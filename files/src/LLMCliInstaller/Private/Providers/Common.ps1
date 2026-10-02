function Get-ComponentCatalog {
    $path = Join-Path $script:ModuleRoot 'Data/Components.psd1'
    return Import-PowerShellDataFile -Path $path
}

function Resolve-ComponentSelection {
    param([string[]]$Components, [switch]$AllowLegacyGemini)
    if (-not $Components -or $Components.Count -eq 0) { throw 'E_INVALID_ARGUMENT: 구성요소를 선택해야 합니다.' }
    $aliases = @{ google='antigravity'; gemini='antigravity' }
    $allowed = @('codex', 'claude', 'antigravity', 'grok', 'legacy-gemini')
    $selected = New-Object System.Collections.ArrayList
    $expanded = @($Components | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($expanded.Count -eq 0) { throw 'E_INVALID_ARGUMENT: 구성요소를 선택해야 합니다.' }
    foreach ($component in $expanded) {
        $id = ([string]$component).Trim().ToLowerInvariant()
        if ($id -eq 'all') {
            foreach ($default in @('codex', 'claude', 'antigravity', 'grok')) { if ($selected -notcontains $default) { [void]$selected.Add($default) } }
            continue
        }
        if ($aliases.ContainsKey($id)) { $id = $aliases[$id] }
        if ($allowed -notcontains $id) { throw "E_INVALID_ARGUMENT: 알 수 없는 구성요소 '$component'" }
        if ($id -eq 'legacy-gemini' -and -not $AllowLegacyGemini) { throw 'E_INVALID_ARGUMENT: Legacy Gemini는 -AllowLegacyGemini를 함께 지정해야 합니다.' }
        if ($selected -notcontains $id) { [void]$selected.Add($id) }
    }
    return @($selected)
}

function Get-VerificationResult {
    param([string]$Id, $Definition)
    $process = $null
    foreach ($candidate in @($Definition.VerifyCommands)) {
        $command = [string]$candidate.File
        $arguments = @($candidate.Arguments)
        $process = Invoke-SafeProcess -FilePath $command -ArgumentList $arguments -TimeoutSeconds 60 -CloseInput
        if ($process.ExitCode -ne 0) { continue }
        $version = Get-StrictSemanticVersion -Text (($process.StdOut, $process.StdErr) -join "`n")
        if (-not $version) { continue }
        if ($Id -eq 'node' -and -not (Test-MinimumSemanticVersion $version.Normalized '22.0.0')) { continue }
        if ($Id -eq 'python' -and -not (Test-MinimumSemanticVersion $version.Normalized '3.12.0')) { continue }
        return [pscustomobject]@{ Success=$true; Version=$version.Normalized; Process=$process; Status='Verified'; Code=0 }
    }
    return [pscustomobject]@{ Success=$false; Version=$null; Process=$process; Status='VerificationFailed'; Code=50 }
}

function Test-PythonManagerList {
    param([string]$Text)
    # Count runtime rows, not occurrences: one real row repeats 3.14 in Tag, Name, Version and Alias,
    # e.g. '3.14[-64]  *  Python 3.14.8  PythonCore  3.14.8   python3[-64].exe, python3.14[-64].exe'.
    $runtimeRows = [regex]::Matches([string]$Text, '(?m)^[ \t]*(?:\*[ \t]*)?3\.14(?![0-9])')
    return ($runtimeRows.Count -eq 1)
}

function Get-ClaudeDoctorClassification {
    param([int]$ExitCode, [string]$Output)
    if ($ExitCode -ne 0) { return [pscustomobject]@{ Status='VerificationFailed'; Code=50 } }
    if ($Output -match '(?i)(missing|corrupt|incompatible|Git Bash.*(missing|failed)|runtime error)') { return [pscustomobject]@{ Status='VerificationFailed'; Code=50 } }
    if ($Output -match '(?i)(authentication|required|update available|configuration)') { return [pscustomobject]@{ Status='VerifiedWithWarning'; Code=0 } }
    return [pscustomobject]@{ Status='Verified'; Code=0 }
}

# ---- v2 inventory, canonical path and provenance grading (V2_MIGRATION_PLAN §2.2-§2.4) ----

$script:SignerSubjectAllowlist = @{
    powershell = @('Microsoft Corporation')
    git = @('Johannes Schindelin')
    node = @('OpenJS Foundation')
    codex = @('OpenAI')
    claude = @('Anthropic', 'Anthropic, PBC')
    antigravity = @('Google LLC')
}

function Get-CertificateOrganization {
    # First O= value of a certificate subject; quoted RDN values ("A, B") are parsed and "" is unescaped.
    param([string]$Subject)
    $match = [regex]::Match([string]$Subject, '(?:^|,\s*)O=(?:"((?:[^"]|"")*)"|([^,]*))')
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return ($match.Groups[1].Value -replace '""', '"').Trim() }
    return $match.Groups[2].Value.Trim()
}

function Resolve-CanonicalRoot {
    # Expands a catalog CanonicalInstall token. Unresolved environment tokens yield $null (never guessed).
    param([string]$Token, [string]$NpmEffectivePrefix)
    if (-not $Token) { return $null }
    if ($Token -eq 'npm-effective-prefix') { return (Get-NpmExecutableDirectory -Prefix $NpmEffectivePrefix) }
    if ($Token -eq 'pymanager-managed') { return $null }
    if ($Token -eq '%CODEX_INSTALL_DIR%' -and -not $env:CODEX_INSTALL_DIR) {
        # Official Windows installer default (openai/codex scripts/install/install.ps1, checked 2026-09-23):
        # $visibleBinDir = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin" when CODEX_INSTALL_DIR is unset.
        $localAppData = $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') })
        if (-not $localAppData) { return $null }
        return (Join-Path $localAppData 'Programs\OpenAI\Codex\bin')
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Token)
    if ($expanded -match '%[^%]+%') { return $null }
    return $expanded
}

function Get-ComponentCanonicalRoot {
    param([Parameter(Mandatory=$true)]$Definition, [string]$NpmEffectivePrefix, [object[]]$ManagedRuntimes = @())
    $roots = New-Object System.Collections.ArrayList
    foreach ($token in @($Definition.CanonicalInstall)) {
        if ($token -eq 'pymanager-managed') {
            foreach ($runtime in @($ManagedRuntimes)) { if ($runtime.Executable) { [void]$roots.Add([IO.Path]::GetDirectoryName([string]$runtime.Executable)) } }
            continue
        }
        $root = Resolve-CanonicalRoot -Token $token -NpmEffectivePrefix $NpmEffectivePrefix
        if ($root) { [void]$roots.Add($root) }
    }
    return @($roots)
}

function Test-CanonicalPath {
    param([string]$Path, [string[]]$CanonicalRoots)
    foreach ($root in @($CanonicalRoots)) { if (Test-PathUnderRoot -Path $Path -Root $root) { return $true } }
    return $false
}

function Get-ProvenanceGrade {
    # P3 needs every ownership evidence kind from the catalog plus exactly one package match and a remover-capable component.
    # Path strings, file names, version output or package listing alone never reach P2/P3.
    param([object[]]$Evidence, [Parameter(Mandatory=$true)]$Definition, [int]$PackageMatchCount = 0)
    $matched = @{}
    foreach ($item in @($Evidence)) { if ($item -and $item.Matched) { $matched[[string]$item.Kind] = $true } }
    $required = @($Definition.OwnershipEvidence)
    $supportsRemoval = ([string]$Definition.MigrationSupport -ne 'KeepOnly')
    $hasAllOwnership = ($required.Count -gt 0)
    foreach ($kind in $required) { if (-not $matched.ContainsKey([string]$kind)) { $hasAllOwnership = $false } }
    if ($supportsRemoval -and $hasAllOwnership -and $PackageMatchCount -eq 1 -and $matched.ContainsKey('RemoverAvailable')) { return 'P3' }
    if ($matched.ContainsKey('SignerAllowlist') -and $matched.ContainsKey('OfficialMarker')) { return 'P2' }
    if ($matched.ContainsKey('PackageInventory')) { return 'P1' }
    return 'P0'
}

function Get-InventoryFingerprint {
    param([object[]]$Candidates)
    $lines = foreach ($candidate in @($Candidates | Where-Object { $_ } | Sort-Object CandidateId)) {
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $candidate.CandidateId, $candidate.FileIdentity, $candidate.OwnerManager, $candidate.PackageId, $candidate.PackageVersion, $candidate.EvidencePrefix, $candidate.Reparse, $candidate.Lock, $candidate.IsPathWinner, $candidate.IsCanonical, $candidate.ProvenanceGrade
    }
    return (Get-TextSha256 -Text (@($lines) -join "`n"))
}

function Complete-ComponentInventory {
    # Pure classification over collected candidates; used by live inventory and by fixtures.
    param([Parameter(Mandatory=$true)][string]$ComponentId, [object[]]$Candidates = @(), [Parameter(Mandatory=$true)]$Definition, [string[]]$CanonicalRoots = @())
    $list = @($Candidates | Where-Object { $_ })
    foreach ($candidate in $list) {
        $candidate.ProvenanceGrade = Get-ProvenanceGrade -Evidence $candidate.Evidence -Definition $Definition -PackageMatchCount $candidate.PackageMatchCount
    }
    $canonicality = 'None'
    if ($list.Count -gt 1) { $canonicality = 'Ambiguous' }
    elseif ($list.Count -eq 1) {
        $single = $list[0]
        if ($single.Reparse) { $canonicality = 'ReparseBlocked' }
        elseif ($single.IsCanonical -and @('P2', 'P3') -contains $single.ProvenanceGrade) { $canonicality = 'Canonical' }
        elseif (@('P0', 'P1') -contains $single.ProvenanceGrade) { $canonicality = 'Untrusted' }
        else { $canonicality = 'NonCanonical' }
    }
    foreach ($candidate in $list) { $candidate.Canonicality = $canonicality }
    [pscustomobject]@{
        ComponentId = $ComponentId
        Candidates = @($list)
        CandidateCount = $list.Count
        Canonicality = $canonicality
        CanonicalRoots = @($CanonicalRoots)
        Fingerprint = (Get-InventoryFingerprint -Candidates $list)
    }
}

function Test-UserWritablePrefix {
    param([string]$Prefix)
    $userRoot = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME })
    return (Test-PathUnderRoot -Path $Prefix -Root $userRoot)
}

function Get-NpmCandidateEvidence {
    param([string]$Path, [string]$Directory, $Definition)
    $evidence = New-Object System.Collections.ArrayList
    $package = [string]$Definition.NpmPackage
    $prefix = $(if ($env:OS -eq 'Windows_NT') { $Directory } else { [IO.Path]::GetDirectoryName($Directory) })
    $inventory = Get-NpmGlobalPackageInventory -Prefix $prefix
    $listed = $inventory.ContainsKey($package)
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PackageInventory' -Source 'npm-ls' -Matched $listed -Detail $package))
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PackageName' -Source 'catalog' -Matched $listed -Detail $package))
    $moduleRoot = $(if ($env:OS -eq 'Windows_NT') { Join-Path $prefix 'node_modules' } else { Join-Path $prefix 'lib/node_modules' })
    $packageDirectory = Join-Path $moduleRoot $package
    $contained = ($listed -and (Test-Path -LiteralPath $packageDirectory -PathType Container) -and ((Get-NpmExecutableDirectory -Prefix $prefix) -eq $Directory))
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PrefixContainment' -Source 'npm-prefix' -Matched $contained -Detail 'prefix contains package root and shim'))
    $shimMatched = $false
    try {
        $shimText = [IO.File]::ReadAllText($Path)
        if ($shimText.Length -le 65536) { $shimMatched = ($shimText.Replace('\', '/') -match [regex]::Escape('node_modules/' + $package)) }
    } catch { $shimMatched = $false }
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'ShimReference' -Source 'shim' -Matched $shimMatched -Detail 'shim references package root'))
    $writable = Test-UserWritablePrefix -Prefix $prefix
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'UserWritable' -Source 'prefix' -Matched $writable -Detail 'prefix under user profile'))
    [void]$evidence.Add((New-ProvenanceEvidence -Kind 'RemoverAvailable' -Source 'npm' -Matched $listed -Detail 'npm uninstall -g --prefix'))
    [pscustomobject]@{ Evidence = @($evidence); Prefix = $prefix; Version = $(if ($listed) { $inventory[$package] } else { $null }); MatchCount = $(if ($listed) { 1 } else { 0 }) }
}

function Get-ComponentInventory {
    # Read-only. Windows-only probes are isolated here; non-Windows returns an empty inventory.
    param([Parameter(Mandatory=$true)][string]$Id, [Parameter(Mandatory=$true)]$Definition, [string]$NpmEffectivePrefix, [object[]]$ManagedRuntimes = @())
    $roots = @(Get-ComponentCanonicalRoot -Definition $Definition -NpmEffectivePrefix $NpmEffectivePrefix -ManagedRuntimes $ManagedRuntimes)
    if ($env:OS -ne 'Windows_NT') { return (Complete-ComponentInventory -ComponentId $Id -Candidates @() -Definition $Definition -CanonicalRoots $roots) }
    $byDirectory = [ordered]@{}
    $winner = $null
    foreach ($name in @($Definition.VerifyCommands | ForEach-Object { [string]$_.File } | Select-Object -Unique)) {
        foreach ($command in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            $source = [string]$command.Source
            if (-not $source) { continue }
            if (-not $winner) { $winner = $source }
            $directory = [IO.Path]::GetDirectoryName($source)
            $key = $directory.ToLowerInvariant()
            if (-not $byDirectory.Contains($key)) { $byDirectory[$key] = $source }
        }
    }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($key in $byDirectory.Keys) {
        $path = [string]$byDirectory[$key]
        $directory = [IO.Path]::GetDirectoryName($path)
        $evidence = New-Object System.Collections.ArrayList
        $identity = Get-FileIdentity -Path $path
        [void]$evidence.Add((New-ProvenanceEvidence -Kind 'FileIdentity' -Source 'filesystem' -Matched ([bool]$identity) -Detail 'size+timestamps'))
        $owner = 'none'; $packageId = $null; $version = $null; $prefix = $null; $matchCount = 0
        $isCanonical = Test-CanonicalPath -Path $directory -CanonicalRoots $roots
        if ($Definition.Remover -eq 'npm') {
            $npm = Get-NpmCandidateEvidence -Path $path -Directory $directory -Definition $Definition
            foreach ($item in $npm.Evidence) { [void]$evidence.Add($item) }
            if ($npm.MatchCount -gt 0) { $owner = 'npm'; $packageId = [string]$Definition.NpmPackage; $version = $npm.Version; $prefix = $npm.Prefix; $matchCount = $npm.MatchCount }
            if ($Definition.MigrationSupport -eq 'NpmOnly') { $isCanonical = ($isCanonical -and $owner -ne 'npm') }
        } elseif ($Definition.Remover -eq 'pymanager') {
            $owning = @($ManagedRuntimes | Where-Object { $_.Executable -and (Test-PathUnderRoot -Path $path -Root ([IO.Path]::GetDirectoryName([string]$_.Executable))) })
            $matchCount = $owning.Count
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PackageInventory' -Source 'pymanager-list' -Matched ($owning.Count -ge 1) -Detail 'managed runtime'))
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PrefixContainment' -Source 'pymanager-list' -Matched ($owning.Count -eq 1) -Detail 'executable under managed runtime root'))
            $exactTag = ($owning.Count -eq 1 -and (Test-PyManagerExactTag -Tag $owning[0].Tag))
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'PackageName' -Source 'pymanager-list' -Matched $exactTag -Detail 'exact tag'))
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'RemoverAvailable' -Source 'pymanager' -Matched $exactTag -Detail 'pymanager uninstall --yes <tag>'))
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'UserWritable' -Source 'runtime-root' -Matched (Test-UserWritablePrefix -Prefix $directory) -Detail 'runtime under user profile'))
            if ($owning.Count -eq 1) { $owner = 'pymanager'; $packageId = [string]$owning[0].Tag; $version = [string]$owning[0].Version; $prefix = [IO.Path]::GetDirectoryName([string]$owning[0].Executable) }
        }
        if ($script:SignerSubjectAllowlist.ContainsKey($Id) -and $path -match '(?i)\.exe$') {
            $signed = $false
            try {
                $signature = Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop
                $subject = $(if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' })
                $organization = Get-CertificateOrganization -Subject $subject
                $signed = ($signature.Status -eq 'Valid' -and $null -ne $organization -and @($script:SignerSubjectAllowlist[$Id] | Where-Object { $_ -ieq $organization }).Count -gt 0)
            } catch { $signed = $false }
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'SignerAllowlist' -Source 'authenticode' -Matched $signed -Detail 'signer subject allowlist'))
            [void]$evidence.Add((New-ProvenanceEvidence -Kind 'OfficialMarker' -Source 'canonical-root' -Matched ($signed -and $isCanonical) -Detail 'signed binary in documented layout'))
        }
        $candidate = New-InstallCandidate -ComponentId $Id -Path $path -Directory $directory -FileIdentity $identity -OwnerManager $owner -PackageId $packageId -PackageVersion $version -EvidencePrefix $prefix -PackageMatchCount $matchCount -Reparse (Test-ReparsePath -Path $path) -Locked (Test-FileLocked -Path $path) -IsPathWinner ($path -eq $winner) -IsCanonical $isCanonical -Evidence @($evidence)
        [void]$candidates.Add($candidate)
    }
    return (Complete-ComponentInventory -ComponentId $Id -Candidates @($candidates) -Definition $Definition -CanonicalRoots $roots)
}
