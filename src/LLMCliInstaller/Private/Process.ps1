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
        [switch]$CloseInput
    )
    $resolved = Resolve-ApplicationCommand -FilePath $FilePath
    if (-not $resolved) {
        return [pscustomobject]@{ ExitCode = 127; TimedOut = $false; StdOut = ''; StdErr = 'command not found'; ResolvedPath = $null; CommandSummary = (Join-CommandSummary $FilePath $ArgumentList) }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $resolved.Source
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = [bool]$CloseInput
    $info.CreateNoWindow = $true
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
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        # Only the process this product started is terminated; never an unrelated user process.
        try { $process.Kill() } catch { $null = $_ }
        return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; StdOut = Protect-SensitiveText $stdoutTask.Result; StdErr = 'timeout'; ResolvedPath = $resolved.Source; CommandSummary = (Join-CommandSummary $FilePath $ArgumentList) }
    }
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        StdOut = Protect-SensitiveText -Text $stdoutTask.Result
        StdErr = Protect-SensitiveText -Text $stderrTask.Result
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
