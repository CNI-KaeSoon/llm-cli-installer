$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'Safe dry-run orchestration' -Tag Integration {
    It 'all never plans Legacy Gemini' {
        $result = Invoke-LlmCliInstaller -Components all -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.Components.Id) | Should -Contain 'antigravity'
        @($result.Components.Id) | Should -Not -Contain 'legacy-gemini'
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
        $script:realApp = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
        $script:pwshPath = (Get-Process -Id $PID).Path

        function Copy-AppFixture {
            param([string]$Path)
            [IO.Directory]::CreateDirectory($Path) | Out-Null
            foreach ($directory in @('src', 'docs', 'tests', 'tools')) { Copy-Item -LiteralPath (Join-Path $script:realApp $directory) -Destination $Path -Recurse }
            foreach ($file in @('install.ps1', 'README.md', 'SECURITY.md', 'PSScriptAnalyzerSettings.psd1', '.gitattributes', '.gitignore')) { Copy-Item -LiteralPath (Join-Path $script:realApp $file) -Destination $Path }
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
            $update = Invoke-Child -Script (Join-Path $Path 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $Path)
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
        $script:manifestTool = Join-Path $script:appCopy 'tools/Update-Manifest.ps1'
        $script:packageTool = Join-Path $script:appCopy 'tools/New-ReleasePackage.ps1'
        $script:installScript = Join-Path $script:appCopy 'install.ps1'
        (Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy)).ExitCode | Should -Be 0
    }

    It 'T8-1: the allowlist listing leaves out local state, results and ZIPs and includes dot files and SECURITY.md' {
        $listing = Invoke-Child -Script $script:manifestTool -Arguments @('-AppRoot', $script:appCopy, '-ListOnly')
        $listing.ExitCode | Should -Be 0
        $listing.Lines | Should -Not -Contain '.omc/state/x.json'
        $listing.Lines | Should -Not -Contain 'TestResults/r.xml'
        $listing.Lines | Should -Not -Contain 'old.zip'
        foreach ($expected in @('.gitignore', 'SECURITY.md', 'install.ps1')) { $listing.Lines | Should -Contain $expected }
    }

    It 'R2-01a: packaging without a git work tree fails closed and creates no ZIP' {
        $zipPath = Join-Path $TestDrive 'out/nogit.zip'
        $run = Invoke-Child -Script $script:packageTool -Arguments @('-AppRoot', $script:appCopy, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Not -Be 0
        $run.Text | Should -Match 'requires the app root to be a git work tree'
        Test-Path -LiteralPath $zipPath | Should -BeFalse
    }

    It 'R2-01b: a clean git fixture packages exactly the allowlist plus manifest.sha256 with a detached digest' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $appGit = Join-Path $TestDrive 'appgit'
        New-GitAppFixture -Path $appGit
        $zipPath = Join-Path $TestDrive 'out/pkg.zip'
        $run = Invoke-Child -Script (Join-Path $appGit 'tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appGit, '-OutputPath', $zipPath)
        $run.ExitCode | Should -Be 0 -Because $run.Text
        $listing = (Invoke-Child -Script (Join-Path $appGit 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appGit, '-ListOnly')).Lines
        $expected = @($listing + 'manifest.sha256') | Sort-Object
        Get-ZipEntryName -Path $zipPath | Should -Be $expected
        @(Get-ZipEntryName -Path $zipPath | Where-Object { $_ -like '.omc*' }).Count | Should -Be 0
        $digestLine = ([IO.File]::ReadAllText($zipPath + '.sha256')).Trim()
        $digestLine | Should -Be ('{0}  {1}' -f (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant(), 'pkg.zip')
    }

    It 'R2-01c: ignored local files that the allowlist scan picks up stop packaging' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $appLeak = Join-Path $TestDrive 'appleak'
        New-GitAppFixture -Path $appLeak
        $exclude = Join-Path $appLeak '.git/info/exclude'
        $excludeOriginal = [IO.File]::ReadAllBytes($exclude)
        [IO.File]::WriteAllText((Join-Path $appLeak 'src/.env'), 'x')
        [IO.File]::WriteAllText((Join-Path $appLeak 'docs/private.txt'), 'x')
        [IO.File]::AppendAllText($exclude, "`nsrc/.env`ndocs/private.txt`n")
        (Invoke-Child -Script (Join-Path $appLeak 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appLeak)).ExitCode | Should -Be 0
        $listing = (Invoke-Child -Script (Join-Path $appLeak 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $appLeak, '-ListOnly')).Lines
        $listing | Should -Contain 'src/.env'
        $listing | Should -Contain 'docs/private.txt'
        $hooksOption = 'core.hooksPath=' + (Join-Path $TestDrive 'nohooks')
        # Commit the regenerated manifest so the work tree is clean and only the tracked-set comparison can stop the run.
        & git -C $appLeak add manifest.sha256
        & git -C $appLeak -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c $hooksOption commit --quiet -m manifest
        $leakZip = Join-Path $TestDrive 'out/leak.zip'
        $ignored = Invoke-Child -Script (Join-Path $appLeak 'tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appLeak, '-OutputPath', $leakZip)
        $ignored.ExitCode | Should -Not -Be 0
        $ignored.Text | Should -Match 'allowlist differs from tracked files'
        Test-Path -LiteralPath $leakZip | Should -BeFalse
        [IO.File]::WriteAllBytes($exclude, $excludeOriginal)
        $untracked = Invoke-Child -Script (Join-Path $appLeak 'tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $appLeak, '-OutputPath', $leakZip)
        $untracked.ExitCode | Should -Not -Be 0
        $untracked.Text | Should -Match 'dirty|untracked'
    }

    It 'T8-3: an output path inside the app root is refused' {
        $run = Invoke-Child -Script $script:packageTool -Arguments @('-AppRoot', $script:appCopy, '-OutputPath', (Join-Path $script:appCopy 'in.zip'))
        $run.ExitCode | Should -Not -Be 0
        $run.Text | Should -Match 'E_PACKAGE_LAYOUT'
    }

    It 'T8-4: a stale manifest stops packaging' {
        $readme = Join-Path $script:appCopy 'README.md'
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

    It 'T8-5: a git work tree with an untracked file stops packaging' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $copy2 = Join-Path $TestDrive 'appcopy2'
        Copy-AppFixture -Path $copy2
        (Invoke-Child -Script (Join-Path $copy2 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $copy2)).ExitCode | Should -Be 0
        $noHooks = Join-Path $TestDrive 'nohooks'
        & git -C $copy2 init --quiet
        & git -C $copy2 add -A
        & git -C $copy2 -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=$noHooks commit --quiet -m fixture
        $clean = Invoke-Child -Script (Join-Path $copy2 'tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $copy2, '-OutputPath', (Join-Path $TestDrive 'out/git-clean.zip'))
        $clean.ExitCode | Should -Be 0 -Because $clean.Text
        [IO.File]::WriteAllText((Join-Path $copy2 'tests/extra.txt'), 'x')
        # Refresh the manifest so the manifest check passes and only the git work tree check can stop the run.
        (Invoke-Child -Script (Join-Path $copy2 'tools/Update-Manifest.ps1') -Arguments @('-AppRoot', $copy2)).ExitCode | Should -Be 0
        $dirty = Invoke-Child -Script (Join-Path $copy2 'tools/New-ReleasePackage.ps1') -Arguments @('-AppRoot', $copy2, '-OutputPath', (Join-Path $TestDrive 'out/git-dirty.zip'))
        $dirty.ExitCode | Should -Not -Be 0
        $dirty.Text | Should -Match 'dirty|untracked'
    }

    It 'T8-6: install.ps1 passes its integrity check and runs a WhatIf plan' {
        $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l1'))
        $run.ExitCode | Should -Be 0 -Because $run.Text
    }

    It 'T8-7: a modified code file stops install.ps1 with exit 23' {
        $target = Join-Path $script:appCopy 'src/LLMCliInstaller/Private/Platform.ps1'
        $original = [IO.File]::ReadAllBytes($target)
        try {
            [IO.File]::AppendAllText($target, "`n# x`n")
            $run = Invoke-Child -Script $script:installScript -Arguments @('-Components', 'google', '-NonInteractive', '-WhatIf', '-NoSupportBundle', '-LogRoot', (Join-Path $TestDrive 'l2'))
            $run.ExitCode | Should -Be 23
            $run.Text | Should -Match '무결성'
        } finally { [IO.File]::WriteAllBytes($target, $original) }
    }

    It 'T8-8: an unlisted extra script file stops install.ps1 with exit 23' {
        $extra = Join-Path $script:appCopy 'src/LLMCliInstaller/Private/Extra.ps1'
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

    It 'T8-9: a code file missing from the manifest stops install.ps1 with exit 23' {
        $manifest = Join-Path $script:appCopy 'manifest.sha256'
        $original = [IO.File]::ReadAllBytes($manifest)
        try {
            $kept = @([IO.File]::ReadAllLines($manifest) | Where-Object { $_ -notlike '*  src/LLMCliInstaller/Private/Platform.ps1' })
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
