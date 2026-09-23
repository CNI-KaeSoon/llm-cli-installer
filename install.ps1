[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string[]]$Components,
    [switch]$AllowLegacyGemini,
    [switch]$AllowUpgrade,
    [switch]$NonInteractive,
    [string]$LogRoot,
    [switch]$NoSupportBundle,
    [string]$ExistingInstallPolicy = 'Keep',
    [switch]$ConfirmMigration,
    [string[]]$MigrationComponents
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/LLMCliInstaller/LLMCliInstaller.psd1'

try {
    $module = Import-Module $modulePath -Force -ErrorAction Stop -PassThru
    $arguments = @{
        Components = $Components
        AllowLegacyGemini = $AllowLegacyGemini
        AllowUpgrade = $AllowUpgrade
        NonInteractive = $NonInteractive
        NoSupportBundle = $NoSupportBundle
        ExistingInstallPolicy = $ExistingInstallPolicy
        ConfirmMigration = $ConfirmMigration
    }
    if ($MigrationComponents) { $arguments.MigrationComponents = $MigrationComponents }
    if ($LogRoot) { $arguments.LogRoot = $LogRoot }
    if ($WhatIfPreference) { $arguments.WhatIf = $true }
    $result = Invoke-LlmCliInstaller @arguments
    # Console output goes through the same masking as the log files.
    & $module { param($value) ConvertTo-SafeJson -Value $value } $result
    exit ([int]$result.ExitCode)
} catch {
    $message = $_.Exception.Message
    [Console]::Error.WriteLine("설치기를 시작하지 못했습니다: {0}" -f $message)
    if ($message -match 'E_INVALID_ARGUMENT') { exit 2 }
    if ($message -match 'E_LOG_UNAVAILABLE') { exit 12 }
    exit 90
}
