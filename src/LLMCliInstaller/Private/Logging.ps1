function Initialize-RunLogging {
    param($Context, [string]$RequestedRoot)
    $candidates = New-Object System.Collections.ArrayList
    if ($RequestedRoot) { [void]$candidates.Add($RequestedRoot) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'LLMCliInstaller/Logs')) }
    [void]$candidates.Add((Join-Path ([IO.Path]::GetTempPath()) 'LLMCliInstaller/Logs'))
    foreach ($root in $candidates) {
        try {
            $directory = Join-Path $root $Context.RunId
            [IO.Directory]::CreateDirectory($directory) | Out-Null
            $Context.LogRoot = $root
            $Context.RunDirectory = $directory
            $Context.TextLog = Join-Path $directory 'run.log'
            $Context.JsonLog = Join-Path $directory 'events.jsonl'
            [IO.File]::WriteAllText($Context.TextLog, '', (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($Context.JsonLog, '', (New-Object Text.UTF8Encoding($false)))
            return $Context
        } catch { continue }
    }
    throw 'E_LOG_UNAVAILABLE: 로그 경로에 쓸 수 없습니다.'
}

# §7 schema v2 migration fields. Only these scalar keys are ever copied into an event.
$script:MigrationEventFields = @('migrationTransactionId', 'decision', 'provenanceGrade', 'canonicality', 'candidateCount', 'candidateFingerprint', 'ownerManager', 'packageId', 'phase', 'pathDeltaCount', 'rollbackAttempted', 'rollbackResult', 'journalCheckpoint', 'reasonCode')

function Write-RunEvent {
    param($Context, [string]$Stage, [string]$Status, [string]$Component, [string]$Message, [int]$Code = 0, $Data, [hashtable]$Migration)
    $Context.Sequence++
    # v1 fields are kept unchanged; v2 adds the allowlisted migration fields only.
    $logEvent = [ordered]@{
        schemaVersion = 2
        sequence = $Context.Sequence
        timestamp = [DateTime]::UtcNow.ToString('o')
        runId = $Context.RunId
        stage = $Stage
        status = $Status
        component = $Component
        code = $Code
        message = Protect-SensitiveText -Text $Message
        data = ConvertTo-MaskedValue -Value $Data
    }
    if ($Migration) {
        foreach ($field in $script:MigrationEventFields) {
            if (-not $Migration.ContainsKey($field)) { continue }
            $value = $Migration[$field]
            if ($null -ne $value -and -not ($value -is [string] -or $value -is [int] -or $value -is [long] -or $value -is [bool])) { $value = '[redacted:' + $value.GetType().Name + ']' }
            $logEvent[$field] = $value
        }
    }
    $json = ConvertTo-SafeJson -Value $logEvent
    $line = '{0} [{1}] {2}/{3}: {4}' -f $logEvent.timestamp, $Status, $Stage, $Component, $logEvent.message
    [IO.File]::AppendAllText($Context.JsonLog, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::AppendAllText($Context.TextLog, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
