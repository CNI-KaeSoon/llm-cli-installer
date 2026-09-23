[CmdletBinding()]
param([string]$AppRoot = (Split-Path $PSScriptRoot -Parent))

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $AppRoot 'manifest.sha256'
$excluded = @('manifest.sha256')
$lines = New-Object System.Collections.ArrayList
foreach ($file in Get-ChildItem -LiteralPath $AppRoot -Recurse -File | Sort-Object FullName) {
    $relative = $file.FullName.Substring($AppRoot.Length).TrimStart('\', '/').Replace('\', '/')
    if ($excluded -contains $relative -or $relative -like 'TestResults/*') { continue }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$lines.Add("$hash  $relative")
}
[IO.File]::WriteAllLines($manifestPath, @($lines), (New-Object Text.UTF8Encoding($false)))
Write-Output $manifestPath
