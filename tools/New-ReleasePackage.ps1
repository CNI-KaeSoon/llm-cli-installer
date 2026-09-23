[CmdletBinding()]
param(
    [string]$AppRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'llm-cli-installer-v2.0.0.zip')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Update-Manifest.ps1') -AppRoot $AppRoot | Out-Null
foreach ($required in @('install.ps1', 'manifest.sha256', 'src/LLMCliInstaller/LLMCliInstaller.psd1', 'README.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $AppRoot $required) -PathType Leaf)) { throw "E_PACKAGE_LAYOUT: missing $required" }
}
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
# v2: archive the app root files directly with System.IO.Compression; no staging copy and no recursive delete.
# Compress-Archive is not used because it fails on hidden dot-files (.gitignore) under pwsh.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$rootFull = [IO.Path]::GetFullPath($AppRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | Where-Object { $_.FullName -ne $outputFull })
$zip = [IO.Compression.ZipFile]::Open($outputFull, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entryName = $file.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        if ($entryName -eq 'TestResults' -or $entryName.StartsWith('TestResults/')) { continue }
        if ($entryName.StartsWith('.git/')) { continue }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally {
    $zip.Dispose()
}
Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
