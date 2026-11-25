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
#   ... -Builder -FirstLaneLocal -NamedWrites    # experimental: snapshot only memory a dispatch names (much less CPU work)
#   ... -InPlace 0                     # turn off zero-copy (on by default: memory outside buffers is shared with the card, not copied)
#   ... -InPlace 2                     # also the game's buffers (turns -Fast off)
#   ... -InPlaceProbe                  # ask the driver what in-place memory it accepts (logs "in place probe")
#   ... -GpuTiming                     # rank GPU time by pipeline ("the card's time by command"); frames get slower
#   ... -GpuTiming -BarrierTest indirect   # TIMING ONLY: how much the ~12,000 GPU waits around indirect commands cost
#   ... -NoFast                        # turn off overlap (on by default: VICTORY_RELAY=2, the card works while the CPU prepares)
#   ... -SaveShaders "$env:TEMP\ztrx-shaders"   # keep the game's shaders for study (never inside the repo)
#   ... -Builder -WaveWhy -WaveWide    # same, plus the risky two-host-wave form (can hang the GPU)
param(
    [Parameter(Mandatory = $true)][string]$Game,
    [string]$Cache = "$env:LOCALAPPDATA\ztrx\cache",   # keep identical between runs or the shader cache starts cold
    [string]$Data  = "$env:LOCALAPPDATA\ztrx\data",
    [string]$Exe   = "",                              # default: <repo>\target\diag\victory.exe
    [string]$Log   = "$env:TEMP\ztrx-diag.log",
    [string]$Filter = "info",
    [int]$TexturePct = 0,
    [int]$TextureBudgetMB = 0,
    [switch]$Builder,
    [switch]$WaveWhy,
    [switch]$WaveWide,
    [switch]$Fast,                                    # kept for old command lines: overlap is on by default
    [switch]$NoFast,
    [switch]$FirstLaneLocal,
    [switch]$NoQuarantine,
    [switch]$NamedWrites,
    [int]$InPlace = 1,                                # 1 (default): zero-copy for memory outside buffers; 0 off
    [int]$InPlaceMB = 0,
    [switch]$InPlaceProbe,
    [switch]$GpuTiming,
    [string]$BarrierTest = "",
    [string]$SaveShaders = ""                         # folder OUTSIDE the repo: each shader as given (.cdxil) and translated (.dxil)
)

# Overlap (VICTORY_RELAY=2) is on by default; -InPlace 2 and -GpuTiming turn it off.
$explicitFast = $PSBoundParameters.ContainsKey('Fast')
if ($InPlace -ge 2 -and $explicitFast) { Write-Host "-InPlace 2 cannot be combined with -Fast / VICTORY_LATE_WAIT" -ForegroundColor Red; exit 1 }
$Fast = -not $NoFast -and $InPlace -lt 2 -and -not $GpuTiming
foreach ($v in "VICTORY_KEYS", "VICTORY_CAPTURE", "VICTORY_CAPTURE_FRAMES", "VICTORY_DUMP_TARGETS",
               "VICTORY_BVH_BUILDER", "VICTORY_BVH_QUARANTINE", "VICTORY_RELAY", "VICTORY_LATE_WAIT",
               "VICTORY_WIDE_BACK", "VICTORY_TEXTURE_PCT", "VICTORY_TEXTURE_BUDGET_MB",
               "VICTORY_WAVE_WHY", "VICTORY_WAVE_WIDE", "VICTORY_FIRSTLANE_LOCAL", "VICTORY_MEMORY_WRITES",
               "VICTORY_INPLACE", "VICTORY_INPLACE_MB", "VICTORY_INPLACE_PROBE",
               "VICTORY_GPU_TIMING", "VICTORY_D3D12_DRED", "VICTORY_BARRIER_TEST", "VICTORY_SHADER_SAVE") {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force $Cache, $Data | Out-Null
$env:VICTORY_CACHE_DIR = $Cache
$env:VICTORY_DATA_DIR  = $Data
$env:VICTORY_LOG       = $Filter

if ($Builder)  { $env:VICTORY_BVH_BUILDER = "1"; if (-not $NoQuarantine) { $env:VICTORY_BVH_QUARANTINE = "1" } }
if ($WaveWhy)  { $env:VICTORY_WAVE_WHY = "1" }
if ($WaveWide) { $env:VICTORY_WAVE_WIDE = "1" }
if ($InPlace -gt 0) {
    # Level 2 must not be combined with late wait (crates/victory-gpu/src/inplace.rs).
    if ($InPlace -ge 2 -and ($Fast -or $env:VICTORY_LATE_WAIT)) { Write-Host "-InPlace 2 cannot be combined with -Fast / VICTORY_LATE_WAIT" -ForegroundColor Red; exit 1 }
    $env:VICTORY_INPLACE = "$InPlace"
}
if ($GpuTiming) {
    # Each list runs and is timed on its own (slower overall); DRED notes each command's pipeline.
    $env:VICTORY_GPU_TIMING = "1"; $env:VICTORY_D3D12_DRED = "1"
}
if ($GpuTiming) {
    Write-Host "Note: a -GpuTiming run has no overlap (late wait is off), so frames are slower." -ForegroundColor Yellow
}
if ($SaveShaders) {
    $full = [System.IO.Path]::GetFullPath($SaveShaders)
    $repo = [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
    if ($full.StartsWith($repo, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "-SaveShaders must be outside the repository (docs/asset-policy.md)" -ForegroundColor Red; exit 1
    }
    $env:VICTORY_SHADER_SAVE = $full
}
if ($BarrierTest) {
    # TIMING ONLY: leaves GPU waits out (indirect | groups | both); expect glitches.
    $env:VICTORY_BARRIER_TEST = $BarrierTest
}
if ($InPlaceMB -gt 0) { $env:VICTORY_INPLACE_MB = "$InPlaceMB" }
if ($InPlaceProbe) { $env:VICTORY_INPLACE_PROBE = "1" }
if ($NamedWrites) { $env:VICTORY_MEMORY_WRITES = "named" }
if ($FirstLaneLocal) { $env:VICTORY_FIRSTLANE_LOCAL = "1" }
if ($Fast)     { $env:VICTORY_RELAY = "2" }
if ($TexturePct -gt 0)      { $env:VICTORY_TEXTURE_PCT = "$TexturePct" }
if ($TextureBudgetMB -gt 0) { $env:VICTORY_TEXTURE_BUDGET_MB = "$TextureBudgetMB" }

# The repo root from this script's own path ($PSScriptRoot can be empty in Windows PowerShell 5.1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# The exe: as given (relative to the current folder, then to the repo root), or the diag build.
if (-not $Exe) { $Exe = Join-Path $root "target\diag\victory.exe" }
$tried = @($Exe, (Join-Path $root $Exe))
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
Write-Host "builder=$([bool]$Builder) quarantine=$([bool]($Builder -and -not $NoQuarantine)) firstlane=$([bool]$FirstLaneLocal) namedwrites=$([bool]$NamedWrites) inplace=$InPlace gputiming=$([bool]$GpuTiming) barriertest=$BarrierTest wavewhy=$([bool]$WaveWhy) wavewide=$([bool]$WaveWide) fast=$([bool]$Fast) texpct=$TexturePct texbudget=$TextureBudgetMB"

# (A first "NativeCommandError" line in the log is only PowerShell wrapping stderr; harmless.)
$env:NO_COLOR = "1"
& $Exe run $Game --execute 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log

$summary = $Log -replace '\.log$', '-summary.txt'
$patterns = @(
    "no room", "card memory for texture copies", "past the host heap", "capped at",
    "builder", "host pipeline refused", "host mesh pipeline", "WAVE64-RETRY",
    "converter shader", "dropped .* without a host pipeline: ", "library saved",
    "ms/frame", "textures picked by index", "device removed", "ERROR",
    "program without a host pipeline", "in place", "copystat: memory: ", "time by command", "the card's clock", "dstorage", "black frame", "enables the", "buffer view", "constant buffer not", "does not translate"
) -join "|"
Select-String -Path $Log -Pattern $patterns |
    ForEach-Object { $_.Line.Trim() } |
    Select-Object -Unique |
    Set-Content $summary
# The last 3,000 lines unfiltered, for cost breakdowns the summary leaves out.
Get-Content $Log -Tail 3000 | Set-Content ($Log -replace '\.log$', '-tail.txt')
Write-Host "`nsummary: $summary  ($((Get-Content $summary).Count) lines)" -ForegroundColor Cyan
