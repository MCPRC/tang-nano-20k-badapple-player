# Tang Nano 20K Bad Apple 播放器

适用于 Tang Nano 20K（3921 版）和官方 5 英寸 800×480 RGB 屏。FPGA 从板载 TF 卡读取 `BAV1` 文件，以 30 fps 播放 320×240 黑白视频（屏上放大 2 倍），并通过板载 MAX98357A 功放输出同步单声道音频。上电显示播放三角；短按 **S1** 播放，再按可从头重播；**S2** 返回待播放状态。

## 仓库内容

- `stream/src/`、`stream/stream.gprj`、`stream/build.tcl`：可综合的 Gowin 工程。
- `firmware/stream.fs`：在开发板上验证过的位流，SHA-256 为 `215A51C6C662D25ED305EFA14ACA1222487B48AFCF6E64D0D7A57614E1445C4E`。
- `media/convert_bav.py`、`media/verify_bav.py`：将自备视频转换为 `BAV1`，并检查格式和逐帧 CRC。格式说明见 `media/README.md`。
- `stream/README.md`：时钟、显示、音频、硬件验证及当前限制的详细记录。

原视频和转换后的 `BADAPPLE.BAV` 没有上传。请使用有权处理的素材自行生成文件。转换工具需要 Python、`numpy` 和 `imageio-ffmpeg`；预览图另外需要 `Pillow`。

```powershell
python -m pip install numpy imageio-ffmpeg Pillow
python media/convert_bav.py input.mp4 BADAPPLE.BAV --threshold 128
python media/verify_bav.py BADAPPLE.BAV
```

## 编译与下载

在 Gowin IDE 打开 `stream/stream.gprj`，或进入 `stream` 目录运行 `gw_sh.exe build.tcl`。生成的位流为 `stream/impl/pnr/stream.fs`。仓库也附有已验证的 `firmware/stream.fs`。`play_badapple.ps1` 默认将该位流下载到 FPGA 的 SRAM；如 Gowin Programmer 未加入 `PATH`，传入 `-Programmer` 的完整路径。需要选择其他下载器时可传入 `-CableIndex`、`-Location`。SRAM 下载会在掉电后消失；要掉电保持，需要用 Gowin Programmer 将位流写入开发板的外部 Flash。

## 当前 TF 卡限制

**播放器没有解析 FAT 文件系统。** 当前固件把视频起点固定为 TF 卡的物理扇区 **LBA 57264**，并要求整个 `BADAPPLE.BAV` 占据连续扇区。这是开发时那张卡的布局；仅把文件复制到另一张卡，或者重新格式化、重写原卡，都可能改变起点或造成碎片，导致无法播放。适配其他卡前，必须核对文件的物理起始 LBA 和连续性，修改 `stream/src/sd_sector_bridge.v` 中的 `FILE_START_LBA`，重新编译位流。不要把 57264 当成通用设置。

更多实现与验证细节见 `stream/README.md`。本工程包含来自 [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader) 的 GPL-3.0 模块及本地修改，原许可证文本见 `stream/THIRD_PARTY_LICENSE_GPL3.txt`。
