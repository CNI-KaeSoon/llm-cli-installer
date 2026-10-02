function Get-ComponentStatus {
    param([string]$Id, $Definition)
    $verification = Get-VerificationResult -Id $Id -Definition $Definition
    if ($verification.Success) { return [pscustomobject]@{ State='Satisfied'; Verification=$verification } }
    return [pscustomobject]@{ State='Missing'; Verification=$verification }
}

function Get-ComponentInstallPlan {
    param([string]$Id, $Definition, [string]$CurrentState)
    [pscustomobject]@{
        Id = $Id
        Action = $(if ($CurrentState -eq 'Satisfied') { 'SkipAndVerify' } else { 'InstallAndVerify' })
        Channel = $Definition.Install
        RequiresElevation = ($Definition.Install -eq 'winget')
        VerifyCommands = $Definition.VerifyCommands
    }
}

function Install-Component {
    param([string]$Id, $Definition, $Context, [switch]$NonInteractive)
    $vendorLog = Join-Path $Context.RunDirectory ("native-{0}.log" -f $Id)
    switch ($Definition.Install) {
        'winget' {
            return Invoke-WinGetInstall -PackageId $Definition.PackageId -VendorLog $vendorLog
        }
        'official-script' {
            $environment = @{}
            if ($Id -eq 'codex') { $environment.CODEX_NON_INTERACTIVE = '1' }
            $process = Install-OfficialPowerShellScript -Uri $Definition.InstallerUri -AllowedHosts @($Definition.InstallerHosts) -Environment $environment -Context $Context -ComponentId $Id
            return [pscustomobject]@{ Process=$process; StableCode=$(if ($process.ExitCode -eq 0) { 0 } elseif ($process.TimedOut) { 20 } else { 40 }); RestartRequired=$false }
        }
        'npm' {
            # §14.1: canonical npm target is the effective prefix; pin it explicitly when it is known.
            $prefix = Get-NpmEffectivePrefix
            $arguments = Get-NpmInstallArgumentList -Package $Definition.Package -Prefix $prefix
            $process = Invoke-SafeProcess -FilePath 'npm' -ArgumentList $arguments -TimeoutSeconds 900 -CloseInput
            $npmCode = 40
            if ($process.ExitCode -eq 0) { $npmCode = 0 }
            elseif ($process.ExitCode -eq 127) { $npmCode = 22 }
            elseif ($process.TimedOut) { $npmCode = 20 }
            elseif ($process.ExitCode -eq 126) { $npmCode = 21 }
            return [pscustomobject]@{ Process=$process; StableCode=$npmCode; RestartRequired=$false }
        }
        'python-manager' {
            # 9NQ7512CXL7T is a Microsoft Store ID; the winget community source does not list it.
            $manager = Invoke-WinGetInstall -PackageId $Definition.PackageId -VendorLog $vendorLog -Source 'msstore'
            if ($manager.StableCode -ne 0 -and -not $manager.RestartRequired) { return $manager }
            Update-ProcessPath | Out-Null
            $process = Invoke-SafeProcess -FilePath 'pymanager' -ArgumentList @('install', '3.14') -TimeoutSeconds 900 -Environment @{ PYTHON_MANAGER_CONFIRM='false' } -CloseInput:$NonInteractive
            if ($process.TimedOut -and $NonInteractive) { return [pscustomobject]@{ Process=$process; StableCode=25; RestartRequired=$false } }
            if ($process.ExitCode -ne 0) { return [pscustomobject]@{ Process=$process; StableCode=40; RestartRequired=$false } }
            $list = Invoke-SafeProcess -FilePath 'pymanager' -ArgumentList @('list') -TimeoutSeconds 60 -CloseInput
            if ($list.ExitCode -ne 0 -or -not (Test-PythonManagerList $list.StdOut)) { return [pscustomobject]@{ Process=$list; StableCode=50; RestartRequired=$false } }
            $verify = Invoke-SafeProcess -FilePath 'pymanager' -ArgumentList @('exec', '-V:3.14', '-c', 'import sys; print(".".join(map(str, sys.version_info[:3])))') -TimeoutSeconds 60 -CloseInput
            return [pscustomobject]@{ Process=$verify; StableCode=$(if ($verify.ExitCode -eq 0) { 0 } else { 50 }); RestartRequired=$manager.RestartRequired }
        }
        default { throw "E_INTERNAL_STATE: unsupported install channel $($Definition.Install)" }
    }
}

function Test-ComponentInstallation {
    param([string]$Id, $Definition)
    $verification = Get-VerificationResult -Id $Id -Definition $Definition
    if (-not $verification.Success) { return $verification }
    if ($Id -eq 'claude') {
        $doctor = Invoke-SafeProcess -FilePath 'claude' -ArgumentList @('doctor') -TimeoutSeconds 120 -CloseInput
        $classification = Get-ClaudeDoctorClassification -ExitCode $doctor.ExitCode -Output (($doctor.StdOut, $doctor.StdErr) -join "`n")
        $verification.Status = $classification.Status
        $verification.Code = $classification.Code
        if ($classification.Code -ne 0) { $verification.Success = $false }
    }
    return $verification
}

# ---- v2 provider removal contract (V2_MIGRATION_PLAN §2.4, §14.1) ----

function Get-MigrationRemoverSummary {
    param($Candidate)
    if (-not $Candidate) { return $null }
    switch ([string]$Candidate.OwnerManager) {
        'npm' { return (Join-CommandSummary 'npm' (Get-NpmUninstallArgumentList -Prefix $Candidate.EvidencePrefix -Package $Candidate.PackageId)) }
        'pymanager' { return (Join-CommandSummary 'pymanager' (Get-PyManagerUninstallArgumentList -Tag $Candidate.PackageId)) }
        default { return $null }
    }
}

function Get-MigrationRecoveryCommand {
    # Raw runnable command for the console. Every persisted copy (journal, events, summary) is masked on write.
    param($Candidate)
    if (-not $Candidate) { return $null }
    switch ([string]$Candidate.OwnerManager) {
        'npm' {
            $spec = $(if ($Candidate.PackageVersion) { '{0}@{1}' -f $Candidate.PackageId, $Candidate.PackageVersion } else { [string]$Candidate.PackageId })
            return (Join-CommandSummary 'npm' @('install', '-g', '--prefix', [string]$Candidate.EvidencePrefix, $spec) -NoMask)
        }
        'pymanager' { return (Join-CommandSummary 'pymanager' @('install', [string]$Candidate.PackageId) -NoMask) }
        default { return $null }
    }
}

function Invoke-ComponentRemoval {
    # The only removal entry point. P3 + npm/pymanager owner is enforced here as a last guard.
    param([Parameter(Mandatory=$true)]$Candidate)
    if ($Candidate.ProvenanceGrade -ne 'P3') { throw 'E_INTERNAL_STATE: removal requires P3 provenance' }
    switch ([string]$Candidate.OwnerManager) {
        'npm' { return (Invoke-NpmUninstall -Prefix $Candidate.EvidencePrefix -Package $Candidate.PackageId) }
        'pymanager' { return (Invoke-PyManagerUninstall -Tag $Candidate.PackageId) }
        default { throw 'E_INTERNAL_STATE: no official remover for owner manager' }
    }
}
