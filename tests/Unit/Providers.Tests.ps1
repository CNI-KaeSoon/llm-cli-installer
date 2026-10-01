$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'Provider contracts' -Tag Unit {
    InModuleScope LLMCliInstaller {
        BeforeAll {
            function Get-TextSha256 {
                param([string]$Text)
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { return ([BitConverter]::ToString($hasher.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
            }
        }
        It 'catalog contains only HTTPS official sources' {
            foreach ($item in (Get-ComponentCatalog).Values) {
                foreach ($uri in @($item.OfficialUris)) { ([uri]$uri).Scheme | Should -Be 'https' }
            }
        }
        It 'Python Install Manager is installed from the msstore source with UTF-8 output; other winget packages keep the winget source' {
            Mock Invoke-SafeProcess { [pscustomobject]@{ ExitCode=0; TimedOut=$false; StdOut=''; StdErr=''; ResolvedPath='winget.exe'; CommandSummary='winget' } } -ParameterFilter { $FilePath -eq 'winget' }
            Invoke-WinGetInstall -PackageId '9NQ7512CXL7T' -Source 'msstore' | Out-Null
            Should -Invoke Invoke-SafeProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'winget' -and $Utf8Output -and ($ArgumentList -join ' ') -match '--source msstore' }
            Invoke-WinGetInstall -PackageId 'Git.Git' | Out-Null
            Should -Invoke Invoke-SafeProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'winget' -and ($ArgumentList -join ' ') -match '--source winget' }
            (Get-Content -Raw (Join-Path $script:ModuleRoot 'Private/Providers/Providers.ps1')) | Should -Match ([regex]::Escape('-VendorLog $vendorLog -Source ''msstore'''))
        }
        It 'Antigravity has no Node dependency' {
            @((Get-ComponentCatalog).antigravity.DependsOn).Count | Should -Be 0
        }
        It 'Grok and Legacy Gemini depend on Node' {
            (Get-ComponentCatalog).grok.DependsOn | Should -Contain 'node'
            (Get-ComponentCatalog).'legacy-gemini'.DependsOn | Should -Contain 'node'
        }
        It 'Python manager list must contain one 3.14 runtime' {
            Test-PythonManagerList -Text '* 3.14.2' | Should -BeTrue
            Test-PythonManagerList -Text '3.13.9' | Should -BeFalse
            Test-PythonManagerList -Text "3.14.1`n3.14.2" | Should -BeFalse
        }
        It 'known Claude doctor guidance is warning only on exit zero' {
            (Get-ClaudeDoctorClassification -ExitCode 0 -Output 'Authentication required').Status | Should -Be 'VerifiedWithWarning'
            (Get-ClaudeDoctorClassification -ExitCode 1 -Output 'Authentication required').Code | Should -Be 50
            (Get-ClaudeDoctorClassification -ExitCode 0 -Output 'Git Bash missing').Code | Should -Be 50
        }

        It 'T2-5: npm install arguments force the official registry for the global and scoped configuration' {
            (Get-NpmInstallArgumentList -Package '@xai-official/grok' -Prefix 'C:\npm') -join ' ' | Should -Be 'install --global --registry=https://registry.npmjs.org/ --@xai-official:registry=https://registry.npmjs.org/ --prefix C:\npm @xai-official/grok'
            { Get-NpmInstallArgumentList -Package 'a b' -Prefix $null } | Should -Throw '*E_INTERNAL_STATE*'
        }
        It 'T2-6: npm channel stable codes follow the exit reason' -ForEach @(
            @{ Exit = 127; Timed = $false; Expected = 22 }
            @{ Exit = 124; Timed = $true; Expected = 20 }
            @{ Exit = 126; Timed = $false; Expected = 21 }
            @{ Exit = 1; Timed = $false; Expected = 40 }
        ) {
            Mock Get-NpmEffectivePrefix { $null }
            Mock Invoke-SafeProcess { [pscustomobject]@{ ExitCode=$Exit; TimedOut=$Timed; StdOut=''; StdErr=''; ResolvedPath='npm'; CommandSummary='npm' } }
            $context = [pscustomobject]@{ RunDirectory = $TestDrive }
            (Install-Component -Id grok -Definition (Get-ComponentCatalog).grok -Context $context).StableCode | Should -Be $Expected
        }
        It 'T2-7: an npm prefix with cmd metacharacters or a relative path is rejected' {
            $hostile = 'C:\x' + '&' + 'calc'
            Mock Invoke-SafeProcess { [pscustomobject]@{ ExitCode=0; TimedOut=$false; StdOut=$script:npmPrefixOut; StdErr=''; ResolvedPath='npm'; CommandSummary='npm' } }
            $script:npmPrefixOut = $hostile
            Get-NpmEffectivePrefix | Should -BeNullOrEmpty
            $script:npmPrefixOut = 'npm'
            Get-NpmEffectivePrefix | Should -BeNullOrEmpty
        }
        It 'T2-8: npm uninstall arguments reject a prefix with cmd metacharacters' {
            { Get-NpmUninstallArgumentList -Prefix ('C:\x' + '|' + 'y') -Package '@xai-official/grok' } | Should -Throw '*unsafe*'
        }
        It 'T2-9: a cmd shim target with a metacharacter argument is never started' {
            Mock Resolve-ApplicationCommand { [pscustomobject]@{ Source = 'C:\nope\npm.cmd' } }
            $result = Invoke-SafeProcess -FilePath npm -ArgumentList @('install', ('a' + '&' + 'b'))
            $result.ExitCode | Should -Be 126
            $result.StdErr | Should -BeLike 'E_UNSAFE_ARGUMENT*'
        }
        It 'T2-10: the trusted Windows PowerShell path is an absolute file under SystemRoot' {
            $original = $env:SystemRoot
            try {
                $env:SystemRoot = Join-Path $TestDrive 'winroot'
                [IO.Directory]::CreateDirectory($env:SystemRoot) | Out-Null
                { Get-TrustedWindowsPowerShellPath } | Should -Throw '*E_NO_TRUSTED*'
                $expected = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                [IO.Directory]::CreateDirectory((Split-Path $expected -Parent)) | Out-Null
                [IO.File]::WriteAllText($expected, '')
                Get-TrustedWindowsPowerShellPath | Should -Be $expected
            } finally { $env:SystemRoot = $original }
        }

        It 'T1-1: a redirect from the entry host to the vendor download host is followed and hashed' {
            $script:fetchCalls = 0
            $fetch = {
                $script:fetchCalls++
                if ($script:fetchCalls -eq 1) { return [pscustomobject]@{ StatusCode = 302; Location = 'https://releases.openai.com/codex/install.ps1'; Body = [byte[]]@() } }
                [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [Text.Encoding]::UTF8.GetBytes('Write-Output 1') }
            }
            $content = Get-InstallerScriptContent -Uri 'https://chatgpt.com/codex/install.ps1' -AllowedHosts @('chatgpt.com', 'releases.openai.com') -Fetch $fetch
            $content.Text | Should -Be 'Write-Output 1'
            $content.FinalHost | Should -Be 'releases.openai.com'
            $content.Hops | Should -Be 1
            $content.DownloadSha256 | Should -Be (Get-TextSha256 -Text 'Write-Output 1')
        }
        It 'T1-2: a redirect to a host outside the allowlist is rejected before it is requested' {
            $script:fetchCalls = 0
            $fetch = { $script:fetchCalls++; [pscustomobject]@{ StatusCode = 302; Location = 'https://evil.example/x.ps1'; Body = [byte[]]@() } }
            { Get-InstallerScriptContent -Uri 'https://chatgpt.com/codex/install.ps1' -AllowedHosts @('chatgpt.com', 'releases.openai.com') -Fetch $fetch } | Should -Throw 'E_INTEGRITY*'
            $script:fetchCalls | Should -Be 1
        }
        It 'T1-3: a redirect to plain HTTP is rejected' {
            $fetch = { [pscustomobject]@{ StatusCode = 302; Location = 'http://releases.openai.com/codex/install.ps1'; Body = [byte[]]@() } }
            { Get-InstallerScriptContent -Uri 'https://chatgpt.com/codex/install.ps1' -AllowedHosts @('chatgpt.com', 'releases.openai.com') -Fetch $fetch } | Should -Throw 'E_INTEGRITY*'
        }
        It 'T1-4: more than three redirects are rejected' {
            $fetch = { [pscustomobject]@{ StatusCode = 302; Location = 'https://chatgpt.com/codex/again.ps1'; Body = [byte[]]@() } }
            { Get-InstallerScriptContent -Uri 'https://chatgpt.com/codex/install.ps1' -AllowedHosts @('chatgpt.com') -Fetch $fetch } | Should -Throw 'E_NETWORK*too many*'
        }
        It 'T1-5: HTML, empty and oversized bodies are rejected' {
            $html = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [Text.Encoding]::UTF8.GetBytes('  <html><body>blocked</body></html>') } }
            $empty = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [byte[]]@() } }
            $large = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = (New-Object byte[] 1048577) } }
            foreach ($fetch in @($html, $empty, $large)) {
                { Get-InstallerScriptContent -Uri 'https://claude.ai/install.ps1' -AllowedHosts @('claude.ai') -Fetch $fetch } | Should -Throw 'E_INTEGRITY*'
            }
        }
        It 'T1-6: a relative Location resolves against the current host' {
            $script:fetchCalls = 0
            $fetch = {
                $script:fetchCalls++
                if ($script:fetchCalls -eq 1) { return [pscustomobject]@{ StatusCode = 302; Location = '/codex/install.ps1'; Body = [byte[]]@() } }
                [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [Text.Encoding]::UTF8.GetBytes('Write-Output 1') }
            }
            $content = Get-InstallerScriptContent -Uri 'https://chatgpt.com/start' -AllowedHosts @('chatgpt.com') -Fetch $fetch
            $content.FinalHost | Should -Be 'chatgpt.com'
            $content.Hops | Should -Be 1
        }
        It 'T1-7: Install-Component runs the fetched script through the trusted PowerShell path and records its hash' {
            $script:t17Calls = 0
            Mock Invoke-InstallerHttpRequest {
                $script:t17Calls++
                if ($script:t17Calls -eq 1) { return [pscustomobject]@{ StatusCode = 302; Location = 'https://downloads.claude.ai/install.ps1'; Body = [byte[]]@() } }
                [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [Text.Encoding]::UTF8.GetBytes('Write-Output 1') }
            }
            Mock Get-TrustedWindowsPowerShellPath { 'C:\fake\powershell.exe' }
            Mock Invoke-SafeProcess { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = ''; StdErr = ''; ResolvedPath = $FilePath; CommandSummary = 'ps' } }
            $context = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot (Join-Path $TestDrive 't17logs')
            Initialize-RunLogging -Context $context -RequestedRoot (Join-Path $TestDrive 't17logs') | Out-Null
            $install = Install-Component -Id claude -Definition (Get-ComponentCatalog).claude -Context $context
            $install.StableCode | Should -Be 0
            @($install.Process.PSObject.Properties.Name) | Should -Contain 'InstallerExecutedSha256'
            $install.Process.InstallerFinalHost | Should -Be 'downloads.claude.ai'
            Should -Invoke Invoke-SafeProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\fake\powershell.exe' }
        }
        It 'R2-02a: a body that is not valid UTF-8 or contains NUL is rejected' {
            $badUtf8 = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [byte[]](0x57, 0xC3, 0x28) } }
            $withNul = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [byte[]]([Text.Encoding]::UTF8.GetBytes('Write-Output 1') + [byte[]](0x00)) } }
            { Get-InstallerScriptContent -Uri 'https://claude.ai/install.ps1' -AllowedHosts @('claude.ai') -Fetch $badUtf8 } | Should -Throw 'E_INTEGRITY*UTF-8*'
            { Get-InstallerScriptContent -Uri 'https://claude.ai/install.ps1' -AllowedHosts @('claude.ai') -Fetch $withNul } | Should -Throw 'E_INTEGRITY*NUL*'
        }
        It 'R2-02b: the evidence event with both hashes is persisted before the child process starts' {
            $context = New-RunContext -RunId ([guid]::NewGuid()) -LogRoot (Join-Path $TestDrive 'r2logs')
            Initialize-RunLogging -Context $context -RequestedRoot (Join-Path $TestDrive 'r2logs') | Out-Null
            $script:r2Context = $context
            Mock Get-TrustedWindowsPowerShellPath { 'C:\fake\powershell.exe' }
            Mock Invoke-SafeProcess {
                $script:r2FileHash = (Get-FileHash -LiteralPath $ArgumentList[-1] -Algorithm SHA256).Hash.ToLowerInvariant()
                $script:r2EventsAtStart = [IO.File]::ReadAllText($script:r2Context.JsonLog)
                [pscustomobject]@{ ExitCode = 0; TimedOut = $false; StdOut = ''; StdErr = ''; ResolvedPath = $FilePath; CommandSummary = 'ps' }
            }
            $fetch = { [pscustomobject]@{ StatusCode = 200; Location = $null; Body = [Text.Encoding]::UTF8.GetBytes('Write-Output 1') } }
            $process = Install-OfficialPowerShellScript -Uri 'https://claude.ai/install.ps1' -AllowedHosts @('claude.ai') -Context $context -ComponentId 'claude' -Fetch $fetch
            $process.InstallerExecutedSha256 | Should -Be $script:r2FileHash
            $process.InstallerDownloadSha256 | Should -Be (Get-TextSha256 -Text 'Write-Output 1')
            $process.InstallerExecutedSha256 | Should -Not -Be $process.InstallerDownloadSha256
            $process.InstallerExecutedBytes | Should -Be ($process.InstallerDownloadBytes + 3)
            $script:r2EventsAtStart | Should -Match 'script-fetched'
            $script:r2EventsAtStart | Should -Match $script:r2FileHash
            $script:r2EventsAtStart | Should -Match 'downloadSha256'
        }
        It 'N1: no catalog VerifyCommands argument trips the cmd shim metacharacter guard' {
            foreach ($item in (Get-ComponentCatalog).Values) {
                foreach ($command in @($item.VerifyCommands)) {
                    foreach ($argument in @($command.Arguments)) {
                        [string]$argument | Should -Not -Match $script:CmdUnsafePattern -Because ('{0} {1}' -f $command.File, $argument)
                    }
                }
            }
        }
        It 'T1-8: every official-script catalog entry declares installer hosts that contain its installer host' {
            foreach ($item in (Get-ComponentCatalog).Values) {
                if ($item.Install -ne 'official-script') { continue }
                @($item.InstallerHosts).Count | Should -BeGreaterThan 0
                @($item.InstallerHosts) | Should -Contain ([uri]$item.InstallerUri).Host
            }
        }
    }
}
