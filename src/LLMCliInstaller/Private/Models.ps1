function New-RunContext {
    param([guid]$RunId, [string]$LogRoot)
    [pscustomobject]@{
        RunId = $RunId.ToString()
        State = 'Created'
        Sequence = 0
        StartedAt = [DateTime]::UtcNow
        LogRoot = $LogRoot
        RunDirectory = $null
        TextLog = $null
        JsonLog = $null
        Components = New-Object System.Collections.ArrayList
        Errors = New-Object System.Collections.ArrayList
        MigrationPlans = @{}
        MigrationCanonicalRoots = @{}
        MigrationResults = New-Object System.Collections.ArrayList
        RecoveryResults = New-Object System.Collections.ArrayList
        AbortCode = 0
    }
}

function New-ComponentResult {
    param([Parameter(Mandatory=$true)][string]$Id)
    [pscustomobject]@{
        Id = $Id
        State = 'Unknown'
        PrimaryCode = 0
        RawExitCode = $null
        Message = $null
        Version = $null
        ResolvedPath = $null
        CommandSummary = $null
        RestartRequired = $false
        MigrationState = 'InventoryUnknown'
        Decision = $null
        ProvenanceGrade = $null
        Canonicality = $null
        ReasonCode = $null
        MigrationTransactionId = $null
        RecoveryAction = $null
    }
}

function Set-ComponentFailure {
    param($Result, [int]$Code, [string]$Message, [Nullable[int]]$RawExitCode)
    if ([int]$Result.PrimaryCode -eq 0) { $Result.PrimaryCode = $Code }
    if ($null -ne $RawExitCode) { $Result.RawExitCode = $RawExitCode }
    $Result.Message = Protect-SensitiveText -Text $Message
    $Result
}

function Get-StrictSemanticVersion {
    param([AllowEmptyString()][string]$Text)
    $versionMatches = [regex]::Matches([string]$Text, '(?<![0-9])v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+][0-9A-Za-z.-]+)?(?![0-9])')
    if ($versionMatches.Count -ne 1) { return $null }
    $match = $versionMatches[0]
    [pscustomobject]@{
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
        Normalized = '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
    }
}

function Test-MinimumSemanticVersion {
    param([string]$Actual, [string]$Minimum)
    try { return ([version]$Actual -ge [version]$Minimum) } catch { return $false }
}

# ---- v2 migration models (V2_MIGRATION_PLAN §2.3, §3, §5) ----

$script:ProvenanceGrades = @('P0', 'P1', 'P2', 'P3')
$script:ProvenanceGradeNames = @{ P0='UnknownOrUntrusted'; P1='KnownPackageUncorrelated'; P2='TrustedButNoOfficialRemover'; P3='TrustedRemovable' }
$script:EvidenceKinds = @('FileIdentity', 'PackageInventory', 'PrefixContainment', 'ShimReference', 'PackageName', 'RemoverAvailable', 'UserWritable', 'SignerAllowlist', 'OfficialMarker')

function New-ProvenanceEvidence {
    param(
        [Parameter(Mandatory=$true)][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Source,
        [bool]$Matched,
        [string]$Detail
    )
    if ($script:EvidenceKinds -notcontains $Kind) { throw "E_INTERNAL_STATE: unknown evidence kind $Kind" }
    [pscustomobject]@{
        Kind = $Kind
        Source = $Source
        Matched = [bool]$Matched
        Detail = Protect-SensitiveText -Text $Detail
    }
}

function New-InstallCandidate {
    param(
        [Parameter(Mandatory=$true)][string]$ComponentId,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Directory,
        [string]$FileIdentity,
        [string]$OwnerManager = 'none',
        [string]$PackageId,
        [string]$PackageVersion,
        [string]$PackageScope,
        [string]$EvidencePrefix,
        [int]$PackageMatchCount = 0,
        [bool]$Reparse = $false,
        [bool]$Locked = $false,
        [bool]$IsPathWinner = $false,
        [bool]$IsCanonical = $false,
        [object[]]$Evidence = @()
    )
    if (-not $Directory) { $Directory = [IO.Path]::GetDirectoryName($Path) }
    $identitySeed = ('{0}|{1}' -f $ComponentId, $Directory.ToLowerInvariant())
    [pscustomobject]@{
        CandidateId = ('{0}-{1}' -f $ComponentId, (Get-TextSha256 -Text $identitySeed).Substring(0, 12))
        ComponentId = $ComponentId
        Path = $Path
        Directory = $Directory
        FileIdentity = $FileIdentity
        OwnerManager = $OwnerManager
        PackageId = $PackageId
        PackageVersion = $PackageVersion
        PackageScope = $PackageScope
        EvidencePrefix = $EvidencePrefix
        PackageMatchCount = $PackageMatchCount
        Reparse = [bool]$Reparse
        Lock = [bool]$Locked
        IsPathWinner = [bool]$IsPathWinner
        IsCanonical = [bool]$IsCanonical
        Evidence = @($Evidence)
        ProvenanceGrade = 'P0'
        Canonicality = $null
    }
}

function New-MigrationPlan {
    param([Parameter(Mandatory=$true)][string]$ComponentId)
    [pscustomobject]@{
        ComponentId = $ComponentId
        Policy = 'Keep'
        Decision = 'Keep'
        Action = 'SkipAndVerify'
        ReasonCode = 'NoExistingInstall'
        StableCode = 0
        CandidateCount = 0
        Candidate = $null
        Candidates = @()
        Canonicality = 'None'
        ProvenanceGrade = $null
        InventoryFingerprint = $null
        RemoverSummary = $null
        InstallerSummary = $null
        PreserveScopes = @()
        RequiresElevation = $false
        PathDelta = 'none'
        RollbackPossible = $false
        ExpectedStates = @()
        RecoveryAction = $null
    }
}

function New-MigrationResult {
    param([Parameter(Mandatory=$true)][string]$ComponentId, [string]$TransactionId)
    [pscustomobject]@{
        ComponentId = $ComponentId
        TransactionId = $TransactionId
        FinalState = $null
        StableCode = 0
        RemoverInvocations = 0
        InstallerInvocations = 0
        RollbackAttempted = $false
        RollbackResult = 'NotAttempted'
        RecoveryAction = $null
    }
}

function New-JournalRecord {
    param(
        [Parameter(Mandatory=$true)][string]$TransactionId,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][string]$ComponentId,
        [Parameter(Mandatory=$true)][string]$Phase,
        [string]$CandidateFingerprint,
        [string]$ProvenanceGrade,
        [string]$Decision = 'Migrate',
        [string]$PackageManager,
        [string]$PackageId,
        [string]$OldVersion,
        [string]$NewVersion,
        [string]$EvidencePath,
        [string]$PathSnapshotHash,
        [Nullable[int]]$RawExitCode,
        [int]$StableCode = 0,
        [string]$RecoveryAction,
        [bool]$Commit = $false
    )
    [ordered]@{
        schemaVersion = 2
        transactionId = $TransactionId
        runId = $RunId
        componentId = $ComponentId
        candidateFingerprint = $CandidateFingerprint
        provenanceGrade = $ProvenanceGrade
        decision = $Decision
        phase = $Phase
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        packageManager = $PackageManager
        packageId = $PackageId
        oldVersion = $OldVersion
        newVersion = $NewVersion
        evidencePath = Protect-SensitiveText -Text $EvidencePath
        pathSnapshotHash = $PathSnapshotHash
        rawExitCode = $RawExitCode
        stableCode = $StableCode
        recoveryAction = Protect-SensitiveText -Text $RecoveryAction
        commit = [bool]$Commit
    }
}

function Get-TextSha256 {
    param([AllowEmptyString()][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $algorithm.Dispose() }
}
