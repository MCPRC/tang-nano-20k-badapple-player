#!/usr/bin/env python3
"""Read-only FAT32 layout check for the fixed-LBA BADAPPLE.BAV player.

Examples (Windows PowerShell):
    python tools/check_fat32_bav.py --drive F --partition-start-lba 2048
    python tools/check_fat32_bav.py --image card.img --partition-start-lba 2048

The drive form opens the mounted volume (\\\\.\\F:), whose sector zero is the
partition boot sector.  Its partition-start LBA is needed only to convert the
file's volume-relative sector to the physical-card LBA used by the FPGA.
The image form opens a whole-disk image and seeks to the given partition LBA;
if omitted, it accepts a FAT32 boot sector at image sector zero or locates the
first FAT32 partition in a conventional MBR.

No path in this program opens a card or image for writing.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

SECTOR_BYTES = 512
SHORT_NAME = b"BADAPPLEBAV"
FAT32_EOC = 0x0FFFFFF8
FAT32_BAD = 0x0FFFFFF7


class CheckError(Exception):
    """A readable validation failure, including malformed or unsafe layouts."""


class Reader(Protocol):
    def read_at(self, offset: int, size: int) -> bytes: ...

    def close(self) -> None: ...


class ImageReader:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.size = path.stat().st_size
        self.stream = path.open("rb")

    def read_at(self, offset: int, size: int) -> bytes:
        if offset < 0 or size < 0 or offset + size > self.size:
            raise CheckError(f"read beyond image bounds at byte {offset}")
        self.stream.seek(offset)
        data = self.stream.read(size)
        if len(data) != size:
            raise CheckError(f"short image read at byte {offset}")
        return data

    def close(self) -> None:
        self.stream.close()


class WindowsVolumeReader:
    """Open a mounted Windows volume with read access and shared access only."""

    def __init__(self, drive: str) -> None:
        if os.name != "nt":
            raise CheckError("--drive is supported on Windows only; use --image here")
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._wintypes = wintypes
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._kernel32.CreateFileW.argtypes = (
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        )
        self._kernel32.CreateFileW.restype = wintypes.HANDLE
        self._kernel32.SetFilePointerEx.argtypes = (
            wintypes.HANDLE, ctypes.c_longlong, ctypes.POINTER(ctypes.c_longlong), wintypes.DWORD,
        )
        self._kernel32.SetFilePointerEx.restype = wintypes.BOOL
        self._kernel32.ReadFile.argtypes = (
            wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID,
        )
        self._kernel32.ReadFile.restype = wintypes.BOOL
        self._kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        self._kernel32.CloseHandle.restype = wintypes.BOOL
        path = f"\\\\.\\{drive.upper()}:"
        self.handle = self._kernel32.CreateFileW(
            path, 0x80000000, 0x00000001 | 0x00000002,
            None, 3, 0, None,
        )
        if self.handle == wintypes.HANDLE(-1).value:
            error = ctypes.get_last_error()
            raise CheckError(
                f"cannot open {path} for read-only access (Windows error {error}); "
                "close apps using the card or run the terminal as Administrator"
            )

    def read_at(self, offset: int, size: int) -> bytes:
        if offset < 0 or size < 0:
            raise CheckError("invalid volume read offset or length")
        ctypes = self._ctypes
        wintypes = self._wintypes
        if not self._kernel32.SetFilePointerEx(self.handle, offset, None, 0):
            raise CheckError(f"volume seek failed (Windows error {ctypes.get_last_error()})")
        buffer = ctypes.create_string_buffer(size)
        count = wintypes.DWORD(0)
        if not self._kernel32.ReadFile(self.handle, buffer, size, ctypes.byref(count), None):
            raise CheckError(f"volume read failed (Windows error {ctypes.get_last_error()})")
        if count.value != size:
            raise CheckError(f"short volume read at byte {offset}: {count.value}/{size}")
        return buffer.raw

    def close(self) -> None:
        if getattr(self, "handle", None) is not None:
            self._kernel32.CloseHandle(self.handle)
            self.handle = None


def u16(data: bytes, pos: int) -> int:
    return struct.unpack_from("<H", data, pos)[0]


def u32(data: bytes, pos: int) -> int:
    return struct.unpack_from("<I", data, pos)[0]


@dataclass(frozen=True)
class Fat32:
    reader: Reader
    partition_lba: int
    image: bool
    sectors_per_cluster: int
    reserved_sectors: int
    fat_count: int
    active_fat: int
    fat_sectors: int
    total_sectors: int
    root_cluster: int
    cluster_count: int

    @property
    def first_data_sector(self) -> int:
        return self.reserved_sectors + self.fat_count * self.fat_sectors

    def sector(self, relative_lba: int) -> bytes:
        if relative_lba < 0 or relative_lba >= self.total_sectors:
            raise CheckError(f"sector {relative_lba} lies beyond the FAT32 volume")
        source_lba = relative_lba + (self.partition_lba if self.image else 0)
        return self.reader.read_at(source_lba * SECTOR_BYTES, SECTOR_BYTES)

    def cluster_sector(self, cluster: int) -> int:
        if cluster < 2 or cluster >= self.cluster_count + 2:
            raise CheckError(f"FAT cluster {cluster} is outside the data region")
        sector = self.first_data_sector + (cluster - 2) * self.sectors_per_cluster
        if sector + self.sectors_per_cluster > self.total_sectors:
            raise CheckError(f"cluster {cluster} extends beyond the volume")
        return sector


def detect_partition(reader: ImageReader) -> int:
    first = reader.read_at(0, SECTOR_BYTES)
    if first[510:512] != b"\x55\xaa":
        raise CheckError("image sector zero has no boot/MBR signature; specify --partition-start-lba")
    if first[82:90] == b"FAT32   ":
        return 0
    for offset in (446, 462, 478, 494):
        kind = first[offset + 4]
        if kind in (0x0B, 0x0C):
            lba = u32(first, offset + 8)
            if lba > 0:
                return lba
    raise CheckError("no FAT32 MBR partition found; specify --partition-start-lba")


def open_fat32(reader: Reader, partition_lba: int, image: bool) -> Fat32:
    boot_offset = partition_lba * SECTOR_BYTES if image else 0
    boot = reader.read_at(boot_offset, SECTOR_BYTES)
    if boot[510:512] != b"\x55\xaa":
        raise CheckError("FAT32 boot sector is missing the 0x55AA signature")
    sector_bytes = u16(boot, 11)
    sectors_per_cluster = boot[13]
    reserved_sectors = u16(boot, 14)
    fat_count = boot[16]
    fat_flags = u16(boot, 40)
    root_entries = u16(boot, 17)
    total_sectors = u32(boot, 32) or u16(boot, 19)
    fat_sectors = u32(boot, 36)
    root_cluster = u32(boot, 44)
    hidden_sectors = u32(boot, 28)
    if sector_bytes != SECTOR_BYTES:
        raise CheckError(f"unsupported sector size {sector_bytes}; player requires 512 bytes")
    if sectors_per_cluster == 0 or sectors_per_cluster > 128 or sectors_per_cluster & (sectors_per_cluster - 1):
        raise CheckError(f"invalid FAT32 sectors per cluster: {sectors_per_cluster}")
    if reserved_sectors == 0 or not 1 <= fat_count <= 4 or fat_sectors == 0:
        raise CheckError("invalid FAT32 reserved/FAT sector counts")
    active_fat = (fat_flags & 0x000F) if fat_flags & 0x0080 else 0
    if active_fat >= fat_count:
        raise CheckError("FAT32 active FAT index exceeds the number of FATs")
    if root_entries != 0 or u16(boot, 22) != 0:
        raise CheckError("boot sector describes FAT12/16 rather than FAT32")
    if u16(boot, 42) != 0:
        raise CheckError("unsupported FAT32 format version")
    first_data = reserved_sectors + fat_count * fat_sectors
    if first_data >= total_sectors:
        raise CheckError("FAT32 data region lies outside the volume")
    cluster_count = (total_sectors - first_data) // sectors_per_cluster
    if cluster_count < 1 or cluster_count + 2 > fat_sectors * (SECTOR_BYTES // 4):
        raise CheckError("FAT32 FAT table is too small for its data region")
    if root_cluster < 2 or root_cluster >= cluster_count + 2:
        raise CheckError("FAT32 root directory cluster is outside the data region")
    if hidden_sectors and hidden_sectors != partition_lba:
        raise CheckError(
            f"partition LBA {partition_lba} disagrees with FAT32 hidden-sectors field "
            f"{hidden_sectors}; verify the partition offset"
        )
    if image and isinstance(reader, ImageReader):
        if (partition_lba + total_sectors) * SECTOR_BYTES > reader.size:
            raise CheckError("FAT32 partition extends beyond the image file")
    return Fat32(reader, partition_lba, image, sectors_per_cluster,
                 reserved_sectors, fat_count, active_fat, fat_sectors, total_sectors,
                 root_cluster, cluster_count)


class FatReader:
    def __init__(self, volume: Fat32) -> None:
        self.volume = volume
        self.cached_lba = -1
        self.cached_sector = b""

    def next_cluster(self, cluster: int) -> int:
        self.volume.cluster_sector(cluster)
        byte_offset = cluster * 4
        fat_start = self.volume.reserved_sectors + self.volume.active_fat * self.volume.fat_sectors
        fat_lba = fat_start + byte_offset // SECTOR_BYTES
        if fat_lba >= fat_start + self.volume.fat_sectors:
            raise CheckError(f"FAT entry for cluster {cluster} lies outside the FAT")
        if fat_lba != self.cached_lba:
            self.cached_sector = self.volume.sector(fat_lba)
            self.cached_lba = fat_lba
        return u32(self.cached_sector, byte_offset % SECTOR_BYTES) & 0x0FFFFFFF


@dataclass(frozen=True)
class FileEntry:
    first_cluster: int
    size: int


def find_bav(volume: Fat32, fat: FatReader) -> FileEntry:
    cluster = volume.root_cluster
    visited: set[int] = set()
    found: FileEntry | None = None
    while True:
        if cluster in visited:
            raise CheckError("root directory FAT chain contains a loop")
        volume.cluster_sector(cluster)
        visited.add(cluster)
        start = volume.cluster_sector(cluster)
        for sec in range(start, start + volume.sectors_per_cluster):
            data = volume.sector(sec)
            for offset in range(0, SECTOR_BYTES, 32):
                entry = data[offset:offset + 32]
                if entry[0] == 0x00:
                    if found is None:
                        raise CheckError("BADAPPLE.BAV was not found in the FAT32 root directory")
                    return found
                if entry[0] == 0xE5 or entry[11] == 0x0F:
                    continue
                if entry[0:11] != SHORT_NAME or entry[11] & (0x08 | 0x10):
                    continue
                first_cluster = u16(entry, 26) | (u16(entry, 20) & 0x0FFF) << 16
                candidate = FileEntry(first_cluster, u32(entry, 28))
                if found is not None:
                    raise CheckError("duplicate BADAPPLE.BAV short-name entries in root directory")
                found = candidate
        next_cluster = fat.next_cluster(cluster)
        if next_cluster >= FAT32_EOC:
            break
        if next_cluster == FAT32_BAD or next_cluster < 2:
            raise CheckError("root directory FAT chain ends at a bad/free cluster")
        cluster = next_cluster
    if found is None:
        raise CheckError("BADAPPLE.BAV was not found in the FAT32 root directory")
    return found


@dataclass(frozen=True)
class LayoutResult:
    size: int
    file_sectors: int
    first_lba: int
    clusters_used: int
    sectors_per_cluster: int
    contiguous: bool
    detail: str


def inspect_layout(volume: Fat32) -> LayoutResult:
    fat = FatReader(volume)
    entry = find_bav(volume, fat)
    if entry.size < SECTOR_BYTES or entry.size % SECTOR_BYTES:
        raise CheckError(f"BADAPPLE.BAV size {entry.size} is not sector aligned")
    first_sector = volume.cluster_sector(entry.first_cluster)
    first_lba = volume.partition_lba + first_sector
    if volume.sector(first_sector)[:4] != b"BAV1":
        raise CheckError(f"BADAPPLE.BAV first sector at absolute LBA {first_lba} lacks BAV1 magic")
    needed = (entry.size + volume.sectors_per_cluster * SECTOR_BYTES - 1) // (
        volume.sectors_per_cluster * SECTOR_BYTES
    )
    cluster = entry.first_cluster
    visited: set[int] = set()
    for index in range(needed):
        if cluster in visited:
            return LayoutResult(entry.size, entry.size // SECTOR_BYTES, first_lba,
                                needed, volume.sectors_per_cluster, False,
                                f"FAT chain loops at cluster {cluster}")
        volume.cluster_sector(cluster)
        visited.add(cluster)
        following = fat.next_cluster(cluster)
        if index == needed - 1:
            if following < FAT32_EOC:
                return LayoutResult(entry.size, entry.size // SECTOR_BYTES, first_lba,
                                    needed, volume.sectors_per_cluster, False,
                                    f"FAT chain continues beyond file size at cluster {cluster} "
                                    f"(next {following})")
        elif following != cluster + 1:
            reason = ("chain ends too early" if following >= FAT32_EOC else
                      "bad cluster" if following == FAT32_BAD else
                      "free cluster" if following < 2 else "fragmented")
            return LayoutResult(entry.size, entry.size // SECTOR_BYTES, first_lba,
                                needed, volume.sectors_per_cluster, False,
                                f"{reason}: cluster {cluster} links to {following}, "
                                f"expected {cluster + 1}")
        cluster = following
    return LayoutResult(entry.size, entry.size // SECTOR_BYTES, first_lba,
                        needed, volume.sectors_per_cluster, True,
                        "all file clusters follow in physical order")


def nonnegative_int(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected a nonnegative integer LBA") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("partition LBA cannot be negative")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--drive", help="Windows drive letter of mounted FAT32 card, e.g. F")
    source.add_argument("--image", type=Path, help="read-only whole-card image for testing")
    parser.add_argument("--partition-start-lba", type=nonnegative_int,
                        help="physical LBA of partition boot sector (required with --drive)")
    args = parser.parse_args()
    reader: Reader | None = None
    try:
        if args.drive is not None:
            match = re.fullmatch(r"([A-Za-z]):?", args.drive)
            if not match:
                raise CheckError("--drive must be one letter, such as F or F:")
            if args.partition_start_lba is None:
                raise CheckError("--drive requires --partition-start-lba from Windows Get-Partition")
            reader = WindowsVolumeReader(match.group(1))
            partition_lba = args.partition_start_lba
            image = False
        else:
            reader = ImageReader(args.image)
            partition_lba = (args.partition_start_lba if args.partition_start_lba is not None
                             else detect_partition(reader))
            image = True
        volume = open_fat32(reader, partition_lba, image)
        result = inspect_layout(volume)
        print(f"BADAPPLE.BAV size: {result.size} bytes ({result.file_sectors} sectors)")
        print(f"Partition start LBA: {partition_lba}")
        print(f"first_lba={result.first_lba} (physical card sector)")
        print(f"Clusters used: {result.clusters_used} ({result.sectors_per_cluster} sectors each)")
        print("BAV1 first sector: OK")
        print(f"Contiguous: {'YES' if result.contiguous else 'NO'} — {result.detail}")
        return 0 if result.contiguous else 1
    except (CheckError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        if reader is not None:
            reader.close()


if __name__ == "__main__":
    raise SystemExit(main())
