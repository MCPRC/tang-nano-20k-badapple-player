#!/usr/bin/env python3
"""Validate every record of a BAV1 file, including indices, audio timing and CRC32."""

from __future__ import annotations

import argparse
import json
import struct
import zlib
from pathlib import Path


def verify(path: Path) -> dict:
    with path.open("rb") as stream:
        header = stream.read(512)
        if len(header) != 512 or header[:4] != b"BAV1":
            raise ValueError("Missing BAV1 global header")
        header_bytes, version, width, height = struct.unpack_from("<HHHH", header, 4)
        fps_num, fps_den, audio_rate, frame_count = struct.unpack_from("<IIII", header, 12)
        sectors_per_frame, video_bytes, frame_header_bytes = struct.unpack_from("<HHH", header, 28)
        audio_total_samples = struct.unpack_from("<Q", header, 40)[0]
        if (header_bytes, version, width, height, fps_num, fps_den, audio_rate,
                sectors_per_frame, video_bytes, frame_header_bytes) != (
                512, 1, 320, 240, 30, 1, 46875, 22, 9600, 12):
            raise ValueError("Unexpected BAV1 format settings")
        if header[34:36] != b"\x01\x01":
            raise ValueError("Unexpected pixel or audio encoding")
        if audio_total_samples != frame_count * audio_rate * fps_den // fps_num:
            raise ValueError("Audio sample total does not match frame count")
        record_bytes = sectors_per_frame * 512
        expected_size = header_bytes + frame_count * record_bytes
        if path.stat().st_size != expected_size:
            raise ValueError("File size does not match frame count")

        crcs = {}
        for index in range(frame_count):
            record = stream.read(record_bytes)
            if len(record) != record_bytes:
                raise ValueError(f"Truncated record {index}")
            stored_index, audio_count, flags, stored_crc = struct.unpack_from("<IHHI", record)
            if stored_index != index:
                raise ValueError(f"Record index mismatch at {index}")
            expected_count = ((index + 1) * audio_rate * fps_den // fps_num
                              - index * audio_rate * fps_den // fps_num)
            if audio_count != expected_count:
                raise ValueError(f"Audio count mismatch at {index}")
            if flags != (1 if index == frame_count - 1 else 0):
                raise ValueError(f"EOF flag mismatch at {index}")
            payload_end = frame_header_bytes + video_bytes + audio_count
            if zlib.crc32(record[frame_header_bytes:payload_end]) & 0xFFFFFFFF != stored_crc:
                raise ValueError(f"Payload CRC mismatch at {index}")
            if any(record[payload_end:]):
                raise ValueError(f"Nonzero padding at {index}")
            if index in (0, 1, 100, 1000, frame_count - 1):
                crcs[index] = f"{stored_crc:08x}"
        if stream.read(1):
            raise ValueError("Trailing bytes beyond final frame")
    return {
        "file": str(path.resolve()),
        "frames_verified": frame_count,
        "bytes_verified": expected_size,
        "seconds": frame_count * fps_den / fps_num,
        "audio_samples": audio_total_samples,
        "payload_crc_spot_checks_hex": crcs,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.file), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
