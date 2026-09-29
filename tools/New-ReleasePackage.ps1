[CmdletBinding()]
param(
    [string]$AppRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\', '/')
$version = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $root 'src/LLMCliInstaller/LLMCliInstaller.psd1')).ModuleVersion
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path $root -Parent) ('llm-cli-installer-v' + $version + '.zip') }
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ($outputFull.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $outputFull.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'E_PACKAGE_LAYOUT: output must be outside the app root'
}

# The allowlist in Update-Manifest.ps1 is the only definition of the release set.
$files = [string[]]@(& (Join-Path $PSScriptRoot 'Update-Manifest.ps1') -AppRoot $root -ListOnly)
foreach ($required in @('install.ps1', 'README.md', 'src/LLMCliInstaller/LLMCliInstaller.psd1')) {
    if ($files -notcontains $required) { throw "E_PACKAGE_LAYOUT: missing $required" }
}

# The manifest must match the file set and every hash exactly; it is never regenerated here.
$manifestPath = Join-Path $root 'manifest.sha256'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'E_PACKAGE_LAYOUT: manifest.sha256 is missing; run tools/Update-Manifest.ps1' }
$manifestEntries = @{}
foreach ($line in [IO.File]::ReadAllLines($manifestPath)) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw 'E_PACKAGE_LAYOUT: manifest is stale; run tools/Update-Manifest.ps1' }
    $manifestEntries[$Matches[2]] = $Matches[1]
}
$manifestPaths = [string[]]@($manifestEntries.Keys)
[Array]::Sort($manifestPaths, [StringComparer]::Ordinal)
if (($manifestPaths -join "`n") -ne ($files -join "`n")) { throw 'E_PACKAGE_LAYOUT: manifest is stale; run tools/Update-Manifest.ps1' }
foreach ($relative in $files) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifestEntries[$relative]) { throw 'E_PACKAGE_LAYOUT: manifest is stale; run tools/Update-Manifest.ps1' }
}

# Fail closed: an official package needs git. The release set must equal the tracked files and the work tree must be clean.
$gitRequirement = 'E_PACKAGE_LAYOUT: release packaging requires the app root to be a git work tree and git on PATH'
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCommand -or -not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw $gitRequirement }
$prefixOutput = & git -C $root rev-parse --show-prefix
if ($LASTEXITCODE -ne 0 -or ([string]$prefixOutput).Trim()) { throw $gitRequirement }
$status = @(& git -C $root status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'E_PACKAGE_LAYOUT: git command failed' }
if ($status.Count -gt 0) { throw 'E_PACKAGE_LAYOUT: working tree is dirty or has untracked files' }
$trackedOutput = @(& git -C $root -c core.quotepath=off ls-files)
if ($LASTEXITCODE -ne 0) { throw 'E_PACKAGE_LAYOUT: git command failed' }
$tracked = [string[]]@($trackedOutput | Where-Object { $_ -and $_ -ne 'manifest.sha256' })
[Array]::Sort($tracked, [StringComparer]::Ordinal)
if (($tracked -join "`n") -ne ($files -join "`n")) { throw 'E_PACKAGE_LAYOUT: allowlist differs from tracked files' }

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputFull)) | Out-Null
if (Test-Path -LiteralPath $outputFull) { Remove-Item -LiteralPath $outputFull -Force }
$entryNames = [string[]]@($files + 'manifest.sha256')
# Compress-Archive is not used because it fails on hidden dot-files (.gitignore) under pwsh.
$zip = [IO.Compression.ZipFile]::Open($outputFull, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $entryNames) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $relative), $relative, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

# Re-open the ZIP and require its entries to be exactly the release set plus manifest.sha256.
$reader = [IO.Compression.ZipFile]::OpenRead($outputFull)
try { $actualEntries = [string[]]@($reader.Entries | ForEach-Object { $_.FullName }) } finally { $reader.Dispose() }
$expectedEntries = [string[]]@($entryNames)
[Array]::Sort($actualEntries, [StringComparer]::Ordinal)
[Array]::Sort($expectedEntries, [StringComparer]::Ordinal)
if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) { throw 'E_PACKAGE_LAYOUT: ZIP entries differ from the release set' }

$hash = Get-FileHash -LiteralPath $outputFull -Algorithm SHA256
[IO.File]::WriteAllText(($outputFull + '.sha256'), ('{0}  {1}{2}' -f $hash.Hash.ToLowerInvariant(), [IO.Path]::GetFileName($outputFull), "`n"), (New-Object Text.UTF8Encoding($false)))
$hash
