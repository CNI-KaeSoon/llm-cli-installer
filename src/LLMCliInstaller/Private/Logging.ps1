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

# ---- Console progress for non-expert users. Plain Korean only: no paths, command lines or tool output. ----

function Write-ConsoleStep {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Format-ConsoleElapsed {
    param([TimeSpan]$Elapsed)
    if ($Elapsed.TotalMinutes -ge 1) { return ('{0}분 {1}초' -f [int][Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds) }
    return ('{0}초' -f [int][Math]::Ceiling($Elapsed.TotalSeconds))
}

function Write-ConsoleSummary {
    param($Summary)
    $catalog = Get-ComponentCatalog
    Write-ConsoleStep ''
    Write-ConsoleStep '==================================================' 'Cyan'
    Write-ConsoleStep ' 설치 결과' 'Cyan'
    Write-ConsoleStep '==================================================' 'Cyan'
    if ($Summary.PSObject.Properties['WhatIf'] -and $Summary.WhatIf) {
        Write-ConsoleStep ' 미리보기만 했습니다. 설치 상태는 바뀌지 않았고 진단 기록만 남겼습니다.' 'Yellow'
        if ($Summary.LogDirectory) { Write-ConsoleStep (' 진단 기록: ' + (Protect-SensitiveText -Text ([string]$Summary.LogDirectory))) 'Gray' }
        return
    }
    foreach ($component in @($Summary.Components)) {
        $name = $(if ($catalog.ContainsKey($component.Id)) { $catalog[$component.Id].DisplayName } else { $component.Id })
        $version = $(if ($component.Version) { ' (버전 ' + $component.Version + ')' } else { '' })
        if ($component.State -in @('Verified', 'VerifiedWithWarning')) { Write-ConsoleStep (' [성공] ' + $name + $version) 'Green' }
        elseif ($component.State -eq 'RestartRequired') { Write-ConsoleStep (' [재부팅 필요] ' + $name) 'Yellow' }
        elseif ($component.State -eq 'UnattemptedBlocked') { Write-ConsoleStep (' [건너뜀] ' + $name + ' - 먼저 필요한 프로그램 설치가 실패했습니다') 'Yellow' }
        else { Write-ConsoleStep (' [실패] ' + $name + ' (오류 코드 ' + $component.PrimaryCode + ')') 'Red' }
    }
    Write-ConsoleStep ''
    switch ([int]$Summary.ExitCode) {
        0 {
            $commandById = @{ codex='codex'; claude='claude'; antigravity='agy'; grok='grok'; 'legacy-gemini'='gemini' }
            $ready = @($Summary.Components | Where-Object { $_.State -in @('Verified', 'VerifiedWithWarning') -and $commandById.ContainsKey($_.Id) } | ForEach-Object { $commandById[$_.Id] })
            if ($ready.Count -gt 0) { Write-ConsoleStep (' 모두 끝났습니다. 새 터미널 창을 열면 {0} 명령을 쓸 수 있습니다.' -f ($ready -join ', ')) 'Green' }
            else { Write-ConsoleStep ' 모두 끝났습니다.' 'Green' }
        }
        42 { Write-ConsoleStep ' 설치는 끝났지만 컴퓨터를 다시 시작해야 합니다. 재부팅 후 이 설치기를 한 번 더 실행하세요.' 'Yellow' }
        65 { Write-ConsoleStep ' 다른 설치기가 이미 실행 중입니다. 그 창이 끝난 뒤 다시 실행하세요.' 'Yellow' }
        default { Write-ConsoleStep ' 일부 항목이 실패했습니다. 인터넷 연결을 확인하고 다시 실행해 보세요. 이미 설치된 항목은 건너뜁니다.' 'Red' }
    }
    if ($Summary.LogDirectory) {
        Write-ConsoleStep (' 자세한 기록(summary.json, run.log): ' + (Protect-SensitiveText -Text ([string]$Summary.LogDirectory))) 'Gray'
    }
    if ([int]$Summary.ExitCode -ne 0 -and $Summary.SupportBundle) {
        Write-ConsoleStep (' 계속 실패하면 이 파일을 보내 주세요: ' + (Protect-SensitiveText -Text ([string]$Summary.SupportBundle))) 'Gray'
    }
}
