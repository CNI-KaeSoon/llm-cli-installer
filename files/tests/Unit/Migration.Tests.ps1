$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'v2 migration contracts' -Tag Unit {
    InModuleScope LLMCliInstaller {
        BeforeAll {
            function New-TestEvidence {
                param([string]$Grade, [bool]$Writable = $true)
                $all = @('FileIdentity', 'PackageInventory', 'PrefixContainment', 'ShimReference', 'PackageName', 'RemoverAvailable')
                $list = New-Object System.Collections.ArrayList
                switch ($Grade) {
                    'P3' { foreach ($kind in $all) { [void]$list.Add((New-ProvenanceEvidence -Kind $kind -Source 'fixture' -Matched $true)) } }
                    'P2' { [void]$list.Add((New-ProvenanceEvidence -Kind 'SignerAllowlist' -Source 'fixture' -Matched $true)); [void]$list.Add((New-ProvenanceEvidence -Kind 'OfficialMarker' -Source 'fixture' -Matched $true)) }
                    'P1' { [void]$list.Add((New-ProvenanceEvidence -Kind 'PackageInventory' -Source 'fixture' -Matched $true)) }
                    default { [void]$list.Add((New-ProvenanceEvidence -Kind 'OfficialMarker' -Source 'fixture' -Matched $true)) }
                }
                [void]$list.Add((New-ProvenanceEvidence -Kind 'UserWritable' -Source 'fixture' -Matched $Writable))
                return @($list)
            }
            function New-TestInventory {
                param([string]$Id = 'grok', [string]$Grade = 'P3', [int]$Count = 1, [bool]$Canonical = $false, [bool]$Reparse = $false, [bool]$Locked = $false, [bool]$Writable = $true)
                $definition = (Get-ComponentCatalog)[$Id]
                $candidates = @()
                for ($i = 0; $i -lt $Count; $i++) {
                    $prefix = 'C:\Users\fixture\npm-alt{0}' -f $i
                    $candidates += New-InstallCandidate -ComponentId $Id -Path ($prefix + '\tool.cmd') -Directory $prefix -FileIdentity ('fid' + $i) -OwnerManager 'npm' -PackageId ([string]$definition.NpmPackage) -PackageVersion '1.2.3' -EvidencePrefix $prefix -PackageMatchCount $(if ($Grade -eq 'P3') { 1 } else { 0 }) -Reparse $Reparse -Locked $Locked -IsPathWinner ($i -eq 0) -IsCanonical $Canonical -Evidence (New-TestEvidence -Grade $Grade -Writable $Writable)
                }
                return (Complete-ComponentInventory -ComponentId $Id -Candidates $candidates -Definition $definition)
            }
        }

        It 'grades provenance P0-P3 only from correlated evidence' {
            $definition = (Get-ComponentCatalog).grok
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P3') -Definition $definition -PackageMatchCount 1 | Should -Be 'P3'
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P3') -Definition $definition -PackageMatchCount 2 | Should -Not -Be 'P3'
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P2') -Definition $definition | Should -Be 'P2'
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P1') -Definition $definition | Should -Be 'P1'
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P0') -Definition $definition | Should -Be 'P0'
            # keep-only components can never reach P3 even with full npm-style evidence
            Get-ProvenanceGrade -Evidence (New-TestEvidence -Grade 'P3') -Definition (Get-ComponentCatalog).antigravity -PackageMatchCount 1 | Should -Not -Be 'P3'
        }

        It 'keep policy never plans a change for any existing install shape' {
            foreach ($case in @(@{ Grade='P3'; Canonical=$true }, @{ Grade='P3' }, @{ Grade='P0' }, @{ Grade='P3'; Count=2 }, @{ Grade='P3'; Reparse=$true })) {
                $inventory = New-TestInventory @case
                $plan = Get-MigrationDecision -ComponentId 'grok' -Inventory $inventory -Definition (Get-ComponentCatalog).grok -Policy Keep
                $plan.Decision | Should -Be 'Keep'
                $plan.StableCode | Should -Be 0
                $plan.RemoverSummary | Should -BeNullOrEmpty
            }
        }

        It 'applies the migrate decision matrix with exact block codes' {
            $definition = (Get-ComponentCatalog).grok
            $cases = @(
                @{ Args=@{ Grade='P3'; Canonical=$true }; Decision='Keep'; Action='NoOpAlreadyCanonical'; Code=0 },
                @{ Args=@{ Grade='P3'; Count=2 }; Decision='Blocked'; Action='BlockedConflict'; Code=62 },
                @{ Args=@{ Grade='P3'; Reparse=$true }; Decision='Blocked'; Action='BlockedReparsePoint'; Code=64 },
                @{ Args=@{ Grade='P0' }; Decision='Blocked'; Action='BlockedProvenance'; Code=61 },
                @{ Args=@{ Grade='P1' }; Decision='Blocked'; Action='BlockedProvenance'; Code=61 },
                @{ Args=@{ Grade='P2' }; Decision='Blocked'; Action='BlockedUnsupported'; Code=63 },
                @{ Args=@{ Grade='P3'; Writable=$false }; Decision='Blocked'; Action='BlockedUnsupported'; Code=63 },
                @{ Args=@{ Grade='P3'; Locked=$true }; Decision='Blocked'; Action='BlockedLocked'; Code=64 },
                @{ Args=@{ Grade='P3' }; Decision='Migrate'; Action='MigrateAndVerify'; Code=0 }
            )
            foreach ($case in $cases) {
                $arguments = $case.Args
                $plan = Get-MigrationDecision -ComponentId 'grok' -Inventory (New-TestInventory @arguments) -Definition $definition -Policy Migrate
                $plan.Decision | Should -Be $case.Decision
                $plan.Action | Should -Be $case.Action
                $plan.StableCode | Should -Be $case.Code
            }
            $migrate = Get-MigrationDecision -ComponentId 'grok' -Inventory (New-TestInventory) -Definition $definition -Policy Migrate
            $migrate.RemoverSummary | Should -Match '^npm uninstall -g --prefix .+ @xai-official/grok$'
            $migrate.RequiresElevation | Should -BeFalse
            $migrate.RecoveryAction | Should -Match 'npm install -g --prefix .+ @xai-official/grok@1\.2\.3'
        }

        It 'native Codex with signer evidence only is keep-only (63)' {
            $plan = Get-MigrationDecision -ComponentId 'codex' -Inventory (New-TestInventory -Id 'codex' -Grade 'P2') -Definition (Get-ComponentCatalog).codex -Policy Migrate
            $plan.StableCode | Should -Be 63
        }

        It 'walks component migration states and guards terminal states' {
            $result = New-ComponentResult -Id 'grok'
            foreach ($state in @('InventoryComplete', 'NonCanonical', 'MigrationPreviewed', 'RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified', 'Committed')) {
                Move-ComponentMigrationState $result $state | Out-Null
            }
            $result.MigrationState | Should -Be 'Committed'
            { Move-ComponentMigrationState $result 'RemovalStarted' } | Should -Throw '*terminal*'
            $early = New-ComponentResult -Id 'grok'
            foreach ($state in @('InventoryComplete', 'NonCanonical', 'MigrationPreviewed', 'RemovalStarted')) { Move-ComponentMigrationState $early $state | Out-Null }
            { Move-ComponentMigrationState $early 'ReinstallStarted' } | Should -Throw '*E_INTERNAL_STATE*'
            Move-ComponentMigrationState $early 'Removed' | Out-Null
            Move-ComponentMigrationState $early 'ReinstallStarted' | Out-Null
            Move-ComponentMigrationState $early 'Reinstalled' | Out-Null
            { Move-ComponentMigrationState $early 'Committed' } | Should -Throw '*E_INTERNAL_STATE*'
            foreach ($terminal in @('RemovalFailed', 'ReinstallFailed', 'RollbackSucceeded', 'RollbackFailed', 'RecoveryRequired')) { Test-MigrationTerminalState -State $terminal | Should -BeTrue }
        }

        It 'adds v2 run states without breaking v1 run order' {
            $run = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot $TestDrive
            foreach ($state in @('Preflight', 'Selection', 'Diagnosing', 'Inventorying', 'AwaitingMigrationDecision', 'PreviewingMigration', 'Planned', 'Migrating', 'Installing')) { Move-RunState $run $state | Out-Null }
            $recover = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot $TestDrive
            foreach ($state in @('Preflight', 'Recovering', 'Selection')) { Move-RunState $recover $state | Out-Null }
            { Move-RunState $recover 'Migrating' } | Should -Throw '*E_INTERNAL_STATE*'
        }

        It 'applies exit code precedence 65 > 68 > 67 > 66 > 60 and 50 > 64 > 62 > 61 > 63' {
            $make = { param([string]$State, [int]$Code) $r = New-ComponentResult -Id 'x'; $r.State = $State; $r.PrimaryCode = $Code; $r }
            $ok = & $make 'Verified' 0
            Get-RunExitCode -Components @($ok, (& $make 'InstallFailed' 67)) -AbortCode 65 | Should -Be 65
            Get-RunExitCode -Components @($ok, (& $make 'InstallFailed' 66), (& $make 'InstallFailed' 67)) | Should -Be 67
            Get-RunExitCode -Components @($ok, (& $make 'InstallFailed' 66)) -IncompleteCodes @(68) | Should -Be 68
            Get-RunExitCode -Components @($ok, (& $make 'InstallFailed' 66)) | Should -Be 66
            Get-RunExitCode -Components @($ok, (& $make 'Verified' 61)) | Should -Be 60
            Get-RunExitCode -Components @((& $make 'Verified' 63), (& $make 'Verified' 61)) | Should -Be 61
            Get-RunExitCode -Components @((& $make 'Verified' 61), (& $make 'Verified' 62)) | Should -Be 62
            Get-RunExitCode -Components @((& $make 'Verified' 62), (& $make 'Verified' 64)) | Should -Be 64
            Get-RunExitCode -Components @((& $make 'VerificationFailed' 50), (& $make 'Verified' 64)) | Should -Be 50
            Get-RunExitCode -Components @($ok) | Should -Be 0
        }

        It 'accepts only the exact confirmation token' {
            Test-MigrationConfirmation -Answer '이전' | Should -BeTrue
            foreach ($answer in @('', ' 이전', '이전 ', 'yes', 'B', $null)) { Test-MigrationConfirmation -Answer $answer | Should -BeFalse }
        }

        It 'changes the inventory fingerprint when lock or version changes' {
            $base = (New-TestInventory).Fingerprint
            (New-TestInventory).Fingerprint | Should -Be $base
            (New-TestInventory -Locked $true).Fingerprint | Should -Not -Be $base
            (New-TestInventory -Count 2).Fingerprint | Should -Not -Be $base
        }

        It 'writes append-only flushed journal lines and detects incomplete transactions' {
            $path = Join-Path $TestDrive 'state/migration-journal.jsonl'
            $tx1 = [guid]::NewGuid().ToString(); $tx2 = [guid]::NewGuid().ToString()
            foreach ($phase in @('RemovalStarted', 'Removed', 'ReinstallStarted', 'Reinstalled', 'MigrationVerified', 'Committed')) { Add-MigrationJournalRecord -Path $path -Record (New-JournalRecord -TransactionId $tx1 -RunId 'r' -ComponentId 'grok' -Phase $phase) | Out-Null }
            foreach ($phase in @('RemovalStarted', 'Removed')) { Add-MigrationJournalRecord -Path $path -Record (New-JournalRecord -TransactionId $tx2 -RunId 'r' -ComponentId 'grok' -Phase $phase -EvidencePath 'C:\Users\fixture\npm-alt0') | Out-Null }
            [IO.File]::AppendAllText($path, '{"schemaVersion":2,"transac')
            $journal = Read-MigrationJournal -Path $path
            $journal.Records.Count | Should -Be 8
            $journal.CorruptLineCount | Should -Be 1
            $incomplete = @(Get-IncompleteMigrationTransaction -Path $path)
            $incomplete.Count | Should -Be 1
            $incomplete[0].transactionId | Should -Be $tx2
            $incomplete[0].evidencePath | Should -Not -Match 'fixture'
            (Get-Content -LiteralPath $path -Raw) | Should -Not -Match 'C:\\\\Users\\\\fixture'
        }

        It 'reconciles each durable phase without repeating a removal' {
            $present = New-TestInventory
            $gone = Complete-ComponentInventory -ComponentId 'grok' -Candidates @() -Definition (Get-ComponentCatalog).grok
            $record = New-JournalRecord -TransactionId 't' -RunId 'r' -ComponentId 'grok' -Phase 'RemovalStarted' -PackageId '@xai-official/grok' -EvidencePath 'C:\Users\fixture\npm-alt0'
            $parsed = (ConvertTo-SafeJson $record) | ConvertFrom-Json
            Get-JournalReconcileAction -LastRecord $parsed -Inventory $present | Should -Be 'AbortRemovalIncomplete'
            Get-JournalReconcileAction -LastRecord $parsed -Inventory $gone | Should -Be 'ResumeReinstall'
            foreach ($phase in @('Removed', 'ReinstallStarted', 'ReinstallFailed')) { Get-JournalReconcileAction -LastRecord ([pscustomobject]@{ phase=$phase }) -Inventory $gone | Should -Be 'ResumeReinstall' }
            foreach ($phase in @('Reinstalled', 'MigrationVerified')) { Get-JournalReconcileAction -LastRecord ([pscustomobject]@{ phase=$phase }) -Inventory $gone | Should -Be 'VerifyAndCommit' }
        }

        It 'rolls back only the owned PATH delta with CAS and otherwise returns 67 with zero writes' {
            $sep = [IO.Path]::PathSeparator
            $snapshotValue = "\tools${sep}\home\fixture\bin"
            $snapshot = [pscustomobject]@{ Value = $snapshotValue; Hash = (Get-PathValueHash -Value $snapshotValue) }
            $root = '\home\fixture\npm'
            Mock Set-UserPathValue { }
            Mock Get-UserPathValue { "\tools${sep}\home\fixture\bin${sep}\home\fixture\npm\bin" }
            @(Get-OwnedPathDelta -SnapshotValue $snapshotValue -CurrentValue (Get-UserPathValue) -CanonicalRoots @($root)).Count | Should -Be 1
            (Restore-UserPathSnapshot -Snapshot $snapshot -CanonicalRoots @($root)).Result | Should -Be 'RollbackSucceeded'
            Should -Invoke Set-UserPathValue -Times 1 -Exactly
            Mock Get-UserPathValue { "\tools${sep}\home\fixture\bin${sep}\home\fixture\npm\bin${sep}\external" }
            $conflict = Restore-UserPathSnapshot -Snapshot $snapshot -CanonicalRoots @($root)
            $conflict.Result | Should -Be 'Conflict'
            $conflict.Code | Should -Be 67
            $conflict.WriteCount | Should -Be 0
            Should -Invoke Set-UserPathValue -Times 1 -Exactly
            Mock Get-UserPathValue { $snapshotValue }
            (Restore-UserPathSnapshot -Snapshot $snapshot -CanonicalRoots @($root)).Result | Should -Be 'NoChange'
        }

        It 'builds only official remover shapes and rejects ranges and purge' {
            (Get-NpmUninstallArgumentList -Prefix 'C:\npm-alt' -Package '@openai/codex') -join ' ' | Should -Be 'uninstall -g --prefix C:\npm-alt @openai/codex'
            foreach ($package in @('@openai/codex', '@anthropic-ai/claude-code', '@xai-official/grok', '@google/gemini-cli')) { { Get-NpmUninstallArgumentList -Prefix 'C:\p' -Package $package } | Should -Not -Throw }
            { Get-NpmUninstallArgumentList -Prefix 'C:\p' -Package 'left-pad' } | Should -Throw '*allowlisted*'
            { Get-NpmUninstallArgumentList -Prefix 'relative' -Package '@openai/codex' } | Should -Throw '*absolute*'
            (Get-PyManagerUninstallArgumentList -Tag '3.12') -join ' ' | Should -Be 'uninstall --yes 3.12'
            $purgeFlag = '--' + 'purge'
            foreach ($tag in @('3', '3.*', '>=3.12', '3.12,3.13', $purgeFlag, '3.12 --yes')) { { Get-PyManagerUninstallArgumentList -Tag $tag } | Should -Throw '*exact*' }
            { Invoke-ComponentRemoval -Candidate ([pscustomobject]@{ ProvenanceGrade='P2'; OwnerManager='npm' }) } | Should -Throw '*P3*'
        }

        It 'validates migration arguments before any write (exit 2 contract)' {
            $catalog = Get-ComponentCatalog
            $ordered = @('powershell', 'python', 'node', 'grok')
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -MigrationComponents @('grok') -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Keep' -ConfirmMigration -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -MigrationComponents @('codex') -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -MigrationComponents @('node') -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Replace' -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*'
            (Resolve-ExistingInstallPolicy -Ordered $ordered -Catalog $catalog).Policy | Should -Be 'Keep'
            $saved = $script:MigrationGateOpen
            try {
                $script:MigrationGateOpen = $true
                (Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -MigrationComponents @('grok', 'python') -Ordered $ordered -Catalog $catalog).Components | Should -Be @('grok', 'python')
            } finally { $script:MigrationGateOpen = $saved }
        }

        It 'keeps migration disabled by the release gate by default (§14.8)' {
            $catalog = Get-ComponentCatalog
            $ordered = @('powershell', 'python', 'node', 'grok')
            $script:MigrationGateOpen | Should -BeFalse
            { Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -MigrationComponents @('grok') -Ordered $ordered -Catalog $catalog } | Should -Throw '*E_INVALID_ARGUMENT*Windows*'
            (Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Migrate' -ConfirmMigration -MigrationComponents @('grok') -Ordered $ordered -Catalog $catalog -PreviewOnly).Policy | Should -Be 'Migrate'
            (Resolve-ExistingInstallPolicy -ExistingInstallPolicy 'Keep' -Ordered $ordered -Catalog $catalog).Policy | Should -Be 'Keep'
        }

        It 'never calls any UacHelper function on the migration path' {
            Mock Test-ElevatedOperationAllowed { $true }
            Mock Invoke-ValidatedElevatedOperation { }
            Mock Start-Process { }
            $script:uacInventory = New-TestInventory
            Mock Get-ComponentInventory { $script:uacInventory }
            Mock Invoke-NpmUninstall { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=0; CommandSummary='npm uninstall' }; StableCode=0; RestartRequired=$false } }
            Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=0; CommandSummary='install' }; StableCode=0; RestartRequired=$false } }
            Mock Test-ComponentInstallation { [pscustomobject]@{ Success=$true; Version='2.0.0'; Process=[pscustomobject]@{ ResolvedPath='tool'; ExitCode=0 }; Status='Verified'; Code=0 } }
            Mock Update-ProcessPath { }
            Mock Get-UserPathValue { '\tools' }
            Mock Set-UserPathValue { }
            $context = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot (Join-Path $TestDrive 'uac-logs')
            Initialize-RunLogging -Context $context -RequestedRoot (Join-Path $TestDrive 'uac-logs') | Out-Null
            $definition = (Get-ComponentCatalog).grok
            $plan = Get-MigrationDecision -ComponentId 'grok' -Inventory $script:uacInventory -Definition $definition -Policy Migrate
            $result = New-ComponentResult -Id 'grok'
            $result.State = 'Planned'
            Set-ComponentMigrationFromPlan -Result $result -Plan $plan | Out-Null
            $outcome = Invoke-ComponentMigration -Context $context -Result $result -Plan $plan -Definition $definition -JournalPath (Join-Path $TestDrive 'uac-state/journal.jsonl') -StateRoot (Join-Path $TestDrive 'uac-state') -NonInteractive
            $outcome.FinalState | Should -Be 'Committed'
            Should -Invoke Invoke-NpmUninstall -Times 1 -Exactly
            Should -Invoke Test-ElevatedOperationAllowed -Times 0 -Exactly
            Should -Invoke Invoke-ValidatedElevatedOperation -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'terminates a torn journal tail before appending so both records survive' {
            $path = Join-Path $TestDrive 'torn/migration-journal.jsonl'
            Add-MigrationJournalRecord -Path $path -Record (New-JournalRecord -TransactionId 't1' -RunId 'r' -ComponentId 'grok' -Phase 'Committed') | Out-Null
            [IO.File]::AppendAllText($path, '{"schemaVersion":2,"transac')
            Add-MigrationJournalRecord -Path $path -Record (New-JournalRecord -TransactionId 't2' -RunId 'r' -ComponentId 'grok' -Phase 'RemovalStarted') | Out-Null
            $journal = Read-MigrationJournal -Path $path
            $journal.Records.Count | Should -Be 2
            $journal.CorruptLineCount | Should -Be 1
            @(Get-IncompleteMigrationTransaction -Path $path)[0].transactionId | Should -Be 't2'
        }

        It 'resolves the codex canonical root to the official installer default when CODEX_INSTALL_DIR is unset' {
            $saved = $env:CODEX_INSTALL_DIR
            try {
                Remove-Item Env:CODEX_INSTALL_DIR -ErrorAction SilentlyContinue
                $roots = @(Get-ComponentCanonicalRoot -Definition (Get-ComponentCatalog).codex)
                $roots.Count | Should -BeGreaterThan 0
                $roots[0] | Should -BeLike '*Programs*OpenAI*Codex*bin'
                $env:CODEX_INSTALL_DIR = Join-Path $TestDrive 'codex-bin'
                @(Get-ComponentCanonicalRoot -Definition (Get-ComponentCatalog).codex) | Should -Be @((Join-Path $TestDrive 'codex-bin'))
            } finally {
                if ($null -ne $saved) { $env:CODEX_INSTALL_DIR = $saved } else { Remove-Item Env:CODEX_INSTALL_DIR -ErrorAction SilentlyContinue }
            }
        }

        It 'npm candidate with package-root or signer mismatch never grades P3/P2' {
            $definition = (Get-ComponentCatalog).grok
            $directory = Join-Path $TestDrive 'npm-mismatch/bin'
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            $shim = Join-Path $directory 'grok.cmd'
            [IO.File]::WriteAllText($shim, 'node "%~dp0\node_modules\@xai-official\grok\bin\grok.js" %*')
            Mock Get-NpmGlobalPackageInventory { @{ '@xai-official/grok' = '1.2.3' } }
            $npm = Get-NpmCandidateEvidence -Path $shim -Directory $directory -Definition $definition
            @($npm.Evidence | Where-Object { $_.Kind -eq 'PrefixContainment' })[0].Matched | Should -BeFalse
            Get-ProvenanceGrade -Evidence $npm.Evidence -Definition $definition -PackageMatchCount $npm.MatchCount | Should -Be 'P1'
            $signerMismatch = @($npm.Evidence) + @((New-ProvenanceEvidence -Kind 'SignerAllowlist' -Source 'fixture' -Matched $false), (New-ProvenanceEvidence -Kind 'OfficialMarker' -Source 'fixture' -Matched $true))
            Get-ProvenanceGrade -Evidence $signerMismatch -Definition $definition -PackageMatchCount $npm.MatchCount | Should -Not -BeIn @('P2', 'P3')
        }

        It 'resolves npm to an Application shim and prefers .cmd/.exe' {
            Mock Get-Command { @([pscustomobject]@{ Source = 'C:\nodejs\npm' }, [pscustomobject]@{ Source = 'C:\nodejs\npm.cmd' }) } -ParameterFilter { $CommandType -eq 'Application' }
            (Resolve-ApplicationCommand -FilePath 'npm').Source | Should -Be 'C:\nodejs\npm.cmd'
            Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $CommandType -eq 'Application' }
            Mock Get-Command { @() } -ParameterFilter { $CommandType -eq 'Application' }
            Resolve-ApplicationCommand -FilePath 'npm' | Should -BeNullOrEmpty
        }

        It 'logs only allowlisted scalar migration fields' {
            $context = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot (Join-Path $TestDrive 'logs')
            Initialize-RunLogging -Context $context -RequestedRoot (Join-Path $TestDrive 'logs') | Out-Null
            Write-RunEvent $context 'migrate' 'test' 'grok' 'm' 0 $null @{ decision='Migrate'; provenanceGrade='P3'; candidateCount=1; rawPath='C:\Users\fixture\secret'; evidence=@('x') }
            $logged = (Get-Content -LiteralPath $context.JsonLog | Select-Object -Last 1) | ConvertFrom-Json
            $logged.schemaVersion | Should -Be 2
            $logged.decision | Should -Be 'Migrate'
            $logged.provenanceGrade | Should -Be 'P3'
            @($logged.PSObject.Properties.Name) | Should -Not -Contain 'rawPath'
            @($logged.PSObject.Properties.Name) | Should -Contain 'stage'
        }

        It 'product source contains no recursive delete, forced kill or purge' {
            $appRoot = Join-Path $script:ModuleRoot '../..'
            $recursiveDelete = 'Remove-' + 'Item.*-Rec' + 'urse'
            $forcedKill = 'Stop-' + 'Process.*-Fo' + 'rce'
            $patterns = @($recursiveDelete, ('task' + 'kill'), $forcedKill, ('--' + 'purge'))
            $files = @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'src') -Recurse -File) + @(Get-Item -LiteralPath (Join-Path $appRoot 'install.ps1')) + @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'tools') -File)
            foreach ($file in $files) {
                $text = [IO.File]::ReadAllText($file.FullName)
                foreach ($pattern in $patterns) { $text | Should -Not -Match $pattern -Because $file.Name }
            }
        }

        It 'T7-1: the elevation helper is hard-disabled and never starts a process' {
            Mock Start-Process { }
            { Invoke-ValidatedElevatedOperation -Operation 'winget-install' -Arguments @{} } | Should -Throw '*disabled*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'T6-1: Get-CertificateOrganization parses quoted and plain O values exactly' {
            Get-CertificateOrganization -Subject 'CN=x, O="Anthropic, PBC", C=US' | Should -Be 'Anthropic, PBC'
            $fake = Get-CertificateOrganization -Subject 'CN=a, O=Google LLC Holdings Fake, C=US'
            $fake | Should -Be 'Google LLC Holdings Fake'
            @($script:SignerSubjectAllowlist['antigravity']) | Should -Not -Contain $fake
            Get-CertificateOrganization -Subject 'CN=a' | Should -BeNullOrEmpty
        }

        It 'T5-1: exit code judges only the selected components when SelectedIds is given' {
            $make = { param([string]$Id, [string]$State, [int]$Code) $r = New-ComponentResult -Id $Id; $r.State = $State; $r.PrimaryCode = $Code; $r }
            $components = @((& $make 'powershell' 'Verified' 0), (& $make 'python' 'Verified' 0), (& $make 'codex' 'InstallFailed' 40))
            Get-RunExitCode -Components $components -SelectedIds @('codex') | Should -Be 40
            Get-RunExitCode -Components $components | Should -Be 60
        }
    }
}
