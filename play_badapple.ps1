param(
    [string]$Programmer = '',
    [string]$Bitstream = '',
    [int]$CableIndex = 4,
    [int]$Location = 561
)

# Load the verified TF-card player into Tang Nano 20K FPGA SRAM.
# Keep the prepared TF card in the board's socket. Power cycling clears SRAM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Programmer) {
    $command = Get-Command 'programmer_cli.exe' -ErrorAction SilentlyContinue
    if ($command) {
        $Programmer = $command.Source
    } else {
        $Programmer = 'D:\aFPGA\nes\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe'
    }
}
if (-not $Bitstream) {
    $Bitstream = Join-Path $PSScriptRoot 'firmware\stream.fs'
}
if (-not (Test-Path -LiteralPath $programmer -PathType Leaf)) {
    throw "Gowin Programmer not found: $programmer"
}
if (-not (Test-Path -LiteralPath $bitstream -PathType Leaf)) {
    throw "Bad Apple bitstream not found: $bitstream"
}

& $Programmer --device GW2AR-18C --operation_index 2 --fsFile $Bitstream --cable-index $CableIndex --location $Location
if ($LASTEXITCODE -ne 0) {
    throw "Gowin Programmer failed with exit code $LASTEXITCODE"
}
