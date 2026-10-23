#!/usr/bin/env python3
"""Convert a 30 fps video into Tang Nano 20K-friendly BAV1 sectors.

Requires numpy and imageio-ffmpeg. Pillow is optional for the preview PNG.
The output layout is documented in README.md next to this script.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import zlib
from pathlib import Path

import imageio_ffmpeg
import numpy as np


WIDTH = 320
HEIGHT = 240
FPS = 30
AUDIO_RATE = 46_875
SECTOR_BYTES = 512
SECTORS_PER_FRAME = 22
FRAME_HEADER_BYTES = 12
VIDEO_BYTES = WIDTH * HEIGHT // 8
RECORD_BYTES = SECTOR_BYTES * SECTORS_PER_FRAME
MAX_AUDIO_BYTES = RECORD_BYTES - FRAME_HEADER_BYTES - VIDEO_BYTES
HEADER_BYTES = SECTOR_BYTES


def read_frame(pipe, byte_count: int) -> bytes:
    """Read one complete raw frame, or return b'' at end of stream."""
    chunks = []
    remaining = byte_count
    while remaining:
        data = pipe.read(remaining)
        if not data:
            if remaining == byte_count:
                return b""
            raise ValueError(f"Truncated raw frame: missing {remaining} bytes")
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


def ffmpeg_base(input_path: Path) -> list[str]:
    return [
        imageio_ffmpeg.get_ffmpeg_exe(),
        "-hide_banner", "-loglevel", "error", "-nostdin",
        "-i", str(input_path),
    ]


def decode_audio(input_path: Path) -> bytes:
    command = ffmpeg_base(input_path) + [
        "-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(AUDIO_RATE),
        "-c:a", "pcm_u8", "-f", "u8", "pipe:1",
    ]
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def global_header(frame_count: int, audio_samples: int, threshold: int) -> bytes:
    header = bytearray(HEADER_BYTES)
    struct.pack_into("<4s", header, 0, b"BAV1")
    struct.pack_into("<H", header, 4, HEADER_BYTES)
    struct.pack_into("<H", header, 6, 1)  # version
    struct.pack_into("<HH", header, 8, WIDTH, HEIGHT)
    struct.pack_into("<II", header, 12, FPS, 1)
    struct.pack_into("<I", header, 20, AUDIO_RATE)
    struct.pack_into("<I", header, 24, frame_count)
    struct.pack_into("<HHH", header, 28, SECTORS_PER_FRAME, VIDEO_BYTES, FRAME_HEADER_BYTES)
    header[34] = 1  # monochrome, row-major, MSB-first, 1 = white
    header[35] = 1  # unsigned 8-bit mono PCM, 128 = silence
    struct.pack_into("<I", header, 36, threshold)
    struct.pack_into("<Q", header, 40, audio_samples)
    return bytes(header)


def make_preview(video_bits: bytes, output_path: Path) -> None:
    try:
        from PIL import Image
    except ImportError:
        return
    unpacked = np.unpackbits(np.frombuffer(video_bits, dtype=np.uint8), bitorder="big")
    pixels = (unpacked.reshape(HEIGHT, WIDTH) * 255).astype(np.uint8)
    Image.fromarray(pixels).save(output_path)


def convert(input_path: Path, output_path: Path, threshold: int, preview_frame: int) -> dict:
    if not input_path.is_file():
        raise FileNotFoundError(input_path)
    if not 0 <= threshold <= 255:
        raise ValueError("Threshold must be from 0 through 255")
    if MAX_AUDIO_BYTES < (AUDIO_RATE + FPS - 1) // FPS:
        raise ValueError("Frame record is too small for audio")

    audio = decode_audio(input_path)
    video_command = ffmpeg_base(input_path) + [
        "-map", "0:v:0", "-an", "-fps_mode", "passthrough",
        "-vf", f"scale={WIDTH}:{HEIGHT}:flags=lanczos,format=gray",
        "-c:v", "rawvideo", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1",
    ]
    proc = subprocess.Popen(video_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.stdout is None or proc.stderr is None:
        raise RuntimeError("Could not start ffmpeg video decoder")

    frame_count = 0
    stored_crc_samples: dict[int, int] = {}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    preview_path = output_path.with_name(f"{output_path.stem}_preview_{preview_frame}.png")
    try:
        with output_path.open("wb+") as output:
            output.write(bytes(HEADER_BYTES))
            while True:
                raw = read_frame(proc.stdout, WIDTH * HEIGHT)
                if not raw:
                    break
                luminance = np.frombuffer(raw, dtype=np.uint8)
                video_bits = np.packbits(luminance >= threshold, bitorder="big").tobytes()
                if len(video_bits) != VIDEO_BYTES:
                    raise AssertionError("Unexpected packed frame size")

                audio_begin = frame_count * AUDIO_RATE // FPS
                audio_end = (frame_count + 1) * AUDIO_RATE // FPS
                audio_count = audio_end - audio_begin
                audio_chunk = audio[audio_begin:audio_end]
                if len(audio_chunk) < audio_count:
                    audio_chunk += bytes([128]) * (audio_count - len(audio_chunk))
                payload = video_bits + audio_chunk
                payload_crc = zlib.crc32(payload) & 0xFFFFFFFF
                record_header = struct.pack("<IHHI", frame_count, audio_count, 0, payload_crc)
                padding_bytes = RECORD_BYTES - len(record_header) - len(payload)
                if padding_bytes < 0:
                    raise AssertionError("Frame exceeds fixed record size")
                output.write(record_header)
                output.write(payload)
                output.write(bytes(padding_bytes))

                if frame_count == preview_frame:
                    make_preview(video_bits, preview_path)
                if frame_count in (0, 1, 100, 1000):
                    stored_crc_samples[frame_count] = payload_crc
                frame_count += 1
                if frame_count % 1000 == 0:
                    print(f"Converted {frame_count} frames", flush=True)

            stderr = proc.stderr.read().decode("utf-8", errors="replace")
            return_code = proc.wait()
            if return_code:
                raise RuntimeError(f"ffmpeg video decode failed: {stderr}")
            if frame_count == 0:
                raise ValueError("No video frames decoded")
            final_frame_offset = HEADER_BYTES + (frame_count - 1) * RECORD_BYTES
            output.seek(final_frame_offset + 6)
            output.write(struct.pack("<H", 1))  # flags bit 0: final record
            expected_audio_samples = frame_count * AUDIO_RATE // FPS
            output.seek(0)
            output.write(global_header(frame_count, expected_audio_samples, threshold))
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    actual_size = output_path.stat().st_size
    expected_size = HEADER_BYTES + frame_count * RECORD_BYTES
    if actual_size != expected_size:
        raise AssertionError(f"Size mismatch: {actual_size} != {expected_size}")
    digest = hashlib.sha256()
    with output_path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    info = {
        "source": str(input_path.resolve()),
        "output": str(output_path.resolve()),
        "sha256": digest.hexdigest(),
        "frame_count": frame_count,
        "width": WIDTH,
        "height": HEIGHT,
        "fps_num": FPS,
        "fps_den": 1,
        "audio_rate": AUDIO_RATE,
        "audio_samples_used": expected_audio_samples,
        "audio_samples_decoded": len(audio),
        "seconds": frame_count / FPS,
        "sectors_per_frame": SECTORS_PER_FRAME,
        "record_bytes": RECORD_BYTES,
        "video_bytes": VIDEO_BYTES,
        "file_bytes": actual_size,
        "threshold": threshold,
        "sample_payload_crcs": stored_crc_samples,
        "preview": str(preview_path.resolve()) if preview_path.exists() else None,
    }
    manifest_path = output_path.with_suffix(".json")
    manifest_path.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return info


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--threshold", type=int, default=128)
    parser.add_argument("--preview-frame", type=int, default=900)
    args = parser.parse_args()
    print(json.dumps(convert(args.input, args.output, args.threshold, args.preview_frame), indent=2))


if __name__ == "__main__":
    main()
