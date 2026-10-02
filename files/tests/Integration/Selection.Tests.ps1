$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'Safe dry-run orchestration' -Tag Integration {
    It 'all never plans Legacy Gemini' {
        $result = Invoke-LlmCliInstaller -Components all -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.Components.Id) | Should -Contain 'antigravity'
        @($result.Components.Id) | Should -Not -Contain 'legacy-gemini'
    }
    It 'T9-1: the ordered list is only the selected CLI plus its DependsOn' {
        InModuleScope LLMCliInstaller {
            $catalog = Get-ComponentCatalog
            @(Get-OrderedComponentList -Selected @('codex') -Catalog $catalog) | Should -Be @('codex')
            @(Get-OrderedComponentList -Selected @('claude') -Catalog $catalog) | Should -Be @('git', 'claude')
            @(Get-OrderedComponentList -Selected @('grok') -Catalog $catalog) | Should -Be @('node', 'grok')
        }
    }
    It 'T9-2: a single CLI selection never plans powershell or python (<id>)' -ForEach @(@{ id = 'codex' }, @{ id = 'claude' }, @{ id = 'antigravity' }, @{ id = 'grok' }) {
        $result = Invoke-LlmCliInstaller -Components $id -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.Components.Id) | Should -Not -Contain 'powershell'
        @($result.Components.Id) | Should -Not -Contain 'python'
        @($result.Components.Id) | Should -Contain $id
    }
    It 'T9-3: the confirmation screen lists only dependencies of the selected CLIs' {
        InModuleScope LLMCliInstaller {
            Mock Read-Host { '2' } -ParameterFilter { $Prompt -like '*번호*' }
            Mock Read-Host { 'y' } -ParameterFilter { $Prompt -like '*진행*' }
            $out = (Read-InteractiveSelection 6>&1 | Out-String)
            $out | Should -Match ([regex]::Escape('Git for Windows(Claude Code에 필요)'))
            $out | Should -Not -Match 'Python|PowerShell 7'
            Mock Read-Host { '1' } -ParameterFilter { $Prompt -like '*번호*' }
            $out = (Read-InteractiveSelection 6>&1 | Out-String)
            $out | Should -Not -Match ([regex]::Escape('함께 설치될 수 있는 항목'))
            Mock Read-Host { '2,4' } -ParameterFilter { $Prompt -like '*번호*' }
            $out = (Read-InteractiveSelection 6>&1 | Out-String)
            $out | Should -Match ([regex]::Escape('Node.js LTS(Grok CLI에 필요)'))
        }
    }
    It 'google alias plans Antigravity without Node' {
        $result = Invoke-LlmCliInstaller -Components google -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.SelectedComponents) | Should -Be @('antigravity')
        @($result.Components | Where-Object Id -eq 'node').Count | Should -Be 0
    }
}

Describe 'Release packaging and bootstrap integrity' -Tag Integration {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # Package root: installer-win.bat and git dot files at the top, everything else under files/.
        $script:realApp = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).ProviderPath
        $script:pwshPath = (Get-Process -Id $PID).Path

        function Copy-AppFixture {
            param([string]$Path)
            $filesPath = Join-Path $Path 'files'
            [IO.Directory]::CreateDirectory($filesPath) | Out-Null
            foreach ($directory in @('src', 'docs', 'tests', 'tools', 'macos')) { Copy-Item -LiteralPath (Join-Path $script:realApp ('files/' + $directory)) -Destination $filesPath -Recurse }
            foreach ($file in @('install.ps1', 'README.md', 'SECURITY.md', 'PSScriptAnalyzerSettings.psd1')) { Copy-Item -LiteralPath (Join-Path $script:realApp ('files/' + $file)) -Destination $filesPath }
            foreach ($file in @('installer-win.bat', 'installer-mac.command', 'README.md', '.gitattributes', '.gitignore')) { Copy-Item -LiteralPath (Join-Path $script:realApp $file) -Destination $Path }
        }
        function Invoke-Child {
            param([string]$Script, [string[]]$Arguments)
            $lines = @(& $script:pwshPath -NoProfile -File $Script @Arguments 2>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($lines -join ' ') -replace '\x1b\[[0-9;]*m', '' -replace '[\r\n|]+', ' ' -replace '\s+', ' '); Lines = $lines }
        }
        function New-GitAppFixture {
            param([string]$Path)
            $hooksOption = 'core.hooksPath=' + (Join-Path $TestDrive 'nohooks')
            Copy-AppFixture -Path $Path
            $update = Invoke-Child -Script (Join-Path $Path 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $Path)
            if ($update.ExitCode -ne 0) { throw ('fixture manifest failed: ' + $update.Text) }
            & git -C $Path init --quiet
            & git -C $Path add -A
            & git -C $Path -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c $hooksOption commit --quiet -m fixture
        }
        function Get-ZipEntryName {
            param([string]$Path)
            $zip = [IO.Compression.ZipFile]::OpenRead($Path)
            try { return @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $zip.Dispose() }
        }

        $script:appCopy = Join-Path $TestDrive 'appcopy'
        Copy-AppFixture -Path $script:appCopy
        [IO.Directory]::CreateDirectory((Join-Path $script:appCopy '.omc/state')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:appCopy '.omc/state/x.json'), '{}')
        [IO.Directory]::CreateDirectory((Join-Path $script:appCopy 'TestResults')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:appCopy 'TestResults/r.xml'), '<r/>')
        [IO.File]::WriteAllText((Join-Path $script:appCopy 'old.zip'), 'old')
        $script:manifestTool = Join-Path $script:appCopy 'files/tools/Update-Manifest.ps1'
        $script:packageTool = Join-Path $script:appCopy 'files/tools/New-ReleasePackage.ps1'
        $script:installScript = Join-Path $script:appCopy 'files/install.ps1'
        (Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy)).ExitCode | Should -Be 0
    }

    It 'T8-1: the allowlist listing leaves out local state, results, ZIPs and git dot files and keeps only installer-win.bat at the top' {
        $listing = Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy, '-ListOnly')
        $listing.ExitCode | Should -Be 0
        $listing.Lines | Should -Not -Contain '.omc/state/x.json'
        $listing.Lines | Should -Not -Contain 'TestResults/r.xml'
        $listing.Lines | Should -Not -Contain 'old.zip'
        foreach ($expected in @('installer-win.bat', 'files/SECURITY.md', 'files/install.ps1')) { $listing.Lines | Should -Contain $expected }
        foreach ($gitOnly in @('.gitignore', '.gitattributes')) { $listing.Lines | Should -Not -Contain $gitOnly }
        @($listing.Lines | Where-Object { $_ -notlike 'files/*' }) | Should -Be @('README.md', 'installer-win.bat')
    }

    It 'R2-01a: packaging without a git work tree fails closed and creates no ZIP' {
        $zipPath = Join-Path $TestDrive 'out/nogit.zip'
        $run = Invoke-Child -Script $script:packageTool -Arguments @('-AppRoot', $script:appCopy, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Not -Be 0
        $run.Text | Should -Match 'requires the app root to be a git work tree'
        Test-Path -LiteralPath $zipPath | Should -BeFalse
    }

    It 'R2-01b: a clean git fixture packages exactly the allowlist plus manifest.sha256 with a detached digest' -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue)) -or $IsWindows) {
        $appGit = Join-Path $TestDrive 'appgit'
        New-GitAppFixture -Path $appGit
        $zipPath = Join-Path $TestDrive 'out/pkg.zip'
        $run = Invoke-Child -Script (Join-Path $appGit 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appGit, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Be 0 -Because $run.Text
        $listing = (Invoke-Child -Script (Join-Path $appGit 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appGit, '-ListOnly')).Lines
        $macManifestLines = @([IO.File]::ReadAllLines((Join-Path $appGit 'files/macos/manifest.sha256')) | ForEach-Object { $_.Substring(66) })
        $expected = @($listing + 'files/manifest.sha256' + $macManifestLines + 'files/macos/manifest.sha256') | Sort-Object
        Get-ZipEntryName -Path $zipPath | Should -Be $expected
        # Extracted, the user sees the two launchers, README.md and the files folder.
        (@(Get-ZipEntryName -Path $zipPath | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique) -join ',') | Should -Be ((@('README.md', 'files', 'installer-mac.command', 'installer-win.bat') | Sort-Object) -join ',')
        @(Get-ZipEntryName -Path $zipPath | Where-Object { $_ -like '.omc*' }).Count | Should -Be 0
        $digestLine = ([IO.File]::ReadAllText($zipPath + '.sha256')).Trim()
        $digestLine | Should -Be ('{0}  {1}' -f (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(), 'pkg.zip')
    }

    It 'R2-01e: the ZIP keeps the macOS launcher executable and README.md plain' -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue)) -or $IsWindows) {
        $appGit = Join-Path $TestDrive 'appmode'
        New-GitAppFixture -Path $appGit
        $zipPath = Join-Path $TestDrive 'out/mode.zip'
        $run = Invoke-Child -Script (Join-Path $appGit 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appGit, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Be 0 -Because $run.Text
        $reader = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            (($reader.GetEntry('installer-mac.command').ExternalAttributes -shr 16) -band 0x1FF) | Should -Be 0x1ED
            (($reader.GetEntry('README.md').ExternalAttributes -shr 16) -band 0x1FF) | Should -Be 0x1A4
        } finally { $reader.Dispose() }
    }

    It 'R2-01f: a macOS file changed without refreshing its manifest stops packaging' -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue)) -or $IsWindows) {
        $appGit = Join-Path $TestDrive 'appmacstale'
        New-GitAppFixture -Path $appGit
        $hooksOption = 'core.hooksPath=' + (Join-Path $TestDrive 'nohooks')
        [IO.File]::WriteAllText((Join-Path $appGit 'files/macos/VERSION'), "9.9.9`n")
        & git -C $appGit add -A
        & git -C $appGit -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c $hooksOption commit --quiet -m stale
        $zipPath = Join-Path $TestDrive 'out/stale.zip'
        $run = Invoke-Child -Script (Join-Path $appGit 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appGit, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Not -Be 0
        $run.Text | Should -Match 'macOS manifest is stale'
        Test-Path -LiteralPath $zipPath | Should -BeFalse
    }

    It 'R2-01c: ignored local files that the allowlist scan picks up stop packaging' -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue)) -or $IsWindows) {
        $appLeak = Join-Path $TestDrive 'appleak'
        New-GitAppFixture -Path $appLeak
        $exclude = Join-Path $appLeak '.git/info/exclude'
        $excludeOriginal = [IO.File]::ReadAllBytes($exclude)
        [IO.File]::WriteAllText((Join-Path $appLeak 'files/src/.env'), 'x')
        [IO.File]::WriteAllText((Join-Path $appLeak 'files/docs/private.txt'), 'x')
        [IO.File]::AppendAllText($exclude, "`nfiles/src/.env`nfiles/docs/private.txt`n")
        (Invoke-Child -Script (Join-Path $appLeak 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appLeak)).ExitCode | Should -Be 0
        $listing = (Invoke-Child -Script (Join-Path $appLeak 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appLeak, '-ListOnly')).Lines
        $listing | Should -Contain 'files/src/.env'
        $listing | Should -Contain 'files/docs/private.txt'
        $hooksOption = 'core.hooksPath=' + (Join-Path $TestDrive 'nohooks')
        # Commit the regenerated manifest so the work tree is clean and only the tracked-set comparison can stop the run.
        & git -C $appLeak add files/manifest.sha256
        & git -C $appLeak -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c $hooksOption commit --quiet -m manifest
        $leakZip = Join-Path $TestDrive 'out/leak.zip'
        $ignored = Invoke-Child -Script (Join-Path $appLeak 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appLeak, '-OutputPath', $leakZip)
        $ignored.ExitCode | Should -Not -Be 0
        $ignored.Text | Should -Match 'allowlist differs from tracked files'
        Test-Path -LiteralPath $leakZip | Should -BeFalse
        [IO.File]::WriteAllBytes($exclude, $excludeOriginal)
        $untracked = Invoke-Child -Script (Join-Path $appLeak 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appLeak, '-OutputPath', $leakZip)
        $untracked.ExitCode | Should -Not -Be 0
        $untracked.Text | Should -Match 'dirty|untracked'
    }

    It 'T8-3: an output path inside the app root is refused' {
        $run = Invoke-Child -Script $script:packageTool -Arguments @('-AppRoot', $script:appCopy, '-OutputPath', (Join-Path $script:appCopy 'in.zip'))
        $run.ExitCode | Should -Not -Be 0
        $run.Text | Should -Match 'E_PACKAGE_LAYOUT'
    }

    It 'T8-4: a stale manifest stops packaging' {
        $readme = Join-Path $script:appCopy 'files/README.md'
        $original = [IO.File]::ReadAllBytes($readme)
        try {
            [IO.File]::AppendAllText($readme, "`nextra line`n")
            $run = Invoke-Child -Script $script:packageTool -Arguments @('-AppRoot', $script:appCopy, '-OutputPath', (Join-Path $TestDrive 'out/stale.zip'))
            $run.ExitCode | Should -Not -Be 0
            $run.Text | Should -Match 'manifest is stale'
        } finally {
            [IO.File]::WriteAllBytes($readme, $original)
            Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy) | Out-Null
        }
    }

    It 'T8-5: a git work tree with an untracked file stops packaging' -Skip:((-not (Get-Command git -ErrorAction SilentlyContinue)) -or $IsWindows) {
        $copy2 = Join-Path $TestDrive 'appcopy2'
        Copy-AppFixture -Path $copy2
        (Invoke-Child -Script (Join-Path $copy2 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $copy2)).ExitCode | Should -Be 0
        $noHooks = Join-Path $TestDrive 'nohooks'
        & git -C $copy2 init --quiet
        & git -C $copy2 add -A
        & git -C $copy2 -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=$noHooks commit --quiet -m fixture
        $clean = Invoke-Child -Script (Join-Path $copy2 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $copy2, '-OutputPath', (Join-Path $TestDrive 'out/git-clean.zip'))
        $clean.ExitCode | Should -Be 0 -Because $clean.Text
        [IO.File]::WriteAllText((Join-Path $copy2 'files/tests/extra.txt'), 'x')
        # Refresh the manifest so the manifest check passes and only the git work tree check can stop the run.
        (Invoke-Child -Script (Join-Path $copy2 'files/tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $copy2)).ExitCode | Should -Be 0
        $dirty = Invoke-Child -Script (Join-Path $copy2 'files/tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $copy2, '-OutputPath', (Join-Path $TestDrive 'out/git-dirty.zip'))
        $dirty.ExitCode | Should -Not -Be 0
        $dirty.Text | Should -Match 'dirty|untracked'
    }

    It 'T8-6: install.ps1 passes its integrity check and runs a WhatIf plan' {
        $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l1'))
        $run.ExitCode | Should -Be 0 -Because $run.Text
    }

    It 'T8-7: a modified code file stops install.ps1 with exit 23' {
        $target = Join-Path $script:appCopy 'files/src/LLMCliInstaller/Private/Platform.ps1'
        $original = [IO.File]::ReadAllBytes($target)
        try {
            [IO.File]::AppendAllText($target, "`n# x`n")
            $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l2'))
            $run.ExitCode | Should -Be 23
            $run.Text | Should -Match '무결성'
        } finally { [IO.File]::WriteAllBytes($target, $original) }
    }

    It 'T8-8: an unlisted extra script file stops install.ps1 with exit 23' {
        $extra = Join-Path $script:appCopy 'files/src/LLMCliInstaller/Private/Extra.ps1'
        [IO.File]::WriteAllText($extra, '# extra')
        try {
            $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l3'))
            $run.ExitCode | Should -Be 23
        } finally {
            $parking = Join-Path $TestDrive 'parking'
            [IO.Directory]::CreateDirectory($parking) | Out-Null
            Move-Item -LiteralPath $extra -Destination (Join-Path $parking 'Extra.ps1')
        }
    }

    It 'T8-8b: an unlisted executable or batch file (e.g. a planted powershell.exe) stops install.ps1 with exit 23' {
        foreach ($name in @('powershell.exe', 'evil.cmd', 'evil.bat', 'files/powershell.exe')) {
            $extra = Join-Path $script:appCopy $name
            [IO.File]::WriteAllText($extra, 'x')
            try {
                $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l3b'))
                $run.ExitCode | Should -Be 23 -Because $name
            } finally {
                $parking = Join-Path $TestDrive 'parking-exe'
                [IO.Directory]::CreateDirectory($parking) | Out-Null
                Move-Item -LiteralPath $extra -Destination (Join-Path $parking (Split-Path $name -Leaf)) -Force
            }
        }
    }

    It 'T8-8c: installer-win.bat starts Windows PowerShell by absolute System32 path, never a bare powershell.exe' {
        $bat = [IO.File]::ReadAllText((Join-Path $script:realApp 'installer-win.bat'))
        $bat | Should -Match ([regex]::Escape('set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"'))
        ($bat -split "`r?`n" | Where-Object { $_ -match '(?i)(^|[\s(])powershell(\.exe)?\s+-' }).Count | Should -Be 0
    }

    It 'T8-8e: installer-win.bat uses no parenthesized blocks (a ")" in a message or path would end the block early)' {
        $lines = @([IO.File]::ReadAllText((Join-Path $script:realApp 'installer-win.bat')) -split "`r?`n")
        @($lines | Where-Object { $_ -match '\($' }).Count | Should -Be 0
        @($lines | Where-Object { $_ -match '^\s*\)' }).Count | Should -Be 0
        @($lines | Where-Object { $_ -match '(?i)^\s*if\b.*\(\s*$' }).Count | Should -Be 0
    }

    It 'T8-8d: installer-win.bat runs files\install.ps1 and, without arguments, leaves the component choice to the menu' {
        $bat = [IO.File]::ReadAllText((Join-Path $script:realApp 'installer-win.bat'))
        $bat | Should -Match ([regex]::Escape('set "INSTALL_PS1=%~dp0files\install.ps1"'))
        $bat | Should -Not -Match '(?i)-Components'
    }

    It 'T8-9: a code file missing from the manifest stops install.ps1 with exit 23' {
        $manifest = Join-Path $script:appCopy 'files/manifest.sha256'
        $original = [IO.File]::ReadAllBytes($manifest)
        try {
            $kept = @([IO.File]::ReadAllLines($manifest) | Where-Object { $_ -notlike '*  files/src/LLMCliInstaller/Private/Platform.ps1' })
            $kept.Count | Should -BeLessThan ([IO.File]::ReadAllLines($manifest)).Count
            [IO.File]::WriteAllLines($manifest, $kept, (New-Object Text.UTF8Encoding($false)))
            $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l4'))
            $run.ExitCode | Should -Be 23
        } finally {
            [IO.File]::WriteAllBytes($manifest, $original)
            Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy) | Out-Null
        }
    }
}
