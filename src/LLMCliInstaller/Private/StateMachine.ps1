$script:RunTransitions = @{
    Created = @('Preflight')
    Preflight = @('Selection', 'Recovering', 'PackagingEvidence', 'Failed')
    Recovering = @('Selection', 'PackagingEvidence', 'Failed')
    Selection = @('Diagnosing', 'Failed')
    Diagnosing = @('Inventorying', 'Planned', 'Failed')
    Inventorying = @('AwaitingMigrationDecision', 'Failed')
    AwaitingMigrationDecision = @('Planned', 'PreviewingMigration', 'Failed')
    PreviewingMigration = @('Planned', 'Failed')
    Planned = @('Migrating', 'Installing', 'PackagingEvidence', 'Failed')
    Migrating = @('Installing', 'PackagingEvidence', 'Failed', 'Cancelled')
    Installing = @('RefreshingEnvironment', 'Verifying', 'PackagingEvidence', 'Failed', 'Cancelled')
    RefreshingEnvironment = @('Verifying', 'Installing', 'Failed', 'Cancelled')
    Verifying = @('Installing', 'PackagingEvidence', 'Failed', 'Cancelled')
    PackagingEvidence = @('Succeeded', 'SucceededWithRestartRequired', 'PartiallySucceeded', 'Failed', 'Cancelled')
}

function Move-RunState {
    param($Context, [string]$To)
    $allowed = @($script:RunTransitions[[string]$Context.State])
    if ($allowed -notcontains $To) { throw "E_INTERNAL_STATE: invalid run transition $($Context.State) -> $To" }
    $Context.State = $To
    $Context
}

$script:ComponentTransitions = @{
    Unknown = @('Detecting')
    Detecting = @('Satisfied', 'Missing', 'Unsupported', 'Conflict')
    Satisfied = @('Skipped', 'Planned')
    Missing = @('Planned', 'UnattemptedBlocked')
    Unsupported = @('UnattemptedBlocked')
    Conflict = @('UnattemptedBlocked')
    Planned = @('Installing', 'Skipped', 'UnattemptedBlocked')
    Skipped = @('Verifying')
    Installing = @('Installed', 'RestartRequired', 'InstallFailed')
    Installed = @('Verifying')
    RestartRequired = @('Verifying')
    Verifying = @('Verified', 'VerifiedWithWarning', 'VerificationFailed', 'PathRefreshRequired')
}

function Move-ComponentState {
    param($Result, [string]$To)
    $allowed = @($script:ComponentTransitions[[string]$Result.State])
    if ($allowed -notcontains $To) { throw "E_INTERNAL_STATE: invalid component transition $($Result.State) -> $To" }
    $Result.State = $To
    $Result
}

# Component migration state machine (V2_MIGRATION_PLAN §4).
$script:MigrationTerminalStates = @('KeepSelected', 'MigrationBlocked', 'Committed', 'RemovalFailed', 'ReinstallFailed', 'RollbackSucceeded', 'RollbackFailed', 'RecoveryRequired')
$script:MigrationTransitions = @{
    InventoryUnknown = @('InventoryComplete')
    InventoryComplete = @('Canonical', 'NonCanonical', 'Ambiguous', 'Untrusted', 'ReparseBlocked')
    Canonical = @('KeepSelected', 'MigrationBlocked')
    NonCanonical = @('KeepSelected', 'MigrationPreviewed', 'MigrationBlocked')
    Ambiguous = @('KeepSelected', 'MigrationBlocked')
    Untrusted = @('KeepSelected', 'MigrationBlocked')
    ReparseBlocked = @('KeepSelected', 'MigrationBlocked')
    MigrationPreviewed = @('RemovalStarted', 'KeepSelected', 'MigrationBlocked')
    RemovalStarted = @('Removed', 'RemovalFailed')
    Removed = @('ReinstallStarted', 'RecoveryRequired')
    ReinstallStarted = @('Reinstalled', 'ReinstallFailed')
    Reinstalled = @('MigrationVerified', 'ReinstallFailed')
    MigrationVerified = @('Committed')
}

function Test-MigrationTerminalState {
    param([string]$State)
    return ($script:MigrationTerminalStates -contains $State)
}

function Move-ComponentMigrationState {
    param($Result, [string]$To)
    $from = [string]$Result.MigrationState
    if (Test-MigrationTerminalState -State $from) { throw "E_INTERNAL_STATE: terminal migration state $from cannot transition to $To" }
    $allowed = @($script:MigrationTransitions[$from])
    if ($allowed -notcontains $To) { throw "E_INTERNAL_STATE: invalid migration transition $from -> $To" }
    $Result.MigrationState = $To
    $Result
}

function Resume-ComponentMigrationState {
    # Recovery only: rehydrate a durable, non-terminal checkpoint read from the journal.
    param($Result, [string]$Checkpoint)
    $resumable = @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified')
    if ($resumable -notcontains $Checkpoint) { throw "E_INTERNAL_STATE: checkpoint $Checkpoint is not resumable" }
    $Result.MigrationState = $Checkpoint
    $Result
}
