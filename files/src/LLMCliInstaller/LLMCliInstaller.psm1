Set-StrictMode -Version 2.0
$script:ModuleRoot = $PSScriptRoot

$loadOrder = @(
    'Private/Models.ps1',
    'Private/StateMachine.ps1',
    'Private/Redaction.ps1',
    'Private/Logging.ps1',
    'Private/Process.ps1',
    'Private/Path.ps1',
    'Private/Platform.ps1',
    'Private/PackageManager.ps1',
    'Private/UacHelper.ps1',
    'Private/Providers/Common.ps1',
    'Private/Providers/Providers.ps1',
    'Private/Journal.ps1',
    'Private/Migration.ps1',
    'Private/SupportBundle.ps1',
    'Private/Orchestration.ps1'
)
foreach ($relativePath in $loadOrder) {
    . (Join-Path $PSScriptRoot $relativePath)
}

Export-ModuleMember -Function Invoke-LlmCliInstaller, New-LlmCliSupportBundle
