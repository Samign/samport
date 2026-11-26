# samport debug launcher: runs scripts\play.ps1 with its settings and writes the whole log,
# a filtered summary and the last 3,000 lines, all outside the repository (docs/asset-policy.md).
#
#   Set-ExecutionPolicy -Scope Process Bypass -Force          (once per window)
#   .\scripts\debug.ps1 -Exe "C:\...\game_scarlett_master.exe"            # ray tracing on (the default here)
#   .\scripts\debug.ps1 -Exe "..." -NoRayTracing                          # the ambient stand-in instead
#   .\scripts\debug.ps1 -Exe "..." -More @{VICTORY_COUNTED_HALVES='1'}    # any other setting
#
# Run it with a leading .\ in a PowerShell window, not through `powershell -File`: a -More
# table does not survive -File.
param(
    [Parameter(Mandatory)][string]$Exe,
    [switch]$NoRayTracing,
    [switch]$Safe,
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [hashtable]$More = @{},
    [string]$Log = "$env:TEMP\ztrx-diag.log"
)
# For an 8 GB card (RTX 3070 Ti): the builder's arenas on the card at most 1.5 GB (the base's
# default is 4 GB, sized for a 24 GB card; a run used 1.16 GB), and texture copies at most
# 3.5 GB (the run before had 4.9 GB of host textures and frames of 2-3.5 s on the card while
# the driver moved memory out). Anything given in -More wins.
# The console reports a 1080p television (the base leaves 3840x2160: the title then renders
# at 4K, which an 8 GB card cannot hold), and textures get card memory only for the levels
# the title shows (tiled resources; VICTORY_LEVELS_ON_DEMAND, off in the base). The run with
# only the two caps above still had 9.4 GB in use on a 7.2 GB budget.
$defaults = @{
    VICTORY_MEMORY_CARD_MB = '1536'; VICTORY_TEXTURE_BUDGET_MB = '3584'
    VICTORY_DISPLAY_MODE = '1920x1080'; VICTORY_LEVELS_ON_DEMAND = '1'
}
foreach ($k in $defaults.Keys) { if (-not $More.ContainsKey($k)) { $More[$k] = $defaults[$k] } }
$play = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'play.ps1'
$env:NO_COLOR = '1'
$splat = @{ Exe = $Exe; Build = $Build; More = $More }
if (-not $NoRayTracing) { $splat.RayTracing = $true }
if ($Safe) { $splat.Safe = $true }
Write-Host "log: $Log  raytracing=$(-not $NoRayTracing) safe=$([bool]$Safe) more=$(($More.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')"
& $play @splat 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log

$summary = $Log -replace '\.log$', '-summary.txt'
$patterns = @(
    " fps, ", "structure builder", "does not translate", "host pipeline refused", "unhandled exception",
    "first-chance exception", "device removed", "memory allocation", "title memory by address:",
    "MB private", "card's memory", "budget", "video memory as the system counts", "ERROR", "panicked", "without a host pipeline: ", "ambient"
) -join "|"
Select-String -Path $Log -Pattern $patterns | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique | Set-Content $summary
Get-Content $Log -Tail 3000 | Set-Content ($Log -replace '\.log$', '-tail.txt')
Write-Host "`nsummary: $summary  ($((Get-Content $summary).Count) lines)" -ForegroundColor Cyan
