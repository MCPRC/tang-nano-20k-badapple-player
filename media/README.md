# Bad Apple FPGA playback material

The test clip used during development came from an
[Internet Archive copy of the original Bad Apple!! PV](https://archive.org/details/nicovideo-sm8628149-orig).
Neither that video nor its converted `BADAPPLE.BAV` is included in this
repository. Use media that you are allowed to copy and process.

`BADAPPLE.BAV` is a sector-aligned, fixed-record file intended for simple
sequential reading from a prepared TF card by the Tang Nano 20K. The verified
test conversion contains 6,570 video frames (219.0 seconds) at 30 frames/s
and synchronized mono PCM; other input videos produce different frame counts
and durations.
The converter and verifier are included so the file can be regenerated and
checked without a video decoder in the FPGA.

## Build and verify

Requires Python 3.12, `numpy`, and `imageio-ffmpeg`. `Pillow` is optional for
the PNG preview.

```powershell
python convert_bav.py input.mp4 BADAPPLE.BAV --threshold 128 --preview-frame 900
python verify_bav.py BADAPPLE.BAV
```

The verified test file was made from `bad_apple_original.mp4` with this command.
It is 74,004,992 bytes (144,541 sectors) and has SHA-256
`0e2dd277c2e11e649b5f181adb6c13c39014ddbb8062ed4493f4116489f554f7`.
The converter writes a JSON manifest beside its output. `verify_bav.py`
checked all 6,570 test records, including CRCs, counts, flags and padding.

## Global header: one 512-byte sector

All multi-byte integers are little-endian. Byte offsets below are from the
start of the file.

| Offset | Size | Value or meaning |
| ---: | ---: | --- |
| 0 | 4 | ASCII `BAV1` |
| 4 | 2 | Header size: 512 bytes |
| 6 | 2 | Format version: 1 |
| 8 | 2 | Width: 320 pixels |
| 10 | 2 | Height: 240 pixels |
| 12 | 4 | Frame-rate numerator: 30 |
| 16 | 4 | Frame-rate denominator: 1 |
| 20 | 4 | PCM sample rate: 46,875 Hz |
| 24 | 4 | Frame count: 6,570 |
| 28 | 2 | Sectors per frame: 22 |
| 30 | 2 | Packed video bytes per frame: 9,600 |
| 32 | 2 | Per-frame header bytes: 12 |
| 34 | 1 | Pixel format code 1: 1-bit, row-major, MSB-first, 1=white |
| 35 | 1 | Audio format code 1: unsigned 8-bit mono PCM, 128=silence |
| 36 | 4 | Conversion luminance threshold: 128 |
| 40 | 8 | PCM samples used: 10,265,625 |
| 48–511 | 464 | Reserved, zero |

## Frame records

The first frame starts at byte 512. Record `n` starts at byte
`512 + n * 11264`, so it can be read as 22 consecutive 512-byte sectors.
Each record contains:

| Relative offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 4 | Zero-based frame index `n` |
| 4 | 2 | Audio byte/sample count: alternating 1,562 and 1,563 |
| 6 | 2 | Flags; bit 0 is set only on the final frame |
| 8 | 4 | CRC32 of packed video plus this frame's audio, no padding |
| 12 | 9,600 | 320×240 1-bit image, MSB-first in each byte |
| 9,612 | `audio_count` | 46,875 Hz unsigned 8-bit mono PCM |
| Remainder | 90 or 89 | Zero padding through byte 11,263 |

The audio sample range for record `n` is
`[floor(n * 46875 / 30), floor((n + 1) * 46875 / 30))`.
The source AAC audio extends about 0.08 seconds past the video; the converter
uses exactly the samples corresponding to the 219.0-second video.

For an 800×480 RGB LCD, each source pixel can be displayed as a 2×2 block,
producing a 640×480 picture centered with 80-pixel black margins on each side.
The current FPGA player reads consecutive physical SD sectors from a fixed
start LBA; it does not parse FAT at playback time. It uses frame buffers,
1-bit pixel lookup, and 8-bit PCM output; no H.264/AAC decoder is needed on
the FPGA.
