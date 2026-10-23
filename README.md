# Tang Nano 20K Bad Apple 播放器

适用于 Tang Nano 20K（3921 版）和官方 5 英寸 800×480 RGB 屏。FPGA 从板载 TF 卡读取 `BAV1` 文件，以 30 fps 播放 320×240 黑白视频（屏上放大 2 倍），并通过板载 MAX98357A 功放输出同步单声道音频。上电显示播放三角；短按 **S1** 播放，再按可从头重播；**S2** 返回待播放状态。

## 仓库内容

- `stream/src/`、`stream/stream.gprj`、`stream/build.tcl`：可综合的 Gowin 工程。
- `firmware/stream.fs`：在开发板上验证过的位流，SHA-256 为 `215A51C6C662D25ED305EFA14ACA1222487B48AFCF6E64D0D7A57614E1445C4E`。
- `media/convert_bav.py`、`media/verify_bav.py`：将自备视频转换为 `BAV1`，并检查格式和逐帧 CRC。格式说明见 `media/README.md`。
- `tools/check_fat32_bav.py`：只读检查 TF 卡上文件的物理起始 LBA 与簇链连续性。
- `stream/README.md`：时钟、显示、音频、硬件验证及当前限制的详细记录。

原视频和转换后的 `BADAPPLE.BAV` 没有上传。请使用有权处理的素材自行生成文件。转换工具需要 Python、`numpy` 和 `imageio-ffmpeg`；预览图另外需要 `Pillow`。转换结果是供 FPGA 顺序读取的文件，**不是要烧录到整张卡的磁盘镜像**。

```powershell
python -m pip install numpy imageio-ffmpeg Pillow
python media/convert_bav.py input.mp4 BADAPPLE.BAV --threshold 128
python media/verify_bav.py BADAPPLE.BAV
```

## 准备 TF 卡：工具和步骤

写卡只需**电脑上的 TF 读卡器 + Windows 文件资源管理器或 PowerShell 的 `Copy-Item`**，把生成的 `BADAPPLE.BAV` 作为普通文件复制到卡上；不要使用 Rufus、balenaEtcher、`dd` 等整卡镜像写入方式，也不要直接向固定 LBA 写数据。原测试卡有一个 512 MiB 的 FAT32 第一分区（卷标 `FPGA_MEDIA`），另有一个 exFAT 分区；第二分区不参与播放，这种分区大小也不是硬性要求。**请先备份 TF 卡数据，在 Windows“磁盘管理”中核对容量与盘符；需要新建分区时，选用能容纳 BAV 文件的 FAT32 分区。**

以下以 FAT32 分区盘符 `F:` 为例；实际操作前先把命令中的盘符改成你读卡器显示的盘符。在仓库根目录运行：

```powershell
Get-Volume -DriveLetter F | Select-Object DriveLetter, FileSystem, SizeRemaining
Copy-Item -LiteralPath ".\BADAPPLE.BAV" -Destination "F:\BADAPPLE.BAV"
$sourceHash = (Get-FileHash ".\BADAPPLE.BAV" -Algorithm SHA256).Hash
$cardHash = (Get-FileHash "F:\BADAPPLE.BAV" -Algorithm SHA256).Hash
if ($sourceHash -ne $cardHash) { throw "TF 卡文件复制校验失败" }
```

`Get-Volume` 应显示 `FAT32`，剩余空间应大于 BAV 文件大小。文件放在 FAT32 分区**根目录**，名称保持 `BADAPPLE.BAV`。哈希相同只说明文件内容复制正确，**不能证明物理扇区连续，也不能证明起始 LBA 是 57264**。

安全弹出读卡器之前，在**管理员 PowerShell** 中用仓库附带的只读检查工具核对卡上实际布局；工具只读取 FAT32 元数据和 BAV 文件头，不修改卡：

```powershell
$partition = Get-Partition -DriveLetter F
$startLba = [int64]($partition.Offset / 512)
python tools/check_fat32_bav.py --drive F --partition-start-lba $startLba
```

检查结果必须显示 `BAV1` 文件头、`Contiguous: YES` 和实际 `first_lba`。脚本只支持 512 字节扇区的 FAT32 分区及根目录中的 `BADAPPLE.BAV`；若无管理员读取卷的权限，它会报错并停止。测试用的 BAV 为 74,004,992 字节，占 144,541 个扇区；原卡第一分区从 LBA 16384 开始，数据区从 LBA 24576 开始，每簇 8 个扇区，文件首簇 4088、连续 18,068 簇，因此首扇区为 `24576 + (4088 - 2) × 8 = 57264`。这些数字是**原卡实测值**，不是其他卡的默认布局。

## 卡的限制与固件适配

FPGA **不解析 FAT，也不搜索文件名**，只从编译时设定的物理扇区开始连续读取。因此：

1. 随仓库附带的 `firmware/stream.fs` 只适用于文件恰好从 **LBA 57264** 开始、后续扇区连续、文件头为 `BAV1` 的卡。把同一个文件复制到另一张卡也不保证可用。
2. 新卡若检查为连续但首 LBA 不同，修改 `stream/src/sd_sector_bridge.v` 中的 `FILE_START_LBA` 为检查得到的值，然后重新编译、下载新位流。单纯改文件名或重新复制不会修改旧固件中的地址。
3. 若检查显示碎片化，不能直接使用此播放器。备份卡上数据后，在确认目标卡的前提下准备新的空 FAT32 分区、先复制 BAV，再重新检查；不要在已有文件系统上向某个物理扇区强行写入。
4. 格式化、删除后重拷、整理碎片或更换卡，都可能改变簇链；再次使用前应复查。工程只在上述一张卡上完成过端到端验证，不能把 64 GB、512 MiB FAT32 或 57264 当成容量、分区或地址的通用要求。

## 编译、写入 FPGA 与播放

在 Gowin IDE 打开 `stream/stream.gprj`，或进入 `stream` 目录运行 `gw_sh.exe build.tcl`。生成的位流是 `stream/impl/pnr/stream.fs`。只有检查结果恰好符合原卡固定地址时，才能直接使用仓库附带的 `firmware/stream.fs`。

`play_badapple.ps1` 使用 **Gowin Programmer CLI** 将位流下载到 FPGA **SRAM**。默认选择的下载器编号 `-CableIndex 4 -Location 561` 是原测试电脑的设置，其他电脑需根据 Gowin Programmer 检出的下载器更改；如未将 `programmer_cli.exe` 加入 `PATH`，传入 `-Programmer` 的完整路径。重编译后须传入新位流，例如：

```powershell
.\play_badapple.ps1 -Bitstream ".\stream\impl\pnr\stream.fs" -CableIndex 4 -Location 561
```

SRAM 下载会在断电后消失。要掉电保持，请在 **Gowin Programmer** 中选 Tang Nano 20K 对应的 `GW2AR-18C`，使用 `exFlash Erase,Program,Verify thru GAO-Bridge` 操作（CLI operation 37），选择与你的卡 LBA 对应的 `.fs` 文件，写入地址 `0x000000` 并等待校验成功。固件写入的是**开发板外部 Flash**，与复制 BAV 到 TF 卡是两件事。

把经过检查的 TF 卡插回板载卡槽，官方 RGB 屏接好，喇叭接板载功放输出接口 J4，再给 USB-C 上电。屏幕出现白色播放三角后，短按靠 USB-C 的 **S1** 开始播放；播放中再按 S1 从头重播；按 **S2** 返回待播放画面。卡读取或解析失败时，板上 LED1 会亮。

更多实现与验证细节见 `stream/README.md`。本工程包含来自 [WangXuan95/FPGA-SDcard-Reader](https://github.com/WangXuan95/FPGA-SDcard-Reader) 的 GPL-3.0 模块及本地修改，原许可证文本见 `stream/THIRD_PARTY_LICENSE_GPL3.txt`。
