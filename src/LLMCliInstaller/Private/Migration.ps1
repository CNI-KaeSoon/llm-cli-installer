# Existing-install decision, preview/confirm and transaction orchestration (V2_MIGRATION_PLAN §2-§6, §14).
# Removal is delegated exclusively to Invoke-ComponentRemoval (npm/pymanager official removers, P3 only).

$script:MigrationConfirmToken = '이전'
# §14.8 release gate: migration stays disabled until the §10 Windows 11 E2E gate is met. Keep is unaffected.
$script:MigrationGateOpen = $false
$script:MigrationGateClosedMessage = '기존 설치 이전(migration)은 Windows 11 실기기 검증을 마칠 때까지 비활성화되어 있습니다. 변경 없이 종료합니다. 기존 설치는 유지(Keep)로 사용하세요.'

function Get-MigrationDecision {
    param(
        [Parameter(Mandatory=$true)][string]$ComponentId,
        [Parameter(Mandatory=$true)]$Inventory,
        [Parameter(Mandatory=$true)]$Definition,
        [ValidateSet('Keep', 'Migrate')][string]$Policy = 'Keep'
    )
    $plan = New-MigrationPlan -ComponentId $ComponentId
    $plan.Policy = $Policy
    $plan.CandidateCount = [int]$Inventory.CandidateCount
    $plan.Candidates = @($Inventory.Candidates)
    $plan.Canonicality = [string]$Inventory.Canonicality
    $plan.InventoryFingerprint = [string]$Inventory.Fingerprint
    $plan.PreserveScopes = @($Definition.PreserveScopes)
    $plan.InstallerSummary = [string]$Definition.Install
    $candidate = $null
    if ($plan.CandidateCount -eq 1) { $candidate = @($Inventory.Candidates)[0] }
    elseif ($plan.CandidateCount -gt 1) { $candidate = @($Inventory.Candidates | Where-Object { $_.IsPathWinner } | Select-Object -First 1) | Select-Object -First 1 }
    $plan.Candidate = $candidate
    if ($candidate) { $plan.ProvenanceGrade = [string]$candidate.ProvenanceGrade }

    if ($plan.CandidateCount -eq 0) {
        $plan.Decision = 'None'; $plan.Action = 'NoExistingInstall'; $plan.ReasonCode = 'NoExistingInstall'
        return $plan
    }
    if ($Policy -eq 'Keep') {
        $plan.Decision = 'Keep'
        switch ($plan.Canonicality) {
            'Canonical' { $plan.Action = 'SkipAndVerify'; $plan.ReasonCode = 'Canonical' }
            'Ambiguous' { $plan.Action = 'KeepAndVerify'; $plan.ReasonCode = 'MultipleCandidatesPathWinnerOnly' }
            'ReparseBlocked' { $plan.Action = 'KeepAndVerify'; $plan.ReasonCode = 'ReparseRecordedOnly' }
            'Untrusted' { $plan.Action = 'KeepWithWarning'; $plan.ReasonCode = 'ProvenanceUnknown' }
            default { $plan.Action = 'KeepAndVerify'; $plan.ReasonCode = 'NonCanonicalKept' }
        }
        $plan.ExpectedStates = @('InventoryComplete', $plan.Canonicality, 'KeepSelected')
        return $plan
    }

    $block = {
        param([string]$Action, [string]$Reason, [int]$Code)
        $plan.Decision = 'Blocked'; $plan.Action = $Action; $plan.ReasonCode = $Reason; $plan.StableCode = $Code
        $plan.ExpectedStates = @('InventoryComplete', $plan.Canonicality, 'MigrationBlocked')
        $plan.RecoveryAction = '기존 설치를 유지합니다. 변경은 없습니다.'
        return $plan
    }
    switch ($plan.Canonicality) {
        'Canonical' {
            $plan.Decision = 'Keep'; $plan.Action = 'NoOpAlreadyCanonical'; $plan.ReasonCode = 'AlreadyCanonical'
            $plan.ExpectedStates = @('InventoryComplete', 'Canonical', 'KeepSelected')
            return $plan
        }
        'Ambiguous' { return (& $block 'BlockedConflict' 'MultipleCandidates' 62) }
        'ReparseBlocked' { return (& $block 'BlockedReparsePoint' 'ReparsePoint' 64) }
        'Untrusted' { return (& $block 'BlockedProvenance' ('Provenance' + $plan.ProvenanceGrade) 61) }
    }
    if ($plan.ProvenanceGrade -ne 'P3') { return (& $block 'BlockedUnsupported' 'NoOfficialRemover' 63) }
    if ([string]$Definition.MigrationSupport -eq 'KeepOnly') { return (& $block 'BlockedUnsupported' 'KeepOnlyComponent' 63) }
    $writable = @($candidate.Evidence | Where-Object { $_.Kind -eq 'UserWritable' -and $_.Matched }).Count -gt 0
    if (-not $writable) { return (& $block 'BlockedUnsupported' 'RemoverRequiresElevation' 63) }
    if ($candidate.Lock) { return (& $block 'BlockedLocked' 'BinaryLocked' 64) }

    $plan.Decision = 'Migrate'
    $plan.Action = 'MigrateAndVerify'
    $plan.ReasonCode = 'TrustedRemovable'
    $plan.RemoverSummary = Get-MigrationRemoverSummary -Candidate $candidate
    $plan.RecoveryAction = Get-MigrationRecoveryCommand -Candidate $candidate
    $plan.PathDelta = 'User PATH snapshot; owned delta under canonical root only'
    $plan.RollbackPossible = $true
    $plan.ExpectedStates = @('InventoryComplete', 'NonCanonical', 'MigrationPreviewed', 'RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified', 'Committed')
    return $plan
}

function Set-ComponentMigrationFromPlan {
    param([Parameter(Mandatory=$true)]$Result, [Parameter(Mandatory=$true)]$Plan)
    Move-ComponentMigrationState $Result 'InventoryComplete' | Out-Null
    $Result.Decision = $Plan.Decision
    $Result.ProvenanceGrade = $Plan.ProvenanceGrade
    $Result.Canonicality = $Plan.Canonicality
    $Result.ReasonCode = $Plan.ReasonCode
    if ($Plan.CandidateCount -eq 0) { return $Result }
    Move-ComponentMigrationState $Result $Plan.Canonicality | Out-Null
    switch ($Plan.Decision) {
        'Migrate' { Move-ComponentMigrationState $Result 'MigrationPreviewed' | Out-Null }
        'Blocked' { Move-ComponentMigrationState $Result 'MigrationBlocked' | Out-Null }
        default { Move-ComponentMigrationState $Result 'KeepSelected' | Out-Null }
    }
    return $Result
}

function ConvertTo-MigrationPreviewRow {
    param([Parameter(Mandatory=$true)]$Plan)
    $candidate = $Plan.Candidate
    [ordered]@{
        candidateId = $(if ($candidate) { $candidate.CandidateId } else { $null })
        componentId = $Plan.ComponentId
        currentPath = $(if ($candidate) { Protect-SensitiveText -Text $candidate.Path } else { $null })
        canonicalPath = $(if ($candidate -and $candidate.IsCanonical) { Protect-SensitiveText -Text $candidate.Directory } else { $null })
        provenanceGrade = $Plan.ProvenanceGrade
        evidence = @($(if ($candidate) { @($candidate.Evidence | ForEach-Object { '{0}:{1}' -f $_.Kind, $(if ($_.Matched) { 'ok' } else { 'no' }) }) } else { @() }))
        canonicality = $Plan.Canonicality
        candidateCount = $Plan.CandidateCount
        decision = $Plan.Decision
        action = $Plan.Action
        reasonCode = $Plan.ReasonCode
        stableCode = $Plan.StableCode
        remover = $Plan.RemoverSummary
        installer = $Plan.InstallerSummary
        preserveScopes = @($Plan.PreserveScopes)
        requiresElevation = $false
        locked = $(if ($candidate) { [bool]$candidate.Lock } else { $false })
        reparse = $(if ($candidate) { [bool]$candidate.Reparse } else { $false })
        pathDelta = $Plan.PathDelta
        rollbackPossible = $Plan.RollbackPossible
        expectedStates = @($Plan.ExpectedStates)
        recoveryAction = Protect-SensitiveText -Text $Plan.RecoveryAction
    }
}

function Get-MigrationPreview {
    param([object[]]$Plans)
    $rows = @($Plans | Where-Object { $_ -and $_.CandidateCount -gt 0 } | ForEach-Object { ConvertTo-MigrationPreviewRow -Plan $_ })
    [pscustomobject]@{ Rows = $rows; Json = (ConvertTo-SafeJson -Value @{ schemaVersion = 2; preview = $rows }) }
}

function Write-MigrationPreview {
    param([Parameter(Mandatory=$true)]$Preview)
    Write-Host '기존 설치 이전(migration) 미리보기: 폴더 삭제 명령은 없으며, 설정/인증/세션 내용은 읽지 않습니다.'
    foreach ($row in $Preview.Rows) {
        Write-Host ('- {0} | 후보 {1}개 | 등급 {2} | {3} | 결정 {4} ({5}) | 제거기 {6}' -f $row.componentId, $row.candidateCount, $row.provenanceGrade, $row.canonicality, $row.decision, $row.reasonCode, $(if ($row.remover) { $row.remover } else { '-' }))
    }
}

function Test-MigrationConfirmation {
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    return ([string]$Answer -ceq $script:MigrationConfirmToken)
}

function Read-MigrationChoice {
    Write-Host '비표준 위치의 기존 설치가 있습니다. A) 유지 [기본]  B) 공식 제거 후 정본 재설치(이전)'
    $answer = Read-Host '선택 (A/B)'
    if (([string]$answer).Trim().ToUpperInvariant() -eq 'B') { return 'Migrate' }
    return 'Keep'
}

function Read-MigrationConfirmation {
    $answer = Read-Host ("계속하려면 정확히 '{0}'을 입력하세요 (그 외 입력은 유지)" -f $script:MigrationConfirmToken)
    return (Test-MigrationConfirmation -Answer $answer)
}

function Get-MigrationEventField {
    param($Plan, [string]$Phase, [string]$TransactionId, [int]$PathDeltaCount = 0, [bool]$RollbackAttempted = $false, [string]$RollbackResult, [string]$Checkpoint)
    if (-not $Plan) { return @{} }
    $candidate = $Plan.Candidate
    @{
        migrationTransactionId = $TransactionId
        decision = $Plan.Decision
        provenanceGrade = $Plan.ProvenanceGrade
        canonicality = $Plan.Canonicality
        candidateCount = $Plan.CandidateCount
        candidateFingerprint = $Plan.InventoryFingerprint
        ownerManager = $(if ($candidate) { $candidate.OwnerManager } else { $null })
        packageId = $(if ($candidate) { $candidate.PackageId } else { $null })
        phase = $Phase
        pathDeltaCount = $PathDeltaCount
        rollbackAttempted = $RollbackAttempted
        rollbackResult = $RollbackResult
        journalCheckpoint = $Checkpoint
        reasonCode = $Plan.ReasonCode
    }
}

function Add-MigrationCheckpoint {
    param($Context, $Plan, [string]$JournalPath, [string]$TransactionId, [string]$Phase, [string]$PathSnapshotHash, [Nullable[int]]$RawExitCode, [int]$StableCode = 0, [string]$NewVersion, [bool]$Commit = $false)
    $candidate = $Plan.Candidate
    $record = New-JournalRecord -TransactionId $TransactionId -RunId $Context.RunId -ComponentId $Plan.ComponentId -Phase $Phase -CandidateFingerprint $Plan.InventoryFingerprint -ProvenanceGrade $Plan.ProvenanceGrade -PackageManager $candidate.OwnerManager -PackageId $candidate.PackageId -OldVersion $candidate.PackageVersion -NewVersion $NewVersion -EvidencePath $candidate.EvidencePrefix -PathSnapshotHash $PathSnapshotHash -RawExitCode $RawExitCode -StableCode $StableCode -RecoveryAction $Plan.RecoveryAction -Commit $Commit
    Add-MigrationJournalRecord -Path $JournalPath -Record $record | Out-Null
    Write-RunEvent $Context 'migrate' $Phase $Plan.ComponentId ("migration checkpoint: {0}" -f $Phase) $StableCode $null (Get-MigrationEventField -Plan $Plan -Phase $Phase -TransactionId $TransactionId -Checkpoint $Phase)
}

function Invoke-ComponentMigration {
    # remove -> refresh -> reinstall -> verify -> commit. No elevation, no automatic package rollback (§14.6, §14.7).
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)]$Result,
        [Parameter(Mandatory=$true)]$Plan,
        [Parameter(Mandatory=$true)]$Definition,
        [Parameter(Mandatory=$true)][string]$JournalPath,
        [string]$StateRoot,
        [string]$NpmEffectivePrefix,
        [object[]]$ManagedRuntimes = @(),
        [switch]$NonInteractive
    )
    $outcome = New-MigrationResult -ComponentId $Plan.ComponentId
    $id = $Plan.ComponentId
    # §14.4: re-check the inventory fingerprint immediately before the first change.
    $fresh = Get-ComponentInventory -Id $id -Definition $Definition -NpmEffectivePrefix $NpmEffectivePrefix -ManagedRuntimes $ManagedRuntimes
    if ([string]$fresh.Fingerprint -ne [string]$Plan.InventoryFingerprint) {
        $outcome.StableCode = 65
        $outcome.FinalState = 'StalePlan'
        Write-RunEvent $Context 'migrate' 'stale' $id '미리보기 이후 설치 상태가 바뀌어 이전을 중단합니다. 다시 진단하세요.' 65 $null (Get-MigrationEventField -Plan $Plan -Phase 'StalePlan')
        return $outcome
    }
    $transactionId = [guid]::NewGuid().ToString()
    $outcome.TransactionId = $transactionId
    $Result.MigrationTransactionId = $transactionId
    # Raw runnable form in memory; every serialized copy (events, journal, summary) is masked on write.
    $Result.RecoveryAction = $Plan.RecoveryAction
    $snapshot = New-UserPathSnapshot -TransactionId $transactionId -StateRoot $StateRoot

    Move-ComponentMigrationState $Result 'RemovalStarted' | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $transactionId -Phase 'RemovalStarted' -PathSnapshotHash $snapshot.Hash
    $removal = Invoke-ComponentRemoval -Candidate $Plan.Candidate
    $outcome.RemoverInvocations++
    $Result.CommandSummary = $removal.Process.CommandSummary
    if ($removal.StableCode -ne 0) {
        # Re-inventory: a failed remover may still have removed part of the package.
        $after = Get-ComponentInventory -Id $id -Definition $Definition -NpmEffectivePrefix $NpmEffectivePrefix -ManagedRuntimes $ManagedRuntimes
        $intact = @($after.Candidates | Where-Object { [string]$_.PackageId -eq [string]$Plan.Candidate.PackageId -and [string]$_.EvidencePrefix -eq [string]$Plan.Candidate.EvidencePrefix }).Count -gt 0
        if (-not $intact) {
            Move-ComponentMigrationState $Result 'Removed' | Out-Null
            Move-ComponentState $Result 'UnattemptedBlocked' | Out-Null
            Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $transactionId -Phase 'Removed' -PathSnapshotHash $snapshot.Hash -RawExitCode $removal.Process.ExitCode -StableCode $removal.StableCode
            return (Stop-MigrationWithRecovery -Context $Context -Result $Result -Plan $Plan -JournalPath $JournalPath -TransactionId $transactionId -Snapshot $snapshot -Outcome $outcome -RawExitCode $removal.Process.ExitCode -Phase 'RecoveryRequired')
        }
        Move-ComponentMigrationState $Result 'RemovalFailed' | Out-Null
        Move-ComponentState $Result 'UnattemptedBlocked' | Out-Null
        Set-ComponentFailure $Result $removal.StableCode '공식 제거에 실패했습니다. 설치를 시작하지 않았고 원본과 PATH를 유지합니다.' $removal.Process.ExitCode | Out-Null
        Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $transactionId -Phase 'RemovalFailed' -PathSnapshotHash $snapshot.Hash -RawExitCode $removal.Process.ExitCode -StableCode $removal.StableCode
        $outcome.StableCode = $removal.StableCode
        $outcome.FinalState = 'RemovalFailed'
        return $outcome
    }
    Move-ComponentMigrationState $Result 'Removed' | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $transactionId -Phase 'Removed' -PathSnapshotHash $snapshot.Hash -RawExitCode $removal.Process.ExitCode
    Update-ProcessPath | Out-Null
    return (Complete-ComponentReinstall -Context $Context -Result $Result -Plan $Plan -Definition $Definition -JournalPath $JournalPath -TransactionId $transactionId -Snapshot $snapshot -Outcome $outcome -NonInteractive:$NonInteractive)
}

function Complete-ComponentReinstall {
    param($Context, $Result, $Plan, $Definition, [string]$JournalPath, [string]$TransactionId, $Snapshot, $Outcome, [switch]$NonInteractive)
    $id = $Plan.ComponentId
    $snapshotHash = $(if ($Snapshot) { $Snapshot.Hash } else { $null })
    Move-ComponentMigrationState $Result 'ReinstallStarted' | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Phase 'ReinstallStarted' -PathSnapshotHash $snapshotHash
    if ($Result.State -eq 'Planned') { Move-ComponentState $Result 'Installing' | Out-Null }
    $install = $null
    try {
        $install = Install-Component -Id $id -Definition $Definition -Context $Context -NonInteractive:$NonInteractive
    } catch {
        # An installer exception after removal must still close the attempt with 66 and a recovery command.
        $Outcome.InstallerInvocations++
        Write-RunEvent $Context 'migrate' 'install-exception' $id ('재설치 중 예외: {0}' -f $_.Exception.Message) 66 $null
        if ($Result.State -eq 'Installing') { Move-ComponentState $Result 'InstallFailed' | Out-Null }
        return (Stop-MigrationWithRecovery -Context $Context -Result $Result -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Snapshot $Snapshot -Outcome $Outcome -RawExitCode $null)
    }
    $Outcome.InstallerInvocations++
    $Result.RawExitCode = $install.Process.ExitCode
    if ($install.StableCode -ne 0 -and -not $install.RestartRequired) {
        if ($Result.State -eq 'Installing') { Move-ComponentState $Result 'InstallFailed' | Out-Null }
        return (Stop-MigrationWithRecovery -Context $Context -Result $Result -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Snapshot $Snapshot -Outcome $Outcome -RawExitCode $install.Process.ExitCode)
    }
    if ($Result.State -eq 'Installing') { Move-ComponentState $Result $(if ($install.RestartRequired) { 'RestartRequired' } else { 'Installed' }) | Out-Null }
    $Result.RestartRequired = [bool]$install.RestartRequired
    Move-ComponentMigrationState $Result 'Reinstalled' | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Phase 'Reinstalled' -PathSnapshotHash $snapshotHash -RawExitCode $install.Process.ExitCode
    Update-ProcessPath | Out-Null
    return (Complete-ComponentMigrationVerify -Context $Context -Result $Result -Plan $Plan -Definition $Definition -JournalPath $JournalPath -TransactionId $TransactionId -Snapshot $Snapshot -Outcome $Outcome)
}

function Complete-ComponentMigrationVerify {
    param($Context, $Result, $Plan, $Definition, [string]$JournalPath, [string]$TransactionId, $Snapshot, $Outcome)
    $snapshotHash = $(if ($Snapshot) { $Snapshot.Hash } else { $null })
    if (@('Installed', 'RestartRequired') -contains $Result.State) { Move-ComponentState $Result 'Verifying' | Out-Null }
    $verification = $null
    try {
        $verification = Test-ComponentInstallation -Id $Plan.ComponentId -Definition $Definition
    } catch {
        Write-RunEvent $Context 'migrate' 'verify-exception' $Plan.ComponentId ('검증 중 예외: {0}' -f $_.Exception.Message) 66 $null
        $verification = $null
    }
    if (-not $verification -or -not $verification.Success) {
        if ($Result.State -eq 'Verifying') { Move-ComponentState $Result 'VerificationFailed' | Out-Null }
        if ($Result.MigrationState -eq 'Reinstalled') { Move-ComponentMigrationState $Result 'ReinstallFailed' | Out-Null }
        $verifyExit = $(if ($verification -and $verification.Process) { $verification.Process.ExitCode } else { $null })
        return (Stop-MigrationWithRecovery -Context $Context -Result $Result -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Snapshot $Snapshot -Outcome $Outcome -RawExitCode $verifyExit -AlreadyFailed)
    }
    if ($Result.State -eq 'Verifying') { Move-ComponentState $Result $verification.Status | Out-Null }
    $Result.Version = $verification.Version
    $Result.ResolvedPath = $verification.Process.ResolvedPath
    if ($Result.MigrationState -eq 'Reinstalled') { Move-ComponentMigrationState $Result 'MigrationVerified' | Out-Null }
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Phase 'MigrationVerified' -PathSnapshotHash $snapshotHash -NewVersion $verification.Version
    Move-ComponentMigrationState $Result 'Committed' | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Phase 'Committed' -PathSnapshotHash $snapshotHash -NewVersion $verification.Version -Commit $true
    $Outcome.FinalState = 'Committed'
    $Outcome.StableCode = 0
    return $Outcome
}

function Stop-MigrationWithRecovery {
    # §14.7: no automatic package rollback. Only the product-owned PATH delta may be reverted (CAS, §14.5).
    # -Phase RecoveryRequired marks a remover that failed after partially removing the package (journal stays open).
    param($Context, $Result, $Plan, [string]$JournalPath, [string]$TransactionId, $Snapshot, $Outcome, [Nullable[int]]$RawExitCode, [switch]$AlreadyFailed, [ValidateSet('ReinstallFailed', 'RecoveryRequired')][string]$Phase = 'ReinstallFailed')
    if (-not $AlreadyFailed -and $Result.MigrationState -eq 'ReinstallStarted') { Move-ComponentMigrationState $Result 'ReinstallFailed' | Out-Null }
    if ($Phase -eq 'RecoveryRequired' -and $Result.MigrationState -eq 'Removed') { Move-ComponentMigrationState $Result 'RecoveryRequired' | Out-Null }
    $code = 66
    $rollbackResult = 'NotAttempted'
    $ownedCount = 0
    if ($Snapshot) {
        $rollback = Restore-UserPathSnapshot -Snapshot $Snapshot -CanonicalRoots @($Context.MigrationCanonicalRoots[$Plan.ComponentId])
        $Outcome.RollbackAttempted = $true
        $rollbackResult = $rollback.Result
        $ownedCount = $rollback.OwnedDeltaCount
        if ($rollback.Code -eq 67) { $code = 67 } elseif ($rollback.Code -eq 68) { $code = 68 }
    }
    $Outcome.RollbackResult = $rollbackResult
    $Outcome.StableCode = $code
    $Outcome.FinalState = $Phase
    # Console gets the runnable command; a journal-derived (masked) command is re-expanded for the same user.
    $runnable = [Environment]::ExpandEnvironmentVariables([string]$Plan.RecoveryAction)
    $Outcome.RecoveryAction = $runnable
    $Result.RecoveryAction = $runnable
    $reason = $(if ($Phase -eq 'RecoveryRequired') { '공식 제거가 실패했지만 패키지가 일부 제거되었습니다.' } else { '제거 뒤 재설치/검증에 실패했습니다.' })
    Set-ComponentFailure $Result $code ('{0} 복구 명령: {1}' -f $reason, $runnable) $RawExitCode | Out-Null
    Add-MigrationCheckpoint -Context $Context -Plan $Plan -JournalPath $JournalPath -TransactionId $TransactionId -Phase $Phase -PathSnapshotHash $(if ($Snapshot) { $Snapshot.Hash } else { $null }) -RawExitCode $RawExitCode -StableCode $code
    Write-RunEvent $Context 'migrate' 'recovery-required' $Plan.ComponentId ('복구가 필요합니다: {0}' -f $runnable) $code $null (Get-MigrationEventField -Plan $Plan -Phase $Phase -TransactionId $TransactionId -PathDeltaCount $ownedCount -RollbackAttempted $Outcome.RollbackAttempted -RollbackResult $rollbackResult -Checkpoint $Phase)
    Write-Warning ('[{0}] 복구 명령: {1}' -f $Plan.ComponentId, $runnable)
    return $Outcome
}

function ConvertTo-RecoveryPlan {
    # Rebuilds the minimal plan needed to resume from a journal record. No removal data is re-derived.
    param([Parameter(Mandatory=$true)]$LastRecord)
    $plan = New-MigrationPlan -ComponentId ([string]$LastRecord.componentId)
    $plan.Decision = 'Migrate'
    $plan.Action = 'ResumeRecovery'
    $plan.ReasonCode = 'IncompleteJournal'
    $plan.ProvenanceGrade = [string]$LastRecord.provenanceGrade
    $plan.InventoryFingerprint = [string]$LastRecord.candidateFingerprint
    $plan.RecoveryAction = [string]$LastRecord.recoveryAction
    $plan.Candidate = [pscustomobject]@{ OwnerManager = [string]$LastRecord.packageManager; PackageId = [string]$LastRecord.packageId; PackageVersion = [string]$LastRecord.oldVersion; EvidencePrefix = [string]$LastRecord.evidencePath }
    return $plan
}

function Invoke-MigrationRecovery {
    # Recovery-first routing (§4, §5): never repeats a completed removal.
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)]$LastRecord,
        [Parameter(Mandatory=$true)]$Definition,
        [Parameter(Mandatory=$true)][string]$JournalPath,
        [string]$NpmEffectivePrefix,
        [object[]]$ManagedRuntimes = @(),
        [switch]$NonInteractive
    )
    $id = [string]$LastRecord.componentId
    $transactionId = [string]$LastRecord.transactionId
    $plan = ConvertTo-RecoveryPlan -LastRecord $LastRecord
    $outcome = New-MigrationResult -ComponentId $id -TransactionId $transactionId
    $inventory = Get-ComponentInventory -Id $id -Definition $Definition -NpmEffectivePrefix $NpmEffectivePrefix -ManagedRuntimes $ManagedRuntimes
    $action = Get-JournalReconcileAction -LastRecord $LastRecord -Inventory $inventory
    Write-RunEvent $Context 'recover' 'started' $id ("미완료 이전 복구: {0}" -f $action) 0 $null (Get-MigrationEventField -Plan $plan -Phase ([string]$LastRecord.phase) -TransactionId $transactionId -Checkpoint ([string]$LastRecord.phase))
    $result = New-ComponentResult -Id $id
    $result.MigrationTransactionId = $transactionId
    $result.State = 'Planned'
    switch ($action) {
        'AbortRemovalIncomplete' {
            Resume-ComponentMigrationState $result 'RemovalStarted' | Out-Null
            Move-ComponentMigrationState $result 'RemovalFailed' | Out-Null
            Add-MigrationCheckpoint -Context $Context -Plan $plan -JournalPath $JournalPath -TransactionId $transactionId -Phase 'Aborted' -PathSnapshotHash ([string]$LastRecord.pathSnapshotHash)
            $outcome.FinalState = 'Aborted'
            return $outcome
        }
        'VerifyAndCommit' {
            Resume-ComponentMigrationState $result 'Reinstalled' | Out-Null
            $result.State = 'Verifying'
            $verified = Complete-ComponentMigrationVerify -Context $Context -Result $result -Plan $plan -Definition $Definition -JournalPath $JournalPath -TransactionId $transactionId -Snapshot $null -Outcome $outcome
            return $verified
        }
        'ResumeReinstall' {
            Resume-ComponentMigrationState $result 'Removed' | Out-Null
            return (Complete-ComponentReinstall -Context $Context -Result $result -Plan $plan -Definition $Definition -JournalPath $JournalPath -TransactionId $transactionId -Snapshot $null -Outcome $outcome -NonInteractive:$NonInteractive)
        }
        default {
            $outcome.FinalState = 'None'
            return $outcome
        }
    }
}
