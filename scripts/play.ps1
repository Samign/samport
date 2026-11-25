# ztrx launcher: runs the game for normal play (no scripted presses, no capture).
param(
    [Parameter(Mandatory = $true)][string]$Game,
    [string]$Cache = "$env:LOCALAPPDATA\ztrx\cache",
    [string]$Data = "$env:LOCALAPPDATA\ztrx\data",
    [string]$Exe = "",
    [int]$InPlace = 1,  # zero-copy for memory outside buffers (VICTORY_INPLACE); 0 turns it off
    [int]$Relay = 2,    # overlap: the card works while the CPU prepares (VICTORY_RELAY); 0 turns it off
    [int]$WideBack = 1, # shader-write snapshots and compares on several threads (VICTORY_WIDE_BACK); 0 turns it off
    [int]$CardBuffersMinMB = 1,    # buffers of this size or more are compared on the card (layer default 16)
    [int]$CardBuffersMB = 768,     # most card memory for those copies (layer default 512; 1024 went over the VRAM budget)
    [int]$IndirectWindow = 1,      # clamp up to 64 indirect mesh records in one pass (VICTORY_INDIRECT_WINDOW); 0 off
    [int]$TextureIdleMS = 1000,    # unused texture copies leave the card after this long (VICTORY_TEXTURE_IDLE_MS)
    [string]$DisplayMode = "1920x1080", # the TV size the console reports (VICTORY_DISPLAY_MODE; layer default 3840x2160)
    [ValidateSet("series-x", "series-s")][string]$Console = "series-x"  # the Xbox model the game sees
)
foreach ($v in "VICTORY_KEYS", "VICTORY_CAPTURE", "VICTORY_CAPTURE_FRAMES", "VICTORY_DUMP_TARGETS") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
# $PSScriptRoot can be empty here in Windows PowerShell 5.1: the repo root from the script path.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Exe) { $Exe = Join-Path $root "target\release\victory.exe" }
if (-not (Test-Path $Exe -PathType Leaf)) {
    Write-Host "victory.exe not found at $([System.IO.Path]::GetFullPath($Exe)). Build it first: cargo build --release -p victory" -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force $Cache, $Data | Out-Null
if ($InPlace -gt 0) { $env:VICTORY_INPLACE = "$InPlace" } else { Remove-Item Env:VICTORY_INPLACE -ErrorAction SilentlyContinue }
if ($Relay -gt 0 -and $InPlace -lt 2) { $env:VICTORY_RELAY = "$Relay" } else { Remove-Item Env:VICTORY_RELAY -ErrorAction SilentlyContinue }
if ($WideBack -gt 0) { $env:VICTORY_WIDE_BACK = "1" } else { Remove-Item Env:VICTORY_WIDE_BACK -ErrorAction SilentlyContinue }
$env:VICTORY_CARD_BUFFERS_MIN_MB = "$CardBuffersMinMB"
$env:VICTORY_CARD_BUFFERS_MB = "$CardBuffersMB"
if ($IndirectWindow -gt 0) { $env:VICTORY_INDIRECT_WINDOW = "1" } else { Remove-Item Env:VICTORY_INDIRECT_WINDOW -ErrorAction SilentlyContinue }
$env:VICTORY_TEXTURE_IDLE_MS = "$TextureIdleMS"
if ($DisplayMode) { $env:VICTORY_DISPLAY_MODE = $DisplayMode } else { Remove-Item Env:VICTORY_DISPLAY_MODE -ErrorAction SilentlyContinue }
$env:VICTORY_CACHE_DIR = $Cache
$env:VICTORY_DATA_DIR = $Data
& $Exe run $Game --execute --console $Console 2>&1 | Out-File "$env:TEMP\ztrx.log" -Encoding utf8
Write-Host "Exited with $LASTEXITCODE; log: $env:TEMP\ztrx.log"
