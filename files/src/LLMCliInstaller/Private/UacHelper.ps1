# Elevation is used for install only. Migration (uninstall/reinstall) never elevates (V2_MIGRATION_PLAN §14.6).
$script:ElevatedOperationAllowlist = @('winget-install')
$script:ElevationChannelEnabled = $false

function Test-ElevatedOperationAllowed {
    param([string]$Operation)
    if ([string]$Operation -match '(?i)uninstall|remove|migrat') { return $false }
    return ($script:ElevatedOperationAllowlist -contains $Operation)
}

function Invoke-ValidatedElevatedOperation {
    param([string]$Operation, [hashtable]$Arguments, [int]$TimeoutSeconds = 900)
    if (-not $script:ElevationChannelEnabled) { throw 'E_ELEVATION_CHANNEL: elevation helper is disabled in this release (see SECURITY.md)' }
    if (-not (Test-ElevatedOperationAllowed -Operation $Operation)) { throw 'E_ELEVATION_CHANNEL: operation not allowed' }
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('llm-cli-uac-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $requestPath = Join-Path $staging 'request.json'
    $resultPath = Join-Path $staging 'result.json'
    $markerPath = Join-Path $staging 'complete.marker'
    $operationId = [guid]::NewGuid().ToString()
    $request = @{ schemaVersion = 1; operationId = $operationId; operation = $Operation; arguments = $Arguments }
    [IO.File]::WriteAllText($requestPath, (ConvertTo-SafeJson $request), (New-Object Text.UTF8Encoding($false)))
    $helper = Join-Path $script:ModuleRoot 'Private/UacWorker.ps1'
    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-RequestPath', $requestPath, '-ResultPath', $resultPath, '-MarkerPath', $markerPath) -Verb RunAs -PassThru
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch { $null = $_ }; throw 'E_ELEVATION_TIMEOUT' }
        if (-not (Test-Path -LiteralPath $markerPath) -or -not (Test-Path -LiteralPath $resultPath)) { throw 'E_ELEVATION_CHANNEL' }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($result.operationId -ne $operationId) { throw 'E_ELEVATION_CHANNEL' }
        return $result
    } catch [System.ComponentModel.Win32Exception] {
        throw 'E_ELEVATION_DECLINED'
    } finally {
        # Flat staging: remove only the known files, then the empty directory (non-recursive).
        foreach ($known in @($requestPath, $resultPath, $markerPath, ($resultPath + '.tmp'))) {
            if (Test-Path -LiteralPath $known -PathType Leaf) { Remove-Item -LiteralPath $known -Force -ErrorAction SilentlyContinue }
        }
        try { [IO.Directory]::Delete($staging, $false) } catch { $null = $_ }
    }
}
