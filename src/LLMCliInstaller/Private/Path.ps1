function Merge-PathValues {
    param([string[]]$Values)
    $separator = [IO.Path]::PathSeparator
    $seen = @{}
    $output = New-Object System.Collections.ArrayList
    foreach ($value in $Values) {
        foreach ($entry in @(([string]$value).Split($separator))) {
            $clean = $entry.Trim().Trim('"').TrimEnd('\', '/')
            if (-not $clean) { continue }
            $key = $clean.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$output.Add($clean)
            }
        }
    }
    return ($output -join $separator)
}

function Update-ProcessPath {
    if ($env:OS -ne 'Windows_NT') { return $env:PATH }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = Merge-PathValues -Values @($machine, $user, $env:PATH)
    return $env:PATH
}

function Get-NpmExecutableDirectory {
    param([string]$Prefix)
    if (-not $Prefix) { return $null }
    if ($env:OS -eq 'Windows_NT') { return $Prefix.Trim() }
    return (Join-Path $Prefix 'bin')
}

# ---- v2 migration PATH snapshot / owned delta / CAS rollback (V2_MIGRATION_PLAN §5, §14.5) ----
# Only the User PATH is read or written. Machine PATH is never modified by migration.

function Get-UserPathValue {
    if ($env:OS -ne 'Windows_NT') { return $null }
    return [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPathValue {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([AllowEmptyString()][string]$Value)
    if ($env:OS -ne 'Windows_NT') { throw 'E_INTERNAL_STATE: User PATH write is Windows-only' }
    if ($PSCmdlet.ShouldProcess('User PATH', 'Restore snapshot')) {
        [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
    }
}

function Get-PathEntryList {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $separator = [IO.Path]::PathSeparator
    return @(([string]$Value).Split($separator) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-PathValueHash {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return (Get-TextSha256 -Text ((Get-PathEntryList -Value $Value) -join "`n"))
}

function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $normalizedPath = $Path.Trim().Trim('"').Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $normalizedRoot = $Root.Trim().Trim('"').Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    if (-not $normalizedRoot) { return $false }
    return ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith($normalizedRoot + '\'))
}

function New-UserPathSnapshot {
    param([Parameter(Mandatory=$true)][string]$TransactionId, [string]$StateRoot)
    $value = Get-UserPathValue
    $stagingPath = $null
    if ($StateRoot) {
        # Exact PATH text is kept only in the user-private recovery staging; logs and journal get the hash.
        $staging = Join-Path $StateRoot 'recovery'
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        $stagingPath = Join-Path $staging ('path-{0}.snapshot' -f $TransactionId)
        [IO.File]::WriteAllText($stagingPath, [string]$value, (New-Object Text.UTF8Encoding($false)))
    }
    [pscustomobject]@{ Value = $value; Hash = (Get-PathValueHash -Value $value); StagingPath = $stagingPath; EntryCount = @(Get-PathEntryList -Value $value).Count }
}

function Get-OwnedPathDelta {
    # Owned = appeared after the snapshot AND lies under the component canonical install root.
    param([AllowNull()][AllowEmptyString()][string]$SnapshotValue, [AllowNull()][AllowEmptyString()][string]$CurrentValue, [string[]]$CanonicalRoots)
    $before = @{}
    foreach ($entry in (Get-PathEntryList -Value $SnapshotValue)) { $before[$entry.ToLowerInvariant()] = $true }
    $owned = New-Object System.Collections.ArrayList
    foreach ($entry in (Get-PathEntryList -Value $CurrentValue)) {
        if ($before.ContainsKey($entry.ToLowerInvariant())) { continue }
        foreach ($root in @($CanonicalRoots)) {
            if (Test-PathUnderRoot -Path $entry -Root $root) { [void]$owned.Add($entry); break }
        }
    }
    return @($owned)
}

function Restore-UserPathSnapshot {
    # CAS-style: restore only when (current - owned delta) hashes equal to the snapshot; otherwise write nothing (67).
    param([Parameter(Mandatory=$true)]$Snapshot, [string[]]$CanonicalRoots)
    $current = Get-UserPathValue
    $owned = @(Get-OwnedPathDelta -SnapshotValue $Snapshot.Value -CurrentValue $current -CanonicalRoots $CanonicalRoots)
    $ownedKeys = @{}
    foreach ($entry in $owned) { $ownedKeys[$entry.ToLowerInvariant()] = $true }
    $remaining = @(Get-PathEntryList -Value $current | Where-Object { -not $ownedKeys.ContainsKey($_.ToLowerInvariant()) })
    $remainingHash = Get-TextSha256 -Text ($remaining -join "`n")
    if ($remainingHash -ne $Snapshot.Hash) {
        return [pscustomobject]@{ Result = 'Conflict'; Code = 67; OwnedDeltaCount = $owned.Count; WriteCount = 0 }
    }
    if ($owned.Count -eq 0) {
        return [pscustomobject]@{ Result = 'NoChange'; Code = 0; OwnedDeltaCount = 0; WriteCount = 0 }
    }
    try {
        Set-UserPathValue -Value $Snapshot.Value -Confirm:$false
    } catch {
        return [pscustomobject]@{ Result = 'RollbackFailed'; Code = 68; OwnedDeltaCount = $owned.Count; WriteCount = 0 }
    }
    return [pscustomobject]@{ Result = 'RollbackSucceeded'; Code = 0; OwnedDeltaCount = $owned.Count; WriteCount = 1 }
}
