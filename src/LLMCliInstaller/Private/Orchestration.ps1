function Read-InteractiveSelection {
    Write-Host '설치할 CLI를 쉼표로 선택하세요: codex, claude, antigravity, grok, all'
    Write-Host 'Google/Gemini 계정 사용자는 antigravity를 선택합니다. Legacy Gemini는 고급 옵션입니다.'
    $answer = Read-Host '선택'
    return @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-RunExitCode {
    # §14.3: 65 aborts the run first; incomplete-journal codes 68 > 67 > 66 outrank 60;
    # otherwise v1 logic, with migration block codes 64, 62, 61, 63 after 50.
    param([object[]]$Components, [int]$AbortCode = 0, [int[]]$IncompleteCodes = @(), [string[]]$SelectedIds = @())
    if ($AbortCode -eq 65) { return 65 }
    $failed = @($Components | Where-Object { $_.PrimaryCode -ne 0 })
    $allCodes = @(@($failed | ForEach-Object { [int]$_.PrimaryCode }) + @($IncompleteCodes))
    foreach ($code in @(68, 67, 66)) { if ($allCodes -contains $code) { return $code } }
    $verified = @($Components | Where-Object { $_.State -in @('Verified', 'VerifiedWithWarning') -and [int]$_.PrimaryCode -eq 0 -and (@($SelectedIds).Count -eq 0 -or @($SelectedIds) -contains $_.Id) })
    if ($failed.Count -eq 0) { return 0 }
    if ($verified.Count -gt 0) { return 60 }
    $priority = @(70, 90, 23, 24, 33, 32, 31, 12, 10, 20, 22, 21, 25, 40, 41, 42, 50, 64, 62, 61, 63)
    foreach ($code in $priority) { if ($failed.PrimaryCode -contains $code) { return $code } }
    return [int]$failed[0].PrimaryCode
}

function Get-ExceptionStableCode {
    # Maps an exception message prefix to a stable code. -1 means an invariant violation that must abort the run.
    param([string]$Message)
    if ($Message -match '^E_NETWORK') { return 20 }
    if ($Message -match '^E_INTEGRITY') { return 23 }
    if ($Message -match '^E_NO_TRUSTED') { return 22 }
    if ($Message -match '^E_INTERNAL_STATE') { return -1 }
    return 40
}

function Resolve-ExistingInstallPolicy {
    # Pure argument validation. Any failure throws E_INVALID_ARGUMENT before a single write (§2.1, §14.4).
    # -PreviewOnly (WhatIf) may preview a migration while the §14.8 release gate is closed; nothing is changed.
    param([string]$ExistingInstallPolicy, [switch]$ConfirmMigration, [string[]]$MigrationComponents, [string[]]$Ordered, $Catalog, [switch]$PreviewOnly)
    $policy = ([string]$ExistingInstallPolicy).Trim()
    if (-not $policy) { $policy = 'Keep' }
    if ($policy -eq 'keep') { $policy = 'Keep' } elseif ($policy -eq 'migrate') { $policy = 'Migrate' } else { throw "E_INVALID_ARGUMENT: 알 수 없는 -ExistingInstallPolicy '$ExistingInstallPolicy'" }
    $requested = @($MigrationComponents | Where-Object { $_ } | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($policy -eq 'Keep') {
        if ($ConfirmMigration) { throw 'E_INVALID_ARGUMENT: -ConfirmMigration은 -ExistingInstallPolicy Migrate와 함께만 사용할 수 있습니다.' }
        if ($requested.Count -gt 0) { throw 'E_INVALID_ARGUMENT: -MigrationComponents는 -ExistingInstallPolicy Migrate와 함께만 사용할 수 있습니다.' }
        return [pscustomobject]@{ Policy = 'Keep'; Components = @() }
    }
    if (-not $ConfirmMigration) { throw 'E_INVALID_ARGUMENT: 이전에는 -ExistingInstallPolicy Migrate와 -ConfirmMigration이 모두 필요합니다.' }
    if ($requested.Count -eq 0) { throw 'E_INVALID_ARGUMENT: 이전할 구성요소를 -MigrationComponents로 지정해야 합니다. all은 이전 동의가 아닙니다.' }
    foreach ($id in $requested) {
        if ($Ordered -notcontains $id) { throw "E_INVALID_ARGUMENT: '$id'는 이번 설치 선택 범위 밖입니다." }
        if ([string]$Catalog[$id].MigrationSupport -eq 'KeepOnly') { throw "E_INVALID_ARGUMENT: '$id'는 공식 안전 제거기가 없어 유지만 지원합니다." }
    }
    if (-not $script:MigrationGateOpen -and -not $PreviewOnly) { throw ('E_INVALID_ARGUMENT: ' + $script:MigrationGateClosedMessage) }
    return [pscustomobject]@{ Policy = 'Migrate'; Components = @($requested) }
}

function Get-OrderedComponentList {
    param([string[]]$Selected, $Catalog)
    $ordered = New-Object System.Collections.ArrayList
    foreach ($required in @('powershell', 'python')) { [void]$ordered.Add($required) }
    foreach ($id in $Selected) {
        foreach ($dependency in @($Catalog[$id].DependsOn)) { if ($ordered -notcontains $dependency) { [void]$ordered.Add($dependency) } }
    }
    foreach ($id in $Selected) { if ($ordered -notcontains $id) { [void]$ordered.Add($id) } }
    return @($ordered)
}

function Complete-RunSummary {
    param($Context, [string[]]$Selected, [switch]$NoSupportBundle, [guid]$RunId, [string]$JournalPath, $Preview)
    if ($JournalPath -and ($Context.MigrationResults.Count -gt 0 -or $Context.RecoveryResults.Count -gt 0)) {
        try { Save-SanitizedJournalCopy -JournalPath $JournalPath -RunDirectory $Context.RunDirectory | Out-Null } catch { Write-RunEvent $Context 'journal' 'warning' $null $_.Exception.Message 0 $null }
    }
    $incompleteCodes = @($Context.RecoveryResults | ForEach-Object { [int]$_.StableCode } | Where-Object { $_ -ne 0 })
    $exitCode = Get-RunExitCode -Components @($Context.Components) -AbortCode $Context.AbortCode -IncompleteCodes $incompleteCodes -SelectedIds $Selected
    if ($exitCode -eq 0 -and @($Context.Components | Where-Object { $_.RestartRequired }).Count -gt 0) { $exitCode = 42 }
    $terminal = if ($exitCode -eq 0) { 'Succeeded' } elseif ($exitCode -eq 42) { 'SucceededWithRestartRequired' } elseif ($exitCode -eq 60) { 'PartiallySucceeded' } else { 'Failed' }
    $summary = [pscustomobject]@{ RunId=$Context.RunId; State=$terminal; ExitCode=$exitCode; SelectedComponents=$Selected; Components=@($Context.Components); LogDirectory=$Context.RunDirectory; SupportBundle=$null; WhatIf=$false; Migration=@($Context.MigrationResults); Recovery=@($Context.RecoveryResults); MigrationPreview=$(if ($Preview) { @($Preview.Rows) } else { @() }) }
    [IO.File]::WriteAllText((Join-Path $Context.RunDirectory 'summary.json'), (ConvertTo-SafeJson $summary), (New-Object Text.UTF8Encoding($false)))
    if (-not $NoSupportBundle) {
        $bundlePath = Join-Path $Context.RunDirectory ('support-{0}.zip' -f $Context.RunId)
        try { $summary.SupportBundle = New-LlmCliSupportBundle -RunId $RunId -OutputPath $bundlePath -LogRoot $Context.LogRoot } catch { Write-RunEvent $Context 'bundle' 'warning' $null $_.Exception.Message 0 $null }
    }
    Move-RunState $Context $terminal | Out-Null
    Write-RunEvent $Context 'run' 'completed' $null ("실행 종료: {0}" -f $terminal) $exitCode @{ supportBundle=$summary.SupportBundle }
    return $summary
}

function Invoke-LlmCliInstaller {
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
    if ((-not $Components -or $Components.Count -eq 0) -and $NonInteractive) { throw 'E_INVALID_ARGUMENT: 무인 모드에는 -Components가 필요합니다.' }
    if (-not $Components -or $Components.Count -eq 0) { $Components = Read-InteractiveSelection }
    $selected = @(Resolve-ComponentSelection -Components $Components -AllowLegacyGemini:$AllowLegacyGemini)
    $catalog = Get-ComponentCatalog
    $ordered = @(Get-OrderedComponentList -Selected $selected -Catalog $catalog)
    $migration = Resolve-ExistingInstallPolicy -ExistingInstallPolicy $ExistingInstallPolicy -ConfirmMigration:$ConfirmMigration -MigrationComponents $MigrationComponents -Ordered $ordered -Catalog $catalog -PreviewOnly:([bool]$WhatIfPreference)
    $runId = [guid]::NewGuid()
    $context = New-RunContext -RunId $runId -LogRoot $LogRoot
    Initialize-RunLogging -Context $context -RequestedRoot $LogRoot | Out-Null
    Write-RunEvent $context 'run' 'started' $null '설치기 실행을 시작합니다.' 0 @{ selected=$selected; whatIf=[bool]$WhatIfPreference; allowUpgrade=[bool]$AllowUpgrade; existingInstallPolicy=$migration.Policy; migrationComponents=@($migration.Components) }
    Move-RunState $context 'Preflight' | Out-Null
    $platform = Get-PlatformDiagnostic
    if (-not $platform.IsSupported -and -not $WhatIfPreference) {
        Write-RunEvent $context 'preflight' 'failed' $null 'Windows 11 x64에서만 실행할 수 있습니다.' 10 @{ architecture=$platform.Architecture }
        Move-RunState $context 'Failed' | Out-Null
        return [pscustomobject]@{ RunId=$context.RunId; State=$context.State; ExitCode=10; SelectedComponents=$selected; Components=@(); LogDirectory=$context.RunDirectory; SupportBundle=$null }
    }
    Write-RunEvent $context 'preflight' 'completed' $null '플랫폼 진단을 완료했습니다.' 0 @{ isWindows=$platform.IsWindows; architecture=$platform.Architecture; powershell=$platform.PowerShellVersion }

    $mutex = $null
    try {
        # §14.2: every changing run holds Local\LLMCliInstaller; a concurrent run exits 65 with zero changes.
        if (-not $WhatIfPreference) {
            $mutex = Enter-InstallerMutex
            if (-not $mutex) {
                $context.AbortCode = 65
                Write-RunEvent $context 'run' 'blocked' $null '다른 설치기 실행이 진행 중입니다. 변경 없이 종료합니다.' 65 $null
                Move-RunState $context 'PackagingEvidence' | Out-Null
                return (Complete-RunSummary -Context $context -Selected $selected -NoSupportBundle:$NoSupportBundle -RunId $runId -JournalPath $null)
            }
        }
        $stateRoot = Get-MigrationStateRoot
        $journalPath = Get-MigrationJournalPath -StateRoot $stateRoot
        $npmPrefix = $null
        $managedRuntimes = @()
        if ($platform.IsWindows) {
            if (@($ordered | Where-Object { $catalog[$_].Remover -eq 'npm' }).Count -gt 0) { $npmPrefix = Get-NpmEffectivePrefix }
            if ($ordered -contains 'python') { $managedRuntimes = @(Get-PyManagerManagedRuntime) }
        }

        # Recovery-first routing: an incomplete journal must reach a terminal/safe checkpoint before new changes (§4).
        $incomplete = @(Get-IncompleteMigrationTransaction -Path $journalPath)
        $recoveryBlocked = $false
        if ($incomplete.Count -gt 0) {
            Move-RunState $context 'Recovering' | Out-Null
            Write-RunEvent $context 'recover' 'detected' $null ("미완료 이전 기록 {0}건을 발견했습니다." -f $incomplete.Count) 0 $null
            # Any recovery activity (or a pending one under WhatIf) forces Keep for the rest of this run.
            $recoveryBlocked = $true
            if (-not $WhatIfPreference) {
                foreach ($record in $incomplete) {
                    $recoveryId = [string]$record.componentId
                    if (-not $catalog.ContainsKey($recoveryId)) {
                        # Unknown component: cannot be reconciled, so it blocks every new change in this run.
                        $unreconcilable = New-MigrationResult -ComponentId $recoveryId -TransactionId ([string]$record.transactionId)
                        $unreconcilable.StableCode = 66
                        $unreconcilable.FinalState = 'Unreconcilable'
                        Write-RunEvent $context 'recover' 'unreconcilable' $recoveryId '알 수 없는 구성요소의 미완료 이전 기록이라 복구할 수 없습니다. 새 변경을 하지 않습니다.' 66 $null
                        [void]$context.RecoveryResults.Add($unreconcilable)
                        continue
                    }
                    $recovered = Invoke-MigrationRecovery -Context $context -LastRecord $record -Definition $catalog[$recoveryId] -JournalPath $journalPath -NpmEffectivePrefix $npmPrefix -ManagedRuntimes $managedRuntimes -NonInteractive:$NonInteractive
                    [void]$context.RecoveryResults.Add($recovered)
                }
                if (@($context.RecoveryResults | Where-Object { $_.StableCode -ne 0 }).Count -gt 0) {
                    Move-RunState $context 'PackagingEvidence' | Out-Null
                    return (Complete-RunSummary -Context $context -Selected $selected -NoSupportBundle:$NoSupportBundle -RunId $runId -JournalPath $journalPath)
                }
                Write-RunEvent $context 'recover' 'migration-deferred' $null '미완료 이전을 복구했습니다. 이번 실행에서는 새 이전(제거)을 하지 않습니다. 이전하려면 다시 실행하세요.' 0 $null
            }
        }
        Move-RunState $context 'Selection' | Out-Null
        if ($selected -contains 'legacy-gemini') {
            Write-RunEvent $context 'selection' 'warning' 'legacy-gemini' 'Legacy Gemini는 Enterprise, Google Cloud 또는 유료 API 키 사용자를 위한 고급 선택입니다. 로그인은 자동화하지 않습니다.' 0 $null
        }
        Move-RunState $context 'Diagnosing' | Out-Null
        $plans = @{}
        $resultById = @{}
        foreach ($id in $ordered) {
            $result = New-ComponentResult -Id $id
            [void]$context.Components.Add($result)
            $resultById[$id] = $result
            Move-ComponentState $result 'Detecting' | Out-Null
            if ($WhatIfPreference) {
                Move-ComponentState $result 'Missing' | Out-Null
            } else {
                $status = Get-ComponentStatus -Id $id -Definition $catalog[$id]
                Move-ComponentState $result $status.State | Out-Null
                if ($status.State -eq 'Satisfied') {
                    $result.Version = $status.Verification.Version
                    $result.ResolvedPath = $status.Verification.Process.ResolvedPath
                }
            }
        }

        # Inventory is read-only for every component; keep is the default decision (§2.1).
        Move-RunState $context 'Inventorying' | Out-Null
        $inventories = @{}
        $migrationPlans = @{}
        foreach ($id in $ordered) {
            $inventories[$id] = Get-ComponentInventory -Id $id -Definition $catalog[$id] -NpmEffectivePrefix $npmPrefix -ManagedRuntimes $managedRuntimes
            $context.MigrationCanonicalRoots[$id] = @($inventories[$id].CanonicalRoots)
            $componentPolicy = $(if ($migration.Policy -eq 'Migrate' -and $migration.Components -contains $id -and -not $recoveryBlocked) { 'Migrate' } else { 'Keep' })
            $migrationPlans[$id] = Get-MigrationDecision -ComponentId $id -Inventory $inventories[$id] -Definition $catalog[$id] -Policy $componentPolicy
        }
        Move-RunState $context 'AwaitingMigrationDecision' | Out-Null
        $interactiveMigrate = $false
        if (-not $NonInteractive -and -not $WhatIfPreference -and $migration.Policy -eq 'Keep' -and -not $recoveryBlocked) {
            $offer = @($ordered | Where-Object { $migrationPlans[$_].Canonicality -eq 'NonCanonical' -and [string]$catalog[$_].MigrationSupport -ne 'KeepOnly' })
            if (-not $script:MigrationGateOpen -and $offer.Count -gt 0) {
                Write-RunEvent $context 'migrate' 'offer-skipped' $null $script:MigrationGateClosedMessage 0 $null
            } elseif ($offer.Count -gt 0 -and (Read-MigrationChoice) -eq 'Migrate') {
                foreach ($id in $offer) { $migrationPlans[$id] = Get-MigrationDecision -ComponentId $id -Inventory $inventories[$id] -Definition $catalog[$id] -Policy 'Migrate' }
                $interactiveMigrate = $true
            }
        }
        $preview = $null
        $wantsPreview = ($WhatIfPreference -or $migration.Policy -eq 'Migrate' -or $interactiveMigrate)
        if ($wantsPreview) {
            Move-RunState $context 'PreviewingMigration' | Out-Null
            $preview = Get-MigrationPreview -Plans @($ordered | ForEach-Object { $migrationPlans[$_] })
            [IO.File]::WriteAllText((Join-Path $context.RunDirectory 'migration-preview.json'), $preview.Json, (New-Object Text.UTF8Encoding($false)))
            if ($preview.Rows.Count -gt 0) { Write-MigrationPreview -Preview $preview }
            if ($interactiveMigrate -and -not (Read-MigrationConfirmation)) {
                foreach ($id in $ordered) { $migrationPlans[$id] = Get-MigrationDecision -ComponentId $id -Inventory $inventories[$id] -Definition $catalog[$id] -Policy 'Keep' }
                Write-RunEvent $context 'migrate' 'declined' $null "확인 문구가 일치하지 않아 기존 설치를 유지합니다." 0 $null
            }
        }
        foreach ($id in $ordered) {
            $result = $resultById[$id]
            $migrationPlan = $migrationPlans[$id]
            $context.MigrationPlans[$id] = $migrationPlan
            Set-ComponentMigrationFromPlan -Result $result -Plan $migrationPlan | Out-Null
            $plans[$id] = Get-ComponentInstallPlan -Id $id -Definition $catalog[$id] -CurrentState $result.State
            if ($migrationPlan.Decision -eq 'Migrate') {
                $plans[$id].Action = 'MigrateAndVerify'
                Move-ComponentState $result 'Planned' | Out-Null
            } elseif ($result.State -eq 'Satisfied') { Move-ComponentState $result 'Skipped' | Out-Null }
            else { Move-ComponentState $result 'Planned' | Out-Null }
            if ($migrationPlan.Decision -eq 'Blocked') {
                Set-ComponentFailure $result $migrationPlan.StableCode ('이전이 차단되어 기존 설치를 유지합니다: {0}' -f $migrationPlan.ReasonCode) | Out-Null
            }
            Write-RunEvent $context 'diagnose' 'completed' $id ("상태: {0}, 계획: {1}, 기존 설치: {2}" -f $result.State, $plans[$id].Action, $migrationPlan.Action) 0 @{ channel=$plans[$id].Channel } (Get-MigrationEventField -Plan $migrationPlan -Phase $result.MigrationState)
        }
        Move-RunState $context 'Planned' | Out-Null
        if ($WhatIfPreference) {
            Move-RunState $context 'PackagingEvidence' | Out-Null
            $summary = [pscustomobject]@{ RunId=$context.RunId; State='Succeeded'; ExitCode=0; SelectedComponents=$selected; Components=@($context.Components); LogDirectory=$context.RunDirectory; SupportBundle=$null; WhatIf=$true; MigrationPreview=$(if ($preview) { @($preview.Rows) } else { @() }); RecoveryPending=$recoveryBlocked }
            [IO.File]::WriteAllText((Join-Path $context.RunDirectory 'summary.json'), (ConvertTo-SafeJson $summary), (New-Object Text.UTF8Encoding($false)))
            Move-RunState $context 'Succeeded' | Out-Null
            Write-RunEvent $context 'run' 'completed' $null 'WhatIf 계획 검증을 완료했습니다. 시스템 변경은 없습니다.' 0 $null
            return $summary
        }
        $migrating = @($ordered | Where-Object { $migrationPlans[$_].Decision -eq 'Migrate' })
        if ($migrating.Count -gt 0) { Move-RunState $context 'Migrating' | Out-Null }
        Move-RunState $context 'Installing' | Out-Null
        foreach ($id in $ordered) {
            $result = $resultById[$id]
            $definition = $catalog[$id]
            $blockedBy = @($definition.DependsOn | Where-Object { $resultById.ContainsKey($_) -and $resultById[$_].State -notin @('Verified', 'VerifiedWithWarning') })
            if ($blockedBy.Count -gt 0) {
                if ($result.State -eq 'Planned') { Move-ComponentState $result 'UnattemptedBlocked' | Out-Null }
                Set-ComponentFailure $result 40 ("선행 구성요소 실패: {0}" -f ($blockedBy -join ', ')) | Out-Null
                Write-RunEvent $context 'install' 'blocked' $id $result.Message $result.PrimaryCode @{ blockedBy=$blockedBy }
                continue
            }
            if ($migrationPlans[$id].Decision -eq 'Migrate' -and $result.State -eq 'Planned') {
                $outcome = Invoke-ComponentMigration -Context $context -Result $result -Plan $migrationPlans[$id] -Definition $definition -JournalPath $journalPath -StateRoot $stateRoot -NpmEffectivePrefix $npmPrefix -ManagedRuntimes $managedRuntimes -NonInteractive:$NonInteractive
                [void]$context.MigrationResults.Add($outcome)
                if ($outcome.StableCode -eq 65) { $context.AbortCode = 65; break }
                continue
            }
            try {
                if ($result.State -eq 'Skipped') {
                    Move-ComponentState $result 'Verifying' | Out-Null
                } else {
                    Move-ComponentState $result 'Installing' | Out-Null
                    Write-RunEvent $context 'install' 'started' $id '공식 설치 채널을 실행합니다.' 0 @{ channel=$definition.Install }
                    $install = Install-Component -Id $id -Definition $definition -Context $context -NonInteractive:$NonInteractive
                    $result.RawExitCode = $install.Process.ExitCode
                    $result.RestartRequired = [bool]$install.RestartRequired
                    $result.CommandSummary = $install.Process.CommandSummary
                    if ($install.Process.PSObject.Properties['InstallerExecutedSha256']) {
                        $result.InstallerDownloadSha256 = $install.Process.InstallerDownloadSha256
                        $result.InstallerExecutedSha256 = $install.Process.InstallerExecutedSha256
                    }
                    if ($install.StableCode -ne 0 -and -not $install.RestartRequired) {
                        Move-ComponentState $result 'InstallFailed' | Out-Null
                        Set-ComponentFailure $result $install.StableCode (Get-OutputTail -Text (($install.Process.StdErr, $install.Process.StdOut) -join ' ') -MaxLength 4000) $install.Process.ExitCode | Out-Null
                        Write-RunEvent $context 'install' 'failed' $id $result.Message $result.PrimaryCode @{ rawExitCode=$result.RawExitCode; commandSummary=$result.CommandSummary }
                        continue
                    }
                    if ($install.RestartRequired) { Move-ComponentState $result 'RestartRequired' | Out-Null }
                    else { Move-ComponentState $result 'Installed' | Out-Null }
                    Update-ProcessPath | Out-Null
                    Move-ComponentState $result 'Verifying' | Out-Null
                }
                $verification = Test-ComponentInstallation -Id $id -Definition $definition
                if ($verification.Success) {
                    Move-ComponentState $result $verification.Status | Out-Null
                    $result.Version = $verification.Version
                    $result.ResolvedPath = $verification.Process.ResolvedPath
                    Write-RunEvent $context 'verify' 'completed' $id ("버전 {0} 검증 성공" -f $result.Version) 0 @{ resolvedPath=$result.ResolvedPath }
                } else {
                    Move-ComponentState $result 'VerificationFailed' | Out-Null
                    Set-ComponentFailure $result $verification.Code '새 프로세스 버전 검증에 실패했습니다.' $verification.Process.ExitCode | Out-Null
                    Write-RunEvent $context 'verify' 'failed' $id $result.Message $result.PrimaryCode @{ rawExitCode=$result.RawExitCode }
                }
            } catch {
                $failure = $_.Exception.Message
                $failureCode = Get-ExceptionStableCode -Message $failure
                if ($failureCode -eq -1) { throw }
                if ($result.State -eq 'Installing') { Move-ComponentState $result 'InstallFailed' | Out-Null }
                elseif ($result.State -eq 'Verifying') { Move-ComponentState $result 'VerificationFailed' | Out-Null }
                Set-ComponentFailure $result $failureCode ('설치/검증 중 예외: ' + $failure) | Out-Null
                Write-RunEvent $context 'install' 'exception' $id $result.Message $failureCode $null
                continue
            }
        }
        Move-RunState $context 'RefreshingEnvironment' | Out-Null
        Update-ProcessPath | Out-Null
        Move-RunState $context 'Verifying' | Out-Null
        Move-RunState $context 'PackagingEvidence' | Out-Null
        return (Complete-RunSummary -Context $context -Selected $selected -NoSupportBundle:$NoSupportBundle -RunId $runId -JournalPath $journalPath -Preview $preview)
    } finally {
        Exit-InstallerMutex -Mutex $mutex
    }
}
