# samport debug launcher: runs the DIAGNOSTICS build, prints and saves the log (whole lines),
# then writes a filtered summary (-summary.txt) and the last 3,000 lines unfiltered (-tail.txt).
# Logs go to %TEMP%, outside the repository (docs/asset-policy.md).
#
#   cargo build --profile diag -p victory --features diagnostics
#
# Examples (repo folder):
#   powershell -ExecutionPolicy Bypass -File scripts\debug.ps1 -Game "C:\...\game_scarlett_master.exe"
#   ... -TexturePct 95                 # texture copies may use 95% of the card budget (default 90); needs texture-room.patch
#   ... -Builder -WaveWhy              # try the RT builder and print why each wave64 retry fails
#   ... -Builder -FirstLaneLocal       # approximate first-lane reads so the 3 missing builder programs translate
#   ... -Builder -FirstLaneLocal -NoQuarantine   # DO NOT USE yet: crashed the game (builder output landed on game pointers)
#   ... -Builder -WaveWhy -WaveWide    # same, plus the risky two-host-wave form (can hang the GPU)
param(
    [Parameter(Mandatory = $true)][string]$Game,
    [string]$Cache = "$env:LOCALAPPDATA\ztrx\cache",   # keep identical between runs or the shader cache starts cold
    [string]$Data  = "$env:LOCALAPPDATA\ztrx\data",
    [string]$Exe   = "$PSScriptRoot\..\target\diag\victory.exe",
    [string]$Log   = "$env:TEMP\ztrx-diag.log",
    [string]$Filter = "info",
    [int]$TexturePct = 0,
    [int]$TextureBudgetMB = 0,
    [switch]$Builder,
    [switch]$WaveWhy,
    [switch]$WaveWide,
    [switch]$Fast,
    [switch]$FirstLaneLocal,
    [switch]$NoQuarantine
)

foreach ($v in "VICTORY_KEYS", "VICTORY_CAPTURE", "VICTORY_CAPTURE_FRAMES", "VICTORY_DUMP_TARGETS",
               "VICTORY_BVH_BUILDER", "VICTORY_BVH_QUARANTINE", "VICTORY_RELAY", "VICTORY_LATE_WAIT",
               "VICTORY_WIDE_BACK", "VICTORY_TEXTURE_PCT", "VICTORY_TEXTURE_BUDGET_MB",
               "VICTORY_WAVE_WHY", "VICTORY_WAVE_WIDE", "VICTORY_FIRSTLANE_LOCAL") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force $Cache, $Data | Out-Null
$env:VICTORY_CACHE_DIR = $Cache
$env:VICTORY_DATA_DIR  = $Data
$env:VICTORY_LOG       = $Filter

if ($Builder)  { $env:VICTORY_BVH_BUILDER = "1"; if (-not $NoQuarantine) { $env:VICTORY_BVH_QUARANTINE = "1" } }
if ($WaveWhy)  { $env:VICTORY_WAVE_WHY = "1" }
if ($WaveWide) { $env:VICTORY_WAVE_WIDE = "1" }
if ($FirstLaneLocal) { $env:VICTORY_FIRSTLANE_LOCAL = "1" }
if ($Fast)     { $env:VICTORY_RELAY = "2" }
if ($TexturePct -gt 0)      { $env:VICTORY_TEXTURE_PCT = "$TexturePct" }
if ($TextureBudgetMB -gt 0) { $env:VICTORY_TEXTURE_BUDGET_MB = "$TextureBudgetMB" }

# The exe: as given (relative to the current folder), or else relative to the repo root.
$tried = @($Exe, (Join-Path "$PSScriptRoot\.." $Exe))
$found = $tried | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
if (-not $found) {
    Write-Host "victory.exe not found. Looked at:" -ForegroundColor Red
    $tried | ForEach-Object { Write-Host "  $([System.IO.Path]::GetFullPath($_))" }
    Write-Host "Build it from the repo root first:  cargo build --profile diag -p victory --features diagnostics" -ForegroundColor Yellow
    Write-Host "or pass the full path with -Exe." -ForegroundColor Yellow
    exit 1
}
$Exe = (Resolve-Path $found).Path
Write-Host "exe: $Exe`ncache: $Cache`nlog: $Log"
Write-Host "builder=$([bool]$Builder) quarantine=$([bool]($Builder -and -not $NoQuarantine)) firstlane=$([bool]$FirstLaneLocal) wavewhy=$([bool]$WaveWhy) wavewide=$([bool]$WaveWide) fast=$([bool]$Fast) texpct=$TexturePct texbudget=$TextureBudgetMB"

# (A first "NativeCommandError" line in the log is only PowerShell wrapping stderr; harmless.)
$env:NO_COLOR = "1"
& $Exe run $Game --execute 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log

$summary = $Log -replace '\.log$', '-summary.txt'
$patterns = @(
    "no room", "card memory for texture copies", "past the host heap", "capped at",
    "builder", "host pipeline refused", "host mesh pipeline", "WAVE64-RETRY",
    "converter shader", "dropped .* without a host pipeline: ", "library saved",
    "ms/frame", "textures picked by index", "device removed", "ERROR",
    "program without a host pipeline", "dstorage", "black frame", "enables the", "buffer view", "constant buffer not", "does not translate"
) -join "|"
Select-String -Path $Log -Pattern $patterns |
    ForEach-Object { $_.Line.Trim() } |
    Select-Object -Unique |
    Set-Content $summary
# The last 3,000 lines unfiltered, for cost breakdowns the summary leaves out.
Get-Content $Log -Tail 3000 | Set-Content ($Log -replace '\.log$', '-tail.txt')
Write-Host "`nsummary: $summary  ($((Get-Content $summary).Count) lines)" -ForegroundColor Cyan
