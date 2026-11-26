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
    "MB private", "ERROR", "panicked", "without a host pipeline: ", "ambient"
) -join "|"
Select-String -Path $Log -Pattern $patterns | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique | Set-Content $summary
Get-Content $Log -Tail 3000 | Set-Content ($Log -replace '\.log$', '-tail.txt')
Write-Host "`nsummary: $summary  ($((Get-Content $summary).Count) lines)" -ForegroundColor Cyan
