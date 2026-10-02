$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'v2 migration orchestration with fake package managers' -Tag Integration {
    InModuleScope LLMCliInstaller {
        BeforeAll {
            function New-FixtureInventory {
                param([string]$Id, [string]$Grade = 'P3', [string]$Owner = 'npm', [string]$PackageId, [bool]$Locked = $false, [bool]$Canonical = $false)
                $definition = (Get-ComponentCatalog)[$Id]
                if (-not $PackageId) { $PackageId = [string]$definition.NpmPackage }
                $evidence = New-Object System.Collections.ArrayList
                if ($Grade -eq 'P3') { foreach ($kind in @('FileIdentity', 'PackageInventory', 'PrefixContainment', 'ShimReference', 'PackageName', 'RemoverAvailable')) { [void]$evidence.Add((New-ProvenanceEvidence -Kind $kind -Source 'fake' -Matched $true)) } }
                [void]$evidence.Add((New-ProvenanceEvidence -Kind 'UserWritable' -Source 'fake' -Matched $true))
                $prefix = 'C:\Users\fixture\npm-alt'
                $candidate = New-InstallCandidate -ComponentId $Id -Path ($prefix + '\tool.cmd') -Directory $prefix -FileIdentity 'fid' -OwnerManager $Owner -PackageId $PackageId -PackageVersion '1.2.3' -EvidencePrefix $prefix -PackageMatchCount $(if ($Grade -eq 'P3') { 1 } else { 0 }) -Locked $Locked -IsPathWinner $true -IsCanonical $Canonical -Evidence @($evidence)
                return (Complete-ComponentInventory -ComponentId $Id -Candidates @($candidate) -Definition $definition)
            }
            function Get-FixtureJournal {
                $path = Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl'
                return @((Read-MigrationJournal -Path $path).Records)
            }
            function Add-FixtureJournalPhases {
                param([string[]]$Phases, [string]$ComponentId = 'grok')
                $path = Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl'
                $transactionId = [guid]::NewGuid().ToString()
                foreach ($phase in $Phases) {
                    Add-MigrationJournalRecord -Path $path -Record (New-JournalRecord -TransactionId $transactionId -RunId 'crashed-run' -ComponentId $ComponentId -Phase $phase -ProvenanceGrade 'P3' -PackageManager 'npm' -PackageId '@xai-official/grok' -OldVersion '1.2.3' -EvidencePath 'C:\Users\fixture\npm-alt' -RecoveryAction 'npm install -g --prefix %USERPROFILE%\npm-alt @xai-official/grok@1.2.3') | Out-Null
                }
                return $transactionId
            }
        }

        BeforeEach {
            # These tests exercise the migration engine itself, so the §14.8 release gate is opened here only.
            $script:MigrationGateOpen = $true
            $stateRoot = Join-Path $TestDrive 'state'
            if (Test-Path -LiteralPath (Join-Path $stateRoot 'migration-journal.jsonl')) { Remove-Item -LiteralPath (Join-Path $stateRoot 'migration-journal.jsonl') -Force }
            $script:fixture = @{ GrokInventory = $null; InventoryCalls = 0; StaleAfter = 0; PathValues = @('\tools'); PathCalls = 0; InstallCode = 0; RemoveCode = 0 }
            $script:fixture.GrokInventory = New-FixtureInventory -Id 'grok'
            Mock Get-PlatformDiagnostic { [pscustomobject]@{ IsWindows=$true; Architecture='AMD64'; IsSupported=$true; Build=26100; PowerShellVersion='5.1'; IsAdministrator=$false } }
            Mock Get-MigrationStateRoot { Join-Path $TestDrive 'state' }
            Mock Get-NpmEffectivePrefix { 'C:\Users\fixture\AppData\Roaming\npm' }
            Mock Get-PyManagerManagedRuntime { @() }
            Mock Get-ComponentStatus { [pscustomobject]@{ State='Satisfied'; Verification=[pscustomobject]@{ Version='1.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool' } } } }
            Mock Get-ComponentInventory {
                if ($Id -ne 'grok' -or -not $script:fixture.GrokInventory) { return (Complete-ComponentInventory -ComponentId $Id -Candidates @() -Definition $Definition) }
                $script:fixture.InventoryCalls++
                if ($script:fixture.StaleAfter -gt 0 -and $script:fixture.InventoryCalls -gt $script:fixture.StaleAfter) { return (New-FixtureInventory -Id 'grok' -Locked $true) }
                return $script:fixture.GrokInventory
            }
            Mock Invoke-NpmUninstall { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=$script:fixture.RemoveCode; CommandSummary='npm uninstall' }; StableCode=$(if ($script:fixture.RemoveCode -eq 0) { 0 } else { 40 }); RestartRequired=$false } }
            Mock Invoke-PyManagerUninstall { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=0; CommandSummary='pymanager uninstall' }; StableCode=0; RestartRequired=$false } }
            Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=$script:fixture.InstallCode; StdErr=''; StdOut=''; CommandSummary='install' }; StableCode=$(if ($script:fixture.InstallCode -eq 0) { 0 } else { 40 }); RestartRequired=$false } }
            Mock Test-ComponentInstallation { [pscustomobject]@{ Success=$true; Version='2.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool'; ExitCode=0 }; Status='Verified'; Code=0 } }
            Mock Update-ProcessPath { }
            Mock Get-UserPathValue {
                $script:fixture.PathCalls++
                $index = [Math]::Min($script:fixture.PathCalls, $script:fixture.PathValues.Count) - 1
                return $script:fixture.PathValues[$index]
            }
            Mock Set-UserPathValue { }
            Mock Enter-InstallerMutex { [pscustomobject]@{ Held = $true } }
            Mock Exit-InstallerMutex { }
            $script:logs = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
        }

        It 'keep default leaves a P3 noncanonical install untouched (zero uninstall/install/PATH writes)' {
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
            Should -Invoke Set-UserPathValue -Times 0 -Exactly
            Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') | Should -BeFalse
        }

        It 'migrates a P3 npm install with official remover then canonical reinstall and commit' {
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            $grok = $result.Components | Where-Object Id -eq 'grok'
            $grok.MigrationState | Should -Be 'Committed'
            $grok.State | Should -Be 'Verified'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'C:\Users\fixture\npm-alt' -and $Package -eq '@xai-official/grok' }
            Should -Invoke Install-Component -Times 1 -Exactly -ParameterFilter { $Id -eq 'grok' }
            $journal = Get-FixtureJournal
            @($journal.phase) | Should -Be @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified', 'Committed')
            $journal[-1].commit | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') -Raw) | Should -Not -Match 'fixture'
            Test-Path -LiteralPath (Join-Path $result.LogDirectory 'migration-journal.sanitized.jsonl') | Should -BeTrue
        }

        It 'rejects Migrate without ConfirmMigration or with unsupported components before any write' {
            { Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents node -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents codex -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Invoke-LlmCliInstaller -Components all -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*'
            Test-Path -LiteralPath $script:logs | Should -BeFalse
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
        }

        It 'blocks P0 provenance with 61 and keeps other components (run 61: no selected CLI succeeded)' {
            $script:fixture.GrokInventory = New-FixtureInventory -Id 'grok' -Grade 'P0'
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            ($result.Components | Where-Object Id -eq 'grok').PrimaryCode | Should -Be 61
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'MigrationBlocked'
            $result.ExitCode | Should -Be 61
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
        }

        It 'aborts with 65 and zero removals when the fingerprint changes before the first change' {
            $script:fixture.StaleAfter = 1
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 65
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
        }

        It 'exits 65 with zero changes when the installer mutex is already held' {
            Mock Enter-InstallerMutex { $null }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 65
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
        }

        It 'removal failure starts no install and closes the journal' {
            $script:fixture.RemoveCode = 1
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'RemovalFailed'
            Should -Invoke Install-Component -Times 0 -Exactly
            Should -Invoke Set-UserPathValue -Times 0 -Exactly
            (Get-FixtureJournal)[-1].phase | Should -Be 'RemovalFailed'
            @(Get-IncompleteMigrationTransaction -Path (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl')).Count | Should -Be 0
        }

        It 'reinstall failure ends 66 with recovery command and incomplete journal, no auto rollback' {
            $script:fixture.InstallCode = 1
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle -WarningAction SilentlyContinue
            $result.ExitCode | Should -Be 66
            $grok = $result.Components | Where-Object Id -eq 'grok'
            $grok.MigrationState | Should -Be 'ReinstallFailed'
            $grok.RecoveryAction | Should -Match 'npm install -g --prefix .+ @xai-official/grok@1\.2\.3'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly
            Should -Invoke Set-UserPathValue -Times 0 -Exactly
            @(Get-IncompleteMigrationTransaction -Path (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl')).Count | Should -Be 1
        }

        It 'reinstall failure with an external PATH change returns 67 and never overwrites PATH' {
            $sep = [IO.Path]::PathSeparator
            $script:fixture.InstallCode = 1
            $script:fixture.PathValues = @('\tools', "\tools${sep}\external\new")
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle -WarningAction SilentlyContinue
            $result.ExitCode | Should -Be 67
            Should -Invoke Set-UserPathValue -Times 0 -Exactly
        }

        It 'reinstall failure reverts only the owned PATH delta under the canonical root' {
            $sep = [IO.Path]::PathSeparator
            $script:fixture.InstallCode = 1
            Mock Get-ComponentInventory {
                $inventory = $(if ($Id -eq 'grok') { $script:fixture.GrokInventory } else { Complete-ComponentInventory -ComponentId $Id -Candidates @() -Definition $Definition })
                $inventory.CanonicalRoots = @('\canonical\npm')
                return $inventory
            }
            $script:fixture.PathValues = @('\tools', "\tools${sep}\canonical\npm")
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle -WarningAction SilentlyContinue
            $result.ExitCode | Should -Be 66
            Should -Invoke Set-UserPathValue -Times 1 -Exactly -ParameterFilter { $Value -eq '\tools' }
        }

        It 'crash after <Phases> reruns with zero removals and exactly one reinstall, then commits' -ForEach @(
            @{ Phases = @('RemovalStarted', 'Removed') },
            @{ Phases = @('RemovalStarted', 'Removed', 'ReinstallStarted') },
            @{ Phases = @('RemovalStarted', 'Removed', 'ReinstallStarted', 'ReinstallFailed') }
        ) {
            $script:fixture.GrokInventory = $null
            $transactionId = Add-FixtureJournalPhases -Phases $Phases
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 1 -Exactly -ParameterFilter { $Id -eq 'grok' }
            $last = @(Get-FixtureJournal | Where-Object transactionId -eq $transactionId)[-1]
            $last.phase | Should -Be 'Committed'
            $last.commit | Should -BeTrue
        }

        It 'crash after RemovalStarted with package gone resumes reinstall without removing again' {
            $script:fixture.GrokInventory = $null
            Add-FixtureJournalPhases -Phases @('RemovalStarted') | Out-Null
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 1 -Exactly -ParameterFilter { $Id -eq 'grok' }
        }

        It 'crash after RemovalStarted with package still present aborts without remove or install, even under Migrate' {
            Add-FixtureJournalPhases -Phases @('RemovalStarted') | Out-Null
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.Recovery[0].FinalState | Should -Be 'Aborted'
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
        }

        It 'crash after <Phases> verifies and commits with zero removals and zero installs' -ForEach @(
            @{ Phases = @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled') },
            @{ Phases = @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified') }
        ) {
            $script:fixture.GrokInventory = $null
            $transactionId = Add-FixtureJournalPhases -Phases $Phases
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
            @(Get-FixtureJournal | Where-Object transactionId -eq $transactionId)[-1].phase | Should -Be 'Committed'
        }

        It 'failed recovery keeps 66 and blocks new changes in the same run' {
            $script:fixture.GrokInventory = $null
            $script:fixture.InstallCode = 1
            Add-FixtureJournalPhases -Phases @('RemovalStarted', 'Removed') | Out-Null
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle -WarningAction SilentlyContinue
            $result.ExitCode | Should -Be 66
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Get-ComponentStatus -Times 0 -Exactly
        }

        It 'committed journal rerun under Migrate performs no uninstall and no install (already canonical)' {
            Add-FixtureJournalPhases -Phases @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified', 'Committed') | Out-Null
            $script:fixture.GrokInventory = New-FixtureInventory -Id 'grok' -Canonical $true
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'
            $result.ExitCode | Should -Be 0
            @($result.Recovery).Count | Should -Be 0
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
        }

        It 'WhatIf previews the migration with zero removals, installs and journal writes' {
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle -WhatIf
            $result.ExitCode | Should -Be 0
            $row = @($result.MigrationPreview | Where-Object { $_.componentId -eq 'grok' })[0]
            $row.decision | Should -Be 'Migrate'
            $row.remover | Should -Match 'npm uninstall -g --prefix'
            $row.currentPath | Should -Not -Match 'fixture'
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
            Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') | Should -BeFalse
        }

        It 'python is outside a grok-only run, so migrating it is rejected (Windows installs only what was selected)' {
            { Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents python -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*'
            Should -Invoke Invoke-PyManagerUninstall -Times 0 -Exactly
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
        }

        Context 'release gate closed (§14.8)' {
            BeforeEach { $script:MigrationGateOpen = $false }

            It 'rejects non-interactive Migrate with E_INVALID_ARGUMENT before any write' {
                { Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INVALID_ARGUMENT*Windows*'
                Test-Path -LiteralPath $script:logs | Should -BeFalse
                Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
                Should -Invoke Install-Component -Times 0 -Exactly
                Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') | Should -BeFalse
            }

            It 'still allows a WhatIf preview with zero changes' {
                $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle -WhatIf
                $result.ExitCode | Should -Be 0
                Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
                Test-Path -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') | Should -BeFalse
            }

            It 'T5-3: does not offer the interactive B choice while the gate is closed and keeps the install' {
                Mock Read-Host { if ($Prompt -like '*A/B*') { 'B' } else { '이전' } }
                { $script:t53 = Invoke-LlmCliInstaller -Components grok -LogRoot $script:logs -NoSupportBundle } | Should -Not -Throw
                $script:t53.ExitCode | Should -Be 0
                ($script:t53.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'
                Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { $Prompt -like '*A/B*' }
                Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
                Should -Invoke Install-Component -Times 0 -Exactly
            }
        }

        Context 'component exception isolation (WP2)' {
            BeforeEach {
                $script:fixture.GrokInventory = $null
                Mock Get-ComponentStatus {
                    if (@('codex', 'grok') -contains $Id) { return [pscustomobject]@{ State='Missing'; Verification=$null } }
                    [pscustomobject]@{ State='Satisfied'; Verification=[pscustomobject]@{ Version='1.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool' } } }
                }
                $script:okInstall = { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=0; StdErr=''; StdOut=''; CommandSummary='install' }; StableCode=0; RestartRequired=$false } }
            }

            It 'T2-1: an E_NETWORK exception in one component is recorded as 20 and the next component still installs' {
                Mock Install-Component { if ($Id -eq 'codex') { throw 'E_NETWORK: simulated' }; & $script:okInstall }
                $result = Invoke-LlmCliInstaller -Components codex, grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
                $codex = $result.Components | Where-Object Id -eq 'codex'
                $codex.PrimaryCode | Should -Be 20
                $codex.State | Should -Be 'InstallFailed'
                ($result.Components | Where-Object Id -eq 'grok').State | Should -Be 'Verified'
                Should -Invoke Install-Component -Times 1 -Exactly -ParameterFilter { $Id -eq 'grok' }
                $result.ExitCode | Should -Be 60
                Test-Path -LiteralPath (Join-Path $result.LogDirectory 'summary.json') | Should -BeTrue
            }

            It 'T2-2: E_INTEGRITY maps to 23 and a throwing verifier fails only that component' {
                Mock Install-Component { if ($Id -eq 'codex') { throw 'E_INTEGRITY: x' }; & $script:okInstall }
                $first = Invoke-LlmCliInstaller -Components codex -NonInteractive -LogRoot $script:logs -NoSupportBundle
                ($first.Components | Where-Object Id -eq 'codex').PrimaryCode | Should -Be 23

                Mock Install-Component { & $script:okInstall }
                Mock Test-ComponentInstallation { throw 'verifier crashed' } -ParameterFilter { $Id -eq 'grok' }
                $second = Invoke-LlmCliInstaller -Components codex, grok -NonInteractive -LogRoot (Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))) -NoSupportBundle
                $grok = $second.Components | Where-Object Id -eq 'grok'
                $grok.State | Should -Be 'VerificationFailed'
                $grok.PrimaryCode | Should -Be 40
                ($second.Components | Where-Object Id -eq 'codex').State | Should -Be 'Verified'
                $second.ExitCode | Should -Be 60
            }

            It 'T1-9: the installer download and executed hashes are copied onto the component result' {
                $script:t19Sha = 'a' * 64
                $script:t19Exec = 'b' * 64
                Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=0; StdErr=''; StdOut=''; CommandSummary='install'; InstallerDownloadSha256=$script:t19Sha; InstallerExecutedSha256=$script:t19Exec; InstallerFinalHost='releases.openai.com'; InstallerBytes=14 }; StableCode=0; RestartRequired=$false } }
                $result = Invoke-LlmCliInstaller -Components codex -NonInteractive -LogRoot $script:logs -NoSupportBundle
                $codex = $result.Components | Where-Object Id -eq 'codex'
                $codex.InstallerDownloadSha256 | Should -Be $script:t19Sha
                $codex.InstallerExecutedSha256 | Should -Be $script:t19Exec
            }

            It 'T2-3: E_INTERNAL_STATE is an invariant violation and still escapes the run' {
                Mock Install-Component { throw 'E_INTERNAL_STATE: x' }
                { Invoke-LlmCliInstaller -Components codex -NonInteractive -LogRoot $script:logs -NoSupportBundle } | Should -Throw '*E_INTERNAL_STATE*'
            }

            It 'T2-4: a 20,000 character stderr is truncated to its tail in the recorded message' {
                Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=1; StdErr=('x' * 20000); StdOut=''; CommandSummary='install' }; StableCode=40; RestartRequired=$false } }
                $result = Invoke-LlmCliInstaller -Components codex -NonInteractive -LogRoot $script:logs -NoSupportBundle
                $codex = $result.Components | Where-Object Id -eq 'codex'
                $codex.Message.Length | Should -BeLessOrEqual 4100
                $codex.Message | Should -BeLike '[[]TRUNCATED]*'
            }
        }

        It 'keep run exits 65 with zero installs when the installer mutex is unavailable' {
            Mock Get-ComponentStatus { if ($Id -eq 'grok') { return [pscustomobject]@{ State='Missing'; Verification=$null } }; [pscustomobject]@{ State='Satisfied'; Verification=[pscustomobject]@{ Version='1.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool' } } } }
            Mock Enter-InstallerMutex { $null }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 65
            Should -Invoke Install-Component -Times 0 -Exactly
            Should -Invoke Get-ComponentStatus -Times 0 -Exactly
        }

        It 'installer throwing after Removed ends 66 with ReinstallFailed and a recovery warning' {
            Mock Install-Component { throw 'E_NETWORK: simulated download failure' }
            Mock Write-Warning { }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 66
            (Get-FixtureJournal)[-1].phase | Should -Be 'ReinstallFailed'
            @(Get-IncompleteMigrationTransaction -Path (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl')).Count | Should -Be 1
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match 'npm install -g --prefix .+ @xai-official/grok@1\.2\.3' }
        }

        It 'verification <Mode> after reinstall ends 66 without Committed' -ForEach @(@{ Mode = 'failure' }, @{ Mode = 'exception' }) {
            if ($Mode -eq 'exception') { Mock Test-ComponentInstallation { throw 'verifier crashed' } -ParameterFilter { $Id -eq 'grok' } }
            else { Mock Test-ComponentInstallation { [pscustomobject]@{ Success=$false; Version=$null; Process=[pscustomobject]@{ ResolvedPath=$null; ExitCode=1 }; Status='VerificationFailed'; Code=50 } } -ParameterFilter { $Id -eq 'grok' } }
            Mock Write-Warning { }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 66
            $phases = @((Get-FixtureJournal).phase)
            $phases | Should -Not -Contain 'Committed'
            $phases[-1] | Should -Be 'ReinstallFailed'
            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It 'console shows the raw recovery command while journal, events and summary keep the masked form' {
            $script:fixture.InstallCode = 1
            Mock Write-Warning { }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*C:\Users\fixture\npm-alt @xai-official/grok@1.2.3*' -and $Message -notlike '*%USERPROFILE%*' }
            ($result.Components | Where-Object Id -eq 'grok').RecoveryAction | Should -BeLike '*C:\Users\fixture\npm-alt*'
            $persisted = @(
                (Get-Content -LiteralPath (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl') -Raw),
                (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'events.jsonl') -Raw),
                (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'summary.json') -Raw)
            )
            foreach ($text in $persisted) {
                $text | Should -Not -Match 'fixture'
                $text | Should -Match '%USERPROFILE%'
            }
        }

        It 'incomplete journal for an unknown component is unreconcilable (66) and blocks every new change' {
            Add-FixtureJournalPhases -Phases @('RemovalStarted', 'Removed') -ComponentId 'not-a-component' | Out-Null
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 66
            $result.Recovery[0].FinalState | Should -Be 'Unreconcilable'
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            Should -Invoke Install-Component -Times 0 -Exactly
        }

        It 'successful recovery forces Keep for the rest of the run and tells the user to rerun' {
            $transactionId = Add-FixtureJournalPhases -Phases @('RemovalStarted', 'Removed')
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 0
            @(Get-FixtureJournal | Where-Object transactionId -eq $transactionId)[-1].phase | Should -Be 'Committed'
            Should -Invoke Install-Component -Times 1 -Exactly
            Should -Invoke Invoke-NpmUninstall -Times 0 -Exactly
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'
            (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'events.jsonl') -Raw) | Should -Match 'migration-deferred'
        }

        It 'remover failure that partially removed the package leaves the journal open with 66, then a rerun reinstalls' {
            Mock Invoke-NpmUninstall {
                $script:fixture.GrokInventory = $null
                [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=1; CommandSummary='npm uninstall' }; StableCode=40; RestartRequired=$false }
            }
            Mock Write-Warning { }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            $result.ExitCode | Should -Be 66
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'RecoveryRequired'
            (Get-FixtureJournal)[-1].phase | Should -Be 'RecoveryRequired'
            @(Get-IncompleteMigrationTransaction -Path (Join-Path (Join-Path $TestDrive 'state') 'migration-journal.jsonl')).Count | Should -Be 1
            Should -Invoke Install-Component -Times 0 -Exactly
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match 'npm install -g --prefix' }
            $rerun = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot (Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))) -NoSupportBundle
            $rerun.ExitCode | Should -Be 0
            (Get-FixtureJournal)[-1].phase | Should -Be 'Committed'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly
            Should -Invoke Install-Component -Times 1 -Exactly
        }

        It 'blocks Claude with code 40 when its Git dependency fails (v1 DAG)' {
            Mock Get-ComponentStatus {
                if (@('git', 'claude') -contains $Id) { return [pscustomobject]@{ State='Missing'; Verification=$null } }
                [pscustomobject]@{ State='Satisfied'; Verification=[pscustomobject]@{ Version='1.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool' } } }
            }
            Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=1; StdErr='failed'; StdOut=''; CommandSummary='winget install' }; StableCode=21; RestartRequired=$false } }
            $result = Invoke-LlmCliInstaller -Components claude -NonInteractive -LogRoot $script:logs -NoSupportBundle
            ($result.Components | Where-Object Id -eq 'git').PrimaryCode | Should -Be 21
            $claude = $result.Components | Where-Object Id -eq 'claude'
            $claude.PrimaryCode | Should -Be 40
            $claude.State | Should -Be 'UnattemptedBlocked'
            Should -Invoke Install-Component -Times 0 -Exactly -ParameterFilter { $Id -eq 'claude' }
            $result.ExitCode | Should -Be 21
        }

        It 'interactive B plus the exact token migrates; A keeps; a near-miss token keeps' {
            Mock Read-Host { if ($Prompt -like '*A/B*') { 'B' } else { '이전' } }
            $migrated = Invoke-LlmCliInstaller -Components grok -LogRoot $script:logs -NoSupportBundle
            ($migrated.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'Committed'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly

            Mock Read-Host { 'A' }
            $kept = Invoke-LlmCliInstaller -Components grok -LogRoot (Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))) -NoSupportBundle
            ($kept.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'

            Mock Read-Host { if ($Prompt -like '*A/B*') { 'B' } else { '이전 ' } }
            $declined = Invoke-LlmCliInstaller -Components grok -LogRoot (Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))) -NoSupportBundle
            ($declined.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'KeepSelected'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly
        }

        It 'leaves config, auth and session fixture files byte- and mtime-identical after a migrate run (remover 호출 범위와 삭제 호출 0건)' {
            $profileRoot = Join-Path $TestDrive 'profile/.grok'
            [IO.Directory]::CreateDirectory((Join-Path $profileRoot 'sessions')) | Out-Null
            $files = @((Join-Path $profileRoot 'config.json'), (Join-Path $profileRoot 'auth.json'), (Join-Path $profileRoot 'sessions/s1.jsonl'))
            foreach ($file in $files) { [IO.File]::WriteAllText($file, ('fixture-' + [IO.Path]::GetFileName($file))) }
            $before = @($files | ForEach-Object { '{0}|{1}' -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash, (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks })
            Mock Remove-Item { }
            $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -ExistingInstallPolicy Migrate -ConfirmMigration -MigrationComponents grok -LogRoot $script:logs -NoSupportBundle
            ($result.Components | Where-Object Id -eq 'grok').MigrationState | Should -Be 'Committed'
            Should -Invoke Remove-Item -Times 0 -Exactly
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly -ParameterFilter { $Package -eq '@xai-official/grok' -and $Prefix -notmatch '\.grok' }
            $after = @($files | ForEach-Object { '{0}|{1}' -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash, (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks })
            $after | Should -Be $before
        }
    }
}
