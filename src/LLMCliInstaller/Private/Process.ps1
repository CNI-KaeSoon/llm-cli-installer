# Characters that cmd.exe would interpret when a .cmd/.bat shim is started: control characters and " % ! ^ & | < >.
$script:CmdUnsafePattern = '[\x00-\x1F"%!^&|<>]'

function Get-OutputTail {
    # Keeps only the last MaxLength characters of process output so one failure cannot flood logs and summaries.
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxLength = 4000)
    $value = [string]$Text
    if ($value.Length -le $MaxLength) { return $value }
    return ('[TRUNCATED] ' + $value.Substring($value.Length - $MaxLength))
}

function Join-CommandSummary {
    # -NoMask builds the runnable form for console display only; logs, journal and summary keep the masked form.
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoMask)
    $parts = @($FilePath) + @($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } })
    if ($NoMask) { return ($parts -join ' ') }
    Protect-SensitiveText -Text ($parts -join ' ')
}

function Resolve-ApplicationCommand {
    # Applications only (never an npm.ps1 ExternalScript); .exe/.cmd shims win over other extensions.
    param([Parameter(Mandatory=$true)][string]$FilePath)
    $found = @(Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue)
    $preferred = @($found | Where-Object { [IO.Path]::GetExtension([string]$_.Source) -match '^(?i)\.(exe|cmd)$' })
    if ($preferred.Count -gt 0) { return $preferred[0] }
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function Invoke-SafeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300,
        [hashtable]$Environment = @{},
        [switch]$CloseInput,
        [switch]$Utf8Output
    )
    $resolved = Resolve-ApplicationCommand -FilePath $FilePath
    if (-not $resolved) {
        return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = 'command not found'; ResolvedPath = $null; CommandSummary = (Join-CommandSummary $FilePath $ArgumentList) }
    }
    if ([IO.Path]::GetExtension([string]$resolved.Source) -match '^(?i)\.(cmd|bat)$') {
        $unsafeArguments = @($ArgumentList | Where-Object { [string]$_ -match $script:CmdUnsafePattern })
        if ($unsafeArguments.Count -gt 0) {
            return [pscustomobject]@{ ExitCode = 126; TimedOut = $false; StdOut = ''; StdErr = 'E_UNSAFE_ARGUMENT: cmd shim argument contains a metacharacter'; ResolvedPath = $resolved.Source; CommandSummary = (Join-CommandSummary $FilePath $ArgumentList) }
        }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $resolved.Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = [bool]$CloseInput
    $info.CreateNoWindow = $true
    if ($Utf8Output) {
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    }
    foreach ($argument in $ArgumentList) {
        $escaped = [string]$argument -replace '(\\*)"', '$1$1\"'
        if ($escaped -match '[\s"]') { $escaped = '"' + ($escaped -replace '(\\+)$', '$1$1') + '"' }
        $info.Arguments += $(if ($info.Arguments) { ' ' } else { '' }) + $escaped
    }
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    if ($CloseInput) { $process.StandardInput.Close() }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    # Poll once per second so a long download shows elapsed time instead of a silent console.
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $exited = $false
    while (-not $exited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $exited = $process.WaitForExit(1000)
        if (-not $exited -and $stopwatch.Elapsed.TotalSeconds -ge 3) {
            Write-Progress -Id 2 -Activity '작업 진행 중 (창을 닫지 마세요)' -Status ('경과 {0}분 {1}초' -f [int][Math]::Floor($stopwatch.Elapsed.TotalMinutes), $stopwatch.Elapsed.Seconds)
        }
    }
    Write-Progress -Id 2 -Activity '작업 진행 중 (창을 닫지 마세요)' -Completed
    if (-not $exited) {
        # Only the process this product started is terminated; never an unrelated user process.
        try { $process.Kill() } catch { $null = $_ }
        # A grandchild may still hold the pipe open, so stdout is awaited for a bounded time only and stderr is not awaited.
        try { [void]$stdoutTask.Wait(5000) } catch { $null = $_ }
        $timedOutStdOut = $(if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted) { Protect-SensitiveText $stdoutTask.Result } else { '' })
        return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; StdOut = $timedOutStdOut; StdErr = 'timeout'; ResolvedPath = $resolved.Source; CommandSummary = (Join-CommandSummary $FilePath $ArgumentList) }
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 10000) } catch { $null = $_ }
    $incomplete = '[OUTPUT_INCOMPLETE: child process still holds the pipe]'
    $normalStdOut = $(if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted) { Protect-SensitiveText -Text $stdoutTask.Result } else { $incomplete })
    $normalStdErr = $(if ($stderrTask.IsCompleted -and -not $stderrTask.IsFaulted) { Protect-SensitiveText -Text $stderrTask.Result } else { $incomplete })
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        StdOut = $normalStdOut
        StdErr = $normalStdErr
        ResolvedPath = $resolved.Source
        CommandSummary = (Join-CommandSummary $FilePath $ArgumentList)
    }
}

# ---- v2 read-only file probes (V2_MIGRATION_PLAN §2.3) ----

function Get-FileIdentity {
    # Read-only identity: normalized full path + size + creation/write ticks. Contents are never read.
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return $null }
        return ('{0}|{1}|{2}|{3}' -f $item.FullName.ToLowerInvariant(), $item.Length, $item.CreationTimeUtc.Ticks, $item.LastWriteTimeUtc.Ticks)
    } catch { return $null }
}

function Test-ReparsePath {
    # True when the file or any ancestor directory is a symlink/junction/reparse point.
    param([string]$Path)
    $current = $Path
    while ($current) {
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        } catch { return $false }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Test-FileLocked {
    # Opens for read with FileShare.None and closes immediately; never writes or terminates processes.
    param([string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        return $false
    } catch [IO.IOException] {
        return $true
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}
