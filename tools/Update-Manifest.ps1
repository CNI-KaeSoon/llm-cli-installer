[CmdletBinding()]
param(
    [string]$AppRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$ListOnly
)

# This allowlist is the only definition of the release file set. Anything else in the folder (local state, results, ZIPs) is never listed.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\', '/')
$topLevelFiles = @('install.ps1', 'install.bat', 'README.md', 'SECURITY.md', 'PSScriptAnalyzerSettings.psd1', '.gitattributes', '.gitignore')
$recursiveDirectories = @('src', 'docs', 'tests', 'tools')
$relativePaths = New-Object System.Collections.ArrayList
foreach ($name in $topLevelFiles) {
    if (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf) { [void]$relativePaths.Add($name) }
}
foreach ($directory in $recursiveDirectories) {
    $directoryPath = Join-Path $root $directory
    if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $directoryPath -Recurse -File -Force) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($file.Name -eq '.DS_Store') { continue }
        if (@('.zip', '.log') -contains $file.Extension.ToLowerInvariant()) { continue }
        if (@($relative.Split('/')) -contains 'TestResults') { continue }
        [void]$relativePaths.Add($relative)
    }
}
$sorted = [string[]]@($relativePaths | Where-Object { $_ -ne 'manifest.sha256' })
[Array]::Sort($sorted, [StringComparer]::Ordinal)
if ($ListOnly) {
    $sorted
    return
}
$lines = New-Object System.Collections.ArrayList
foreach ($relative in $sorted) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$lines.Add("$hash  $relative")
}
$manifestPath = Join-Path $root 'manifest.sha256'
[IO.File]::WriteAllLines($manifestPath, [string[]]@($lines), (New-Object Text.UTF8Encoding($false)))
Write-Output $manifestPath
