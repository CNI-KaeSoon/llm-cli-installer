# Durable migration journal (V2_MIGRATION_PLAN §5, §14.2).
# Canonical location is fixed: %LOCALAPPDATA%\LLMCliInstaller\State\migration-journal.jsonl.
# The run directory receives only a sanitized copy.

$script:InstallerMutexName = 'Local\LLMCliInstaller'
$script:JournalClosedPhases = @('Committed', 'RemovalFailed', 'MigrationBlocked', 'Aborted')

function Get-MigrationStateRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $base) { throw 'E_LOG_UNAVAILABLE: LOCALAPPDATA를 확인할 수 없습니다.' }
    return (Join-Path (Join-Path $base 'LLMCliInstaller') 'State')
}

function Get-MigrationJournalPath {
    param([string]$StateRoot = (Get-MigrationStateRoot))
    return (Join-Path $StateRoot 'migration-journal.jsonl')
}

function Add-MigrationJournalRecord {
    # Append-only; each line is flushed through to disk before returning.
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Record)
    $directory = [IO.Path]::GetDirectoryName($Path)
    if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $line = (ConvertTo-SafeJson -Value $Record) + "`n"
    # A torn tail (crash mid-write) must not swallow this record: terminate it first.
    if ([IO.File]::Exists($Path)) {
        $reader = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($reader.Length -gt 0) {
                [void]$reader.Seek(-1, [IO.SeekOrigin]::End)
                if ($reader.ReadByte() -ne 0x0A) { $line = "`n" + $line }
            }
        } finally { $reader.Dispose() }
    }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    return $Record
}

function Read-MigrationJournal {
    # Torn/corrupt lines (e.g. crash mid-write) are skipped and counted, never repaired in place.
    param([Parameter(Mandatory=$true)][string]$Path)
    $records = New-Object System.Collections.ArrayList
    $corrupt = 0
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if (-not $line.Trim()) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                if ($record.schemaVersion -ne 2 -or -not $record.transactionId -or -not $record.phase) { $corrupt++; continue }
                [void]$records.Add($record)
            } catch { $corrupt++ }
        }
    }
    [pscustomobject]@{ Records = @($records); CorruptLineCount = $corrupt }
}

function Get-MigrationTransactionSummary {
    param([object[]]$Records)
    $lastById = [ordered]@{}
    foreach ($record in @($Records)) { $lastById[[string]$record.transactionId] = $record }
    return @($lastById.Values)
}

function Get-IncompleteMigrationTransaction {
    param([Parameter(Mandatory=$true)][string]$Path)
    $journal = Read-MigrationJournal -Path $Path
    return @(Get-MigrationTransactionSummary -Records $journal.Records | Where-Object { $script:JournalClosedPhases -notcontains [string]$_.phase })
}

function Get-JournalReconcileAction {
    # Reconciles the last durable phase with the real inventory. Completed removals are never repeated.
    param([Parameter(Mandatory=$true)]$LastRecord, $Inventory)
    $phase = [string]$LastRecord.phase
    switch ($phase) {
        'RemovalStarted' {
            $stillPresent = @($(if ($Inventory) { $Inventory.Candidates } else { @() }) | Where-Object {
                $_.PackageId -eq $LastRecord.packageId -and (Protect-SensitiveText -Text ([string]$_.EvidencePrefix)) -eq [string]$LastRecord.evidencePath
            }).Count -gt 0
            if ($stillPresent) { return 'AbortRemovalIncomplete' }
            return 'ResumeReinstall'
        }
        { @('Removed', 'ReinstallStarted', 'ReinstallFailed', 'RecoveryRequired', 'RollbackSucceeded', 'RollbackFailed') -contains $_ } { return 'ResumeReinstall' }
        { @('Reinstalled', 'MigrationVerified') -contains $_ } { return 'VerifyAndCommit' }
        default { return 'None' }
    }
}

function Save-SanitizedJournalCopy {
    param([Parameter(Mandatory=$true)][string]$JournalPath, [Parameter(Mandatory=$true)][string]$RunDirectory)
    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
    $target = Join-Path $RunDirectory 'migration-journal.sanitized.jsonl'
    $lines = @([IO.File]::ReadAllLines($JournalPath) | ForEach-Object { Protect-SensitiveText -Text $_ })
    [IO.File]::WriteAllLines($target, $lines, (New-Object Text.UTF8Encoding($false)))
    return $target
}

function Enter-InstallerMutex {
    # Returns the held mutex, or $null when another installer run already holds it.
    param([string]$Name = $script:InstallerMutexName)
    $mutex = New-Object Threading.Mutex($false, $Name)
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}

function Exit-InstallerMutex {
    param($Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { $null = $_ }
    $Mutex.Dispose()
}
