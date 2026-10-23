#!/usr/bin/env python3
"""Small sparse FAT32 images exercise the read-only layout checker."""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check_fat32_bav.py")
SECTOR_BYTES = 512
PARTITION_LBA = 8
RESERVED_SECTORS = 32
FAT_SECTORS = 550
DATA_CLUSTERS = 70_000
TOTAL_SECTORS = RESERVED_SECTORS + FAT_SECTORS + DATA_CLUSTERS
FIRST_DATA_LBA = RESERVED_SECTORS + FAT_SECTORS
FILE_CLUSTERS = 23
FIRST_FILE_LBA = PARTITION_LBA + FIRST_DATA_LBA + 1


def put_sector(stream, absolute_lba: int, data: bytes) -> None:
    assert len(data) == SECTOR_BYTES
    stream.seek(absolute_lba * SECTOR_BYTES)
    stream.write(data)


def make_image(path: Path, *, fragmented: bool = False, valid_bav: bool = True) -> None:
    with path.open("wb") as stream:
        stream.truncate((PARTITION_LBA + TOTAL_SECTORS) * SECTOR_BYTES)
        mbr = bytearray(SECTOR_BYTES)
        mbr[446 + 4] = 0x0C
        struct.pack_into("<II", mbr, 446 + 8, PARTITION_LBA, TOTAL_SECTORS)
        mbr[510:512] = b"\x55\xaa"
        put_sector(stream, 0, mbr)

        boot = bytearray(SECTOR_BYTES)
        boot[0:3] = b"\xeb\x58\x90"
        struct.pack_into("<H", boot, 11, SECTOR_BYTES)
        boot[13] = 1
        struct.pack_into("<H", boot, 14, RESERVED_SECTORS)
        boot[16] = 1
        struct.pack_into("<I", boot, 28, PARTITION_LBA)
        struct.pack_into("<I", boot, 32, TOTAL_SECTORS)
        struct.pack_into("<I", boot, 36, FAT_SECTORS)
        struct.pack_into("<I", boot, 44, 2)
        boot[82:90] = b"FAT32   "
        boot[510:512] = b"\x55\xaa"
        put_sector(stream, PARTITION_LBA, boot)

        # Root cluster 2 and a 23-cluster file.  The fragmented variant jumps
        # from cluster 3 to 100, so its physical sectors cannot be streamed.
        chain = [3] + (list(range(100, 122)) if fragmented else list(range(4, 26)))
        fat = bytearray(FAT_SECTORS * SECTOR_BYTES)
        for cluster, following in ((0, 0x0FFFFFF8), (1, 0x0FFFFFFF),
                                   (2, 0x0FFFFFFF),
                                   *zip(chain, chain[1:] + [0x0FFFFFFF])):
            struct.pack_into("<I", fat, cluster * 4, following)
        stream.seek((PARTITION_LBA + RESERVED_SECTORS) * SECTOR_BYTES)
        stream.write(fat)

        root = bytearray(SECTOR_BYTES)
        root[0:11] = b"BADAPPLEBAV"
        root[11] = 0x20
        struct.pack_into("<H", root, 26, 3)
        struct.pack_into("<I", root, 28, FILE_CLUSTERS * SECTOR_BYTES)
        put_sector(stream, PARTITION_LBA + FIRST_DATA_LBA, root)

        first = bytearray(SECTOR_BYTES)
        first[:4] = b"BAV1" if valid_bav else b"NOPE"
        put_sector(stream, FIRST_FILE_LBA, first)


class Fat32BavTests(unittest.TestCase):
    def run_check(self, image: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--image", str(image), *args],
            capture_output=True, text=True, check=False,
        )

    def test_contiguous_file_and_first_lba(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "card.img"
            make_image(image)
            result = self.run_check(image)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"first_lba={FIRST_FILE_LBA}", result.stdout)
            self.assertIn("BADAPPLE.BAV size: 11776 bytes", result.stdout)
            self.assertIn("BAV1 first sector: OK", result.stdout)
            self.assertIn("Contiguous: YES", result.stdout)

    def test_fragmented_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "card.img"
            make_image(image, fragmented=True)
            result = self.run_check(image, "--partition-start-lba", str(PARTITION_LBA))
            self.assertEqual(result.returncode, 1)
            self.assertIn(f"first_lba={FIRST_FILE_LBA}", result.stdout)
            self.assertIn("Contiguous: NO", result.stdout)
            self.assertIn("fragmented", result.stdout)

    def test_invalid_first_sector_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "card.img"
            make_image(image, valid_bav=False)
            result = self.run_check(image)
            self.assertEqual(result.returncode, 1)
            self.assertIn("lacks BAV1 magic", result.stderr)


if __name__ == "__main__":
    unittest.main()
