function New-LlmCliSupportBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][guid]$RunId, [Parameter(Mandatory=$true)][string]$OutputPath, [string]$LogRoot)
    if (-not $LogRoot) {
        if ($env:LOCALAPPDATA) { $LogRoot = Join-Path $env:LOCALAPPDATA 'LLMCliInstaller/Logs' }
        else { $LogRoot = Join-Path ([IO.Path]::GetTempPath()) 'LLMCliInstaller/Logs' }
    }
    $runDirectory = Join-Path $LogRoot $RunId.ToString()
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) { throw 'E_INVALID_ARGUMENT: run log not found' }
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('llm-cli-bundle-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        # v2 adds only the sanitized journal copy and the preview/PATH-delta summaries (hash/delta, never full PATH).
        $allowedNames = @('run.log', 'events.jsonl', 'summary.json', 'redaction-report.json', 'migration-journal.sanitized.jsonl', 'migration-preview.json')
        foreach ($name in $allowedNames) {
            $source = Join-Path $runDirectory $name
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $content = Protect-SensitiveText -Text ([IO.File]::ReadAllText($source))
                [IO.File]::WriteAllText((Join-Path $staging $name), $content, (New-Object Text.UTF8Encoding($false)))
            }
        }
        foreach ($native in Get-ChildItem -LiteralPath $runDirectory -Filter 'native-*.sanitized.log' -File -ErrorAction SilentlyContinue) {
            $content = Protect-SensitiveText -Text ([IO.File]::ReadAllText($native.FullName))
            [IO.File]::WriteAllText((Join-Path $staging $native.Name), $content, (New-Object Text.UTF8Encoding($false)))
        }
        $manifest = New-Object System.Collections.ArrayList
        foreach ($file in Get-ChildItem -LiteralPath $staging -File) {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            [void]$manifest.Add([pscustomobject]@{ path=$file.Name; sha256=$hash; bytes=$file.Length })
        }
        [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), (ConvertTo-SafeJson $manifest), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal
        return $OutputPath
    } finally {
        # Flat staging directory: delete files individually, then the empty directory (non-recursive).
        foreach ($file in @(Get-ChildItem -LiteralPath $staging -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
        try { [IO.Directory]::Delete($staging, $false) } catch { $null = $_ }
    }
}
