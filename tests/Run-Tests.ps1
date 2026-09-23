[CmdletBinding()]
param([switch]$IncludeWindowsE2E)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$excludedTags = @('Network', 'Elevation', 'DestructiveIsolated')
if (-not $IncludeWindowsE2E) { $excludedTags = @($excludedTags + 'WindowsE2E') }
$configuration.Filter.ExcludeTag = $excludedTags
Invoke-Pester -Configuration $configuration
