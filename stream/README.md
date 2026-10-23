# Tang Nano 20K TF-card Bad Apple player (first hardware integration)

This project reads `BADAPPLE.BAV` from the verified FAT32 TF card at a fixed
physical sector address, displays 320×240 1-bit frames at 2× in the 800×480
RGB LCD, and sends the
46,875 Hz unsigned 8-bit mono PCM track to the board's MAX98357A I2S
amplifier. The board revision is 3921. Pins 51/54/55/56 for amplifier
enable/DIN/WS/BCK were verified during local hardware testing.

## Build and load

From this directory run `gw_sh.exe build.tcl`. The output bitstream is
`impl/pnr/stream.fs`. `..\play_badapple.ps1` loads the included verified
bitstream from `../firmware/stream.fs` into FPGA SRAM. The button-player
bitstream was
also written to the board's **external Flash** on 2026-09-30 with Gowin
Programmer operation 37 (`exFlash Erase,Program,Verify thru GAO-Bridge`).
The programmer reported `Program and Verify flash successfully.`; its SHA256
was `215A51C6C662D25ED305EFA14ACA1222487B48AFCF6E64D0D7A57614E1445C4E`.
Gowin operation 1 (`Reprogram`) then reconfigured the FPGA from Flash, and
the LCD returned to the ready icon. After a physical USB-C power cycle, the
LCD again showed the ready icon without an SRAM download. Pressing S1 then
started the TF-card film from the opening scene, observed for 20 seconds with
the webcam during local testing. A new build is **not**
automatically written to Flash. The `BADAPPLE.BAV` file must remain on the TF
card exactly as prepared for this test.

After loading, the screen shows a white play triangle. Press the board's
**S1** key (upper left near USB, FPGA pin 88) once to play. Press S1 during
playback to restart at the beginning, or press it again after the end to
replay. Each new press is accepted after a 20 ms debounce; holding the key
does not repeat. **S2** (lower left near the RGB connector, FPGA pin 87)
resets to the ready screen. The restart pulse resets both the AV pipeline
and card controller, so the card reinitializes before playback resumes.

The file's starting physical LBA is fixed at **57264** in
`src/sd_sector_bridge.v`. The actual card's FAT32 cluster chain for this file
was independently audited: all 18,068 clusters, starting at cluster 4088,
were consecutive with no discontinuities; the 144,541 file sectors are
contiguous. The audit record is local test data and is not included here.
Another card, another copy of the file, or a rewritten file may have a
different location or fragmented allocation. This first integration does
not parse FAT at playback time.

## Data path

- The 81 MHz `sd_reader` fetches one physical 512-byte sector at a time and
  checks its DAT0 CRC16. A dual-clock 512-byte block RAM and toggle handshake
  transfer the sector to the 33 MHz AV clock domain. Short reads/CRC errors
  are retried up to three times; a 2-second stuck read raises `data_error`.
- `bav_sector_parser` accepts the BAV header and then 22 sectors per frame.
  It checks frame index, sample count, flags, zero padding, and CRC32 of each
  frame's image plus PCM. A parser or SD error stops subsequent requests.
- `bav_av_engine` alternates two 9,600-byte frame buffers and uses a
  4,096-byte audio FIFO. It starts audio after two validated frames are
  buffered. A 46,875 Hz audio sample counter requests 30 fps video changes;
  each actual buffer swap is held until the next LCD VSYNC.
- 33 MHz / (11 × 2 × 32) produces an exact 46,875 Hz I2S sample rate.
  Both 16-bit I2S slots carry the same sample. PCM amplitude is reduced to
  1/4 of signed 16-bit full scale (about 6 dB louder than the initial test).
  The `PCM_SHIFT` constant in `src/bav_av_engine.v` controls this gain.

The LCD receives 1056 × 505 timing at 33 MHz, approximately 61.88 scan
refreshes/s. Source content changes at 30 frames/s.

The on-board LEDs are active low: LED0 toggles every 32 displayed frames;
LED1 lights for an SD/parse error, audio FIFO underflow, or late video. A
dark opening of the video can therefore be distinguished from a stalled
player by watching LED0. Before starting and after finishing, the LCD's
centered white play triangle indicates S1 is ready.

## Verification and limits

Gowin V1.9.11.03 synthesized and routed the full design with 19/46 block
RAMs and no setup or hold violations after the independent 33 MHz and 81 MHz
PLL domains were declared asynchronous. The held request LBA and sector RAM
are crossed with handshakes; same-domain paths have ample timing margin.

The short ROM AV demo played visibly and audibly on the
physical board. The TF-card bitstream was then loaded into FPGA SRAM and
played changing genuine Bad Apple scenes over an 8-second webcam capture
in local testing: an apple, silhouettes, then a witch. The laptop microphone
measured median RMS 0.00147 during playback,
versus the prior quiet baseline 0.000454, confirming speaker output at this
test position; these are not calibrated sound-pressure measurements.

A later 230-second webcam run sampled the display 47 times. Its first image
matched BAV frame 662 (22.067 seconds into the content); the sample at
195 seconds matched frame 6513 (217.1 seconds). The samples from 200 through
230 seconds all match the same final black image, with last-frame fingerprint
error 0/768 and mean inter-frame change 0.005. This confirms visible playback
through the end and a held final frame. The capture and comparison records
are local test data and are not included here.
The user confirmed the updated `PCM_SHIFT=6` volume is suitable and confirmed
that the speaker stopped at the end. A microphone recording near the expected
end contained ambient noise bursts, so its samples alone cannot establish the
exact mute instant; the RTL deasserts `PA_EN` when the terminal audio FIFO
drains. This 5-second sampling cadence cannot rule out brief glitches between
samples.

The parser emits PCM bytes before the enclosing frame CRC is known; if CRC
fails, playback stops, but already queued audio from that damaged frame
cannot be withdrawn.

The card controller source `src/sd_reader.sv` and `src/sdcmd_ctrl.sv` comes
from [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader)
through the Sipeed/NESTang example, with local DAT0 CRC diagnostic additions
in `sd_reader.sv`. The upstream repository is GPL-3.0 licensed. Keep that
license and source attribution when sharing modified copies of this project.
The upstream license text is included as `THIRD_PARTY_LICENSE_GPL3.txt`.
