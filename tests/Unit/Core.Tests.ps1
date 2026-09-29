$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'LLM CLI Installer core contracts' -Tag Unit {
    InModuleScope LLMCliInstaller {
        It 'maps google and gemini aliases to Antigravity only' {
            @(Resolve-ComponentSelection -Components @('google', 'gemini')) | Should -Be @('antigravity')
        }
        It 'maps all without Legacy Gemini' {
            $actual = @(Resolve-ComponentSelection -Components @('all'))
            $actual | Should -Be @('codex', 'claude', 'antigravity', 'grok')
            $actual | Should -Not -Contain 'legacy-gemini'
        }
        It 'T5-2: splits comma separated selections passed as one -File argument' {
            @(Resolve-ComponentSelection -Components @('google,codex')) | Should -Be @('antigravity', 'codex')
            { Resolve-ComponentSelection -Components @(' , ') } | Should -Throw '*E_INVALID_ARGUMENT*'
        }
        It 'requires the explicit Legacy Gemini guard' {
            { Resolve-ComponentSelection -Components @('legacy-gemini') } | Should -Throw '*E_INVALID_ARGUMENT*'
            @(Resolve-ComponentSelection -Components @('legacy-gemini') -AllowLegacyGemini) | Should -Be @('legacy-gemini')
        }
        It 'accepts one semantic version and rejects ambiguity' {
            (Get-StrictSemanticVersion -Text 'codex-cli 0.42.1').Normalized | Should -Be '0.42.1'
            Get-StrictSemanticVersion -Text 'first 1.2.3 second 4.5.6' | Should -BeNullOrEmpty
            Get-StrictSemanticVersion -Text 'no version' | Should -BeNullOrEmpty
        }
        It 'enforces the Node 22 baseline' {
            Test-MinimumSemanticVersion -Actual '22.0.0' -Minimum '22.0.0' | Should -BeTrue
            Test-MinimumSemanticVersion -Actual '20.19.0' -Minimum '22.0.0' | Should -BeFalse
        }
        It 'redacts sensitive values and user paths' {
            $marker = @('demo', 'secret', 'value') -join '-'
            $sampleText = "PASSWORD=$marker C:\Users\Alice\x"
            $safe = Protect-SensitiveText -Text $sampleText
            $safe | Should -Not -Match ([regex]::Escape($marker))
            $safe | Should -Not -Match 'Alice'
            $safe | Should -Match '\[REDACTED:'
        }
        It 'preserves the first primary component error' {
            $result = New-ComponentResult -Id 'git'
            Set-ComponentFailure -Result $result -Code 22 -Message 'source failed'
            Set-ComponentFailure -Result $result -Code 50 -Message 'verify failed'
            $result.PrimaryCode | Should -Be 22
        }
        It 'blocks illegal state transitions' {
            $run = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot $TestDrive
            { Move-RunState -Context $run -To 'Installing' } | Should -Throw '*E_INTERNAL_STATE*'
            $run.State | Should -Be 'Created'
        }
        It 'normalizes PATH while preserving first-seen order' {
            $separator = [IO.Path]::PathSeparator
            $actual = Merge-PathValues -Values @("A${separator}B", "b${separator}C", '')
            $actual.Split($separator) | Should -Be @('A', 'B', 'C')
        }
    }
}

Describe 'Redaction leak cases' -Tag Unit {
    BeforeAll {
        # Secret-shaped inputs are assembled from fragments at runtime so no such literal exists on disk.
        $hy = '-'; $us = '_'
        $leakM1 = 'QA' * 12
        $leakM2 = 'QB' * 8
        $kw = @('API', 'KEY') -join $us
        $header = @('Author', 'ization') -join ''
        $pwKey = @('pass', 'word') -join ''
        $pemBegin = '-----BEGIN ' + 'RSA ' + 'PRIVATE ' + 'KEY-----'
        $pemEnd = '-----END ' + 'RSA ' + 'PRIVATE ' + 'KEY-----'
        $scheme = @('Bea', 'rer') -join ''
        $jwtHead = @('ey', 'J', 'hbGci', 'OiJIUzI1NiJ9') -join ''
        $script:leakCases = @(
            @{ Name = 'vendor project key in env assignment'; Text = ('OPENAI' + $us + $kw + '=' + (@('sk', 'proj') -join $hy) + $hy + $leakM1); Marker = $leakM1 },
            @{ Name = 'vendor api03 key'; Text = ('key ' + (@('sk', 'ant', 'api03') -join $hy) + $hy + $leakM1); Marker = $leakM1 },
            @{ Name = 'xai hyphen key'; Text = ('xai' + $hy + $leakM1); Marker = $leakM1 },
            @{ Name = 'GitHub PAT'; Text = ('ghp' + $us + $leakM1); Marker = $leakM1 },
            @{ Name = 'GitHub OAuth token'; Text = ('gho' + $us + $leakM1); Marker = $leakM1 },
            @{ Name = 'underscore-prefixed env key name'; Text = ('ANTHROPIC' + $us + $kw + '=' + $leakM1); Marker = $leakM1 },
            @{ Name = 'auth header credential'; Text = ($header + ': ' + $scheme + ' ' + $leakM1); Marker = $leakM1 },
            @{ Name = 'JSON camelCase field'; Text = ('{"' + (@('api', 'Key') -join '') + '": "' + $leakM1 + '"}'); Marker = $leakM1 },
            @{ Name = 'JWT'; Text = ('token ' + $jwtHead + '.' + $leakM1 + '.sig'); Marker = $leakM1 },
            @{ Name = 'user path with space'; Text = 'C:\Users\John Smith\AppData\Roaming\npm'; Marker = 'Smith' },
            @{ Name = 'forward-slash user path'; Text = 'C:/Users/alice/AppData'; Marker = 'alice' },
            @{ Name = 'D-drive user path'; Text = 'D:\Users\alice\AppData'; Marker = 'alice' },
            @{ Name = 'JSON-escaped user path'; Text = '{"p":"C:\\Users\\alice\\AppData"}'; Marker = 'alice' },
            @{ Name = 'T3-1 single-quoted password value'; Text = ($pwKey + "='" + $leakM1 + "'"); Marker = $leakM1 },
            @{ Name = 'T3-2 PowerShell env assignment'; Text = ('$' + 'env:' + 'GEMINI' + $us + $kw + " = '" + $leakM1 + "'"); Marker = $leakM1 },
            @{ Name = 'T3-3 JSON value with spaces'; Text = ('{"' + $pwKey + '": "my ' + $leakM1 + ' pass"}'); Marker = $leakM1 },
            @{ Name = 'T3-4a complete PEM block'; Text = ($pemBegin + "`n" + $leakM1 + "`n" + $pemEnd); Marker = $leakM1 },
            @{ Name = 'T3-4b truncated PEM block'; Text = ($pemBegin + "`n" + $leakM1 + "`nmore"); Marker = $leakM1 },
            @{ Name = 'T3-5 npmrc auth key'; Text = (('_au' + 'th') + '=' + $leakM1); Marker = $leakM1 },
            @{ Name = 'T3-6a api-key flag with space'; Text = ('tool --api' + $hy + 'key ' + $leakM1); Marker = $leakM1 },
            @{ Name = 'T3-6b token flag with space'; Text = ('tool --tok' + 'en ' + $leakM1); Marker = $leakM1 },
            @{ Name = 'T3-7 Google API key shape'; Text = ('key ' + 'AI' + 'za' + ('Q' * 35)); Marker = ('Q' * 35) },
            @{ Name = 'T3-8 npm token shape'; Text = ('x ' + 'np' + 'm_' + ('R' * 36)); Marker = ('R' * 36) }
        )
        $script:leakStdErr = ('npm ERR! OPENAI' + $us + $kw + '=' + (@('sk', 'proj') -join $hy) + $hy + $leakM1 + ' and ' + $header + ': ' + $scheme + ' ' + $leakM2 + ' in C:\Users\fixture\.npmrc')
    }

    It 'Protect-SensitiveText masks every leak case' {
        InModuleScope LLMCliInstaller -Parameters @{ Cases = $script:leakCases } {
            param($Cases)
            foreach ($case in $Cases) {
                Protect-SensitiveText -Text $case.Text | Should -Not -Match ([regex]::Escape($case.Marker)) -Because $case.Name
            }
            # Package names that merely share a vendor prefix stay readable.
            Protect-SensitiveText -Text 'npm install -g @xai-official/grok@1.2.3' | Should -Be 'npm install -g @xai-official/grok@1.2.3'
        }
    }

    It 'T3-9: the current USERNAME is masked as a whole word' {
        InModuleScope LLMCliInstaller {
            $original = $env:USERNAME
            try {
                $env:USERNAME = 'fixtureuser'
                Protect-SensitiveText -Text 'owner fixtureuser done' | Should -Not -Match 'fixtureuser'
            } finally { $env:USERNAME = $original }
        }
    }

    It 'T3-10: ordinary text, registry flags and PATH lists are not over-masked' {
        InModuleScope LLMCliInstaller {
            Protect-SensitiveText -Text 'author: Jane' | Should -Be 'author: Jane'
            $registry = 'npm install --registry=https://registry.npmjs.org/ @xai-official/grok'
            Protect-SensitiveText -Text $registry | Should -Be $registry
            Protect-SensitiveText -Text 'C:\Users\bob;C:\Windows' | Should -Match ([regex]::Escape('C:\Windows'))
        }
    }

    It 'ConvertTo-SafeJson masks user paths nested in objects before JSON escaping' {
        InModuleScope LLMCliInstaller {
            $json = ConvertTo-SafeJson -Value @{ resolvedPath = 'C:\Users\alice\AppData\Roaming\npm\grok.cmd'; nested = @(@{ p = 'C:\Users\John Smith\x' }, [pscustomobject]@{ q = 'D:/Users/bob/y' }) }
            $json | Should -Not -Match 'alice|Smith|bob'
            ($json | ConvertFrom-Json).resolvedPath | Should -Be '%USERPROFILE%\AppData\Roaming\npm\grok.cmd'
        }
    }

    Context 'orchestrated runs' {
        BeforeEach {
            InModuleScope LLMCliInstaller {
                $script:leak = @{ GrokMissing = $false; StdErr = ''; ResolvedPath = 'tool' }
                Mock Get-PlatformDiagnostic { [pscustomobject]@{ IsWindows=$true; Architecture='AMD64'; IsSupported=$true; Build=26100; PowerShellVersion='5.1'; IsAdministrator=$false } }
                Mock Get-MigrationStateRoot { Join-Path $TestDrive 'state' }
                Mock Get-NpmEffectivePrefix { 'C:\Users\fixture\AppData\Roaming\npm' }
                Mock Get-PyManagerManagedRuntime { @() }
                Mock Get-ComponentStatus {
                    if ($Id -eq 'grok' -and $script:leak.GrokMissing) { return [pscustomobject]@{ State='Missing'; Verification=$null } }
                    [pscustomobject]@{ State='Satisfied'; Verification=[pscustomobject]@{ Version='1.0.0'; Process=[pscustomobject]@{ ResolvedPath=$script:leak.ResolvedPath } } }
                }
                Mock Get-ComponentInventory { Complete-ComponentInventory -ComponentId $Id -Candidates @() -Definition $Definition }
                Mock Install-Component { [pscustomobject]@{ Process=[pscustomobject]@{ ExitCode=1; StdErr=$script:leak.StdErr; StdOut=''; CommandSummary='npm install --prefix C:\Users\fixture\AppData\Roaming\npm' }; StableCode=40; RestartRequired=$false } }
                Mock Test-ComponentInstallation { [pscustomobject]@{ Success=$true; Version='2.0.0'; Process=[pscustomobject]@{ ResolvedPath=$script:leak.ResolvedPath; ExitCode=0 }; Status='Verified'; Code=0 } }
                Mock Update-ProcessPath { }
                Mock Enter-InstallerMutex { [pscustomobject]@{ Held = $true } }
                Mock Exit-InstallerMutex { }
            }
        }

        It 'E1: events.jsonl, summary.json and the support bundle carry no home directory name' {
            InModuleScope LLMCliInstaller {
                $script:leak.ResolvedPath = 'C:\Users\fixture\AppData\Roaming\npm\grok.cmd'
                $logs = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
                $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $logs
                $result.ExitCode | Should -Be 0
                (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'events.jsonl') -Raw) | Should -Not -Match 'fixture'
                $summary = Get-Content -LiteralPath (Join-Path $result.LogDirectory 'summary.json') -Raw
                $summary | Should -Not -Match 'fixture'
                $summary | Should -Match '%USERPROFILE%'
                $extract = Join-Path $TestDrive ('bundle-' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $result.SupportBundle -DestinationPath $extract
                @(Get-ChildItem -LiteralPath $extract -File | Select-String -Pattern 'fixture').Count | Should -Be 0
            }
        }

        It 'E2: installer stderr with vendor keys and an auth header never reaches the logs' {
            InModuleScope LLMCliInstaller -Parameters @{ StdErr = $script:leakStdErr; M1 = $leakM1; M2 = $leakM2 } {
                param($StdErr, $M1, $M2)
                $script:leak.GrokMissing = $true
                $script:leak.StdErr = $StdErr
                $logs = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
                $result = Invoke-LlmCliInstaller -Components grok -NonInteractive -LogRoot $logs -NoSupportBundle
                ($result.Components | Where-Object Id -eq 'grok').PrimaryCode | Should -Be 40
                $persisted = (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'events.jsonl') -Raw) + (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'run.log') -Raw) + (Get-Content -LiteralPath (Join-Path $result.LogDirectory 'summary.json') -Raw)
                $persisted | Should -Not -Match $M1
                $persisted | Should -Not -Match $M2
                $persisted | Should -Not -Match 'fixture'
            }
        }
    }
}

Describe 'Process pipe handling' -Tag Unit {
    It 'T4-1: a timed out child that leaves a grandchild holding the pipe returns within 9 seconds' -Skip:($env:OS -eq 'Windows_NT') {
        InModuleScope LLMCliInstaller {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-SafeProcess -FilePath sh -ArgumentList @('-c', 'sleep 12 & wait') -TimeoutSeconds 2 -CloseInput
            $watch.Stop()
            $result.TimedOut | Should -BeTrue
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 9
        }
    }
    It 'T4-2: a normally exiting child returns its output' -Skip:($env:OS -eq 'Windows_NT') {
        InModuleScope LLMCliInstaller {
            $result = Invoke-SafeProcess -FilePath sh -ArgumentList @('-c', 'echo ok') -TimeoutSeconds 10 -CloseInput
            $result.TimedOut | Should -BeFalse
            $result.StdOut | Should -BeLike 'ok*'
        }
    }
}
