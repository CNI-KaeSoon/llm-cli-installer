function Invoke-WinGetInstall {
    param([string]$PackageId, [string]$VendorLog, [int]$TimeoutSeconds = 900)
    $arguments = @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
    if ($VendorLog) { $arguments += @('--log', $VendorLog) }
    $result = Invoke-SafeProcess -FilePath 'winget' -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -CloseInput
    $stableCode = 0
    if ($result.ExitCode -eq 127) { $stableCode = 22 }
    elseif ($result.TimedOut) { $stableCode = 20 }
    elseif ($result.ExitCode -eq 3010) { $stableCode = 42 }
    elseif ($result.ExitCode -ne 0) { $stableCode = 21 }
    $sanitizedLog = Convert-NativeLog -Path $VendorLog
    [pscustomobject]@{ Process = $result; StableCode = $stableCode; RestartRequired = ($result.ExitCode -eq 3010); SanitizedLog=$sanitizedLog }
}

function Convert-NativeLog {
    param([string]$Path, [int]$MaximumBytes = 10485760)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $target = $Path + '.sanitized.log'
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $truncated = ($bytes.Length -gt $MaximumBytes)
        if ($truncated) {
            $start = $bytes.Length - $MaximumBytes
            $slice = New-Object byte[] $MaximumBytes
            [Array]::Copy($bytes, $start, $slice, 0, $MaximumBytes)
            $bytes = $slice
        }
        $text = (New-Object Text.UTF8Encoding($false, $false)).GetString($bytes)
        $safe = Protect-SensitiveText -Text $text
        if ($truncated) { $safe = "[TRUNCATED_TO_10_MIB]`r`n" + $safe }
        [IO.File]::WriteAllText($target, $safe, (New-Object Text.UTF8Encoding($false)))
        return $target
    } finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Install-OfficialPowerShellScript {
    param([string]$Uri, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 900)
    $allowedHosts = @('chatgpt.com', 'claude.ai', 'antigravity.google')
    $parsed = [uri]$Uri
    if ($parsed.Scheme -ne 'https' -or $allowedHosts -notcontains $parsed.Host) { throw 'E_INTEGRITY_FAILURE: untrusted installer host' }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('llm-cli-installer-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $request = [Net.WebRequest]::Create($parsed)
        $request.AllowAutoRedirect = $false
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw 'E_NETWORK' }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        [IO.File]::WriteAllText($temporary, $reader.ReadToEnd(), (New-Object Text.UTF8Encoding($false)))
        $reader.Dispose()
        $response.Dispose()
        return Invoke-SafeProcess -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $temporary) -TimeoutSeconds $TimeoutSeconds -Environment $Environment -CloseInput
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

# ---- v2 read-only inventory and official remover wrappers (V2_MIGRATION_PLAN §2.4, §14.1) ----
# Only these two remover shapes exist in the product. There is no folder-delete remover.

$script:NpmRemovablePackages = @('@openai/codex', '@anthropic-ai/claude-code', '@xai-official/grok', '@google/gemini-cli')

function Get-NpmEffectivePrefix {
    $process = Invoke-SafeProcess -FilePath 'npm' -ArgumentList @('config', 'get', 'prefix') -TimeoutSeconds 60 -CloseInput
    if ($process.ExitCode -ne 0) { return $null }
    $value = ([string]$process.StdOut).Trim()
    if (-not $value) { return $null }
    return $value
}

function Get-NpmGlobalPackageInventory {
    # Returns only name->version scalars for allowlisted packages; never the full npm dump.
    param([Parameter(Mandatory=$true)][string]$Prefix)
    $process = Invoke-SafeProcess -FilePath 'npm' -ArgumentList @('ls', '--global', '--prefix', $Prefix, '--depth=0', '--json') -TimeoutSeconds 120 -CloseInput
    $inventory = @{}
    if ($process.ExitCode -ne 0 -and -not $process.StdOut) { return $inventory }
    try { $parsed = $process.StdOut | ConvertFrom-Json } catch { return $inventory }
    if (-not $parsed -or -not ($parsed.PSObject.Properties.Name -contains 'dependencies') -or -not $parsed.dependencies) { return $inventory }
    foreach ($property in $parsed.dependencies.PSObject.Properties) {
        if ($script:NpmRemovablePackages -notcontains $property.Name) { continue }
        $version = $null
        if ($property.Value -and ($property.Value.PSObject.Properties.Name -contains 'version')) { $version = [string]$property.Value.version }
        $inventory[$property.Name] = $version
    }
    return $inventory
}

function Get-NpmUninstallArgumentList {
    param([Parameter(Mandatory=$true)][string]$Prefix, [Parameter(Mandatory=$true)][string]$Package)
    if ($script:NpmRemovablePackages -notcontains $Package) { throw "E_INTERNAL_STATE: npm package not allowlisted for removal: $Package" }
    if (-not ($Prefix -match '^[A-Za-z]:[\\/]' -or [IO.Path]::IsPathRooted($Prefix))) { throw 'E_INTERNAL_STATE: npm evidence prefix must be absolute' }
    return @('uninstall', '-g', '--prefix', $Prefix, $Package)
}

function Invoke-NpmUninstall {
    param([Parameter(Mandatory=$true)][string]$Prefix, [Parameter(Mandatory=$true)][string]$Package, [int]$TimeoutSeconds = 600)
    $arguments = Get-NpmUninstallArgumentList -Prefix $Prefix -Package $Package
    $process = Invoke-SafeProcess -FilePath 'npm' -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -CloseInput
    $stableCode = 0
    if ($process.ExitCode -eq 127) { $stableCode = 22 }
    elseif ($process.TimedOut) { $stableCode = 20 }
    elseif ($process.ExitCode -ne 0) { $stableCode = 40 }
    [pscustomobject]@{ Process = $process; StableCode = $stableCode; RestartRequired = $false }
}

function Test-PyManagerExactTag {
    # Exact runtime tag only (e.g. 3.13, 3.13-64, 3.13t). Ranges, wildcards and flags are rejected.
    param([string]$Tag)
    return ([string]$Tag -match '^3\.[0-9]{1,2}(?:\.[0-9]{1,3})?(?:t)?(?:-(?:32|64|arm64))?$')
}

function Get-PyManagerUninstallArgumentList {
    param([Parameter(Mandatory=$true)][string]$Tag)
    if (-not (Test-PyManagerExactTag -Tag $Tag)) { throw "E_INTERNAL_STATE: pymanager tag is not an exact tag: $Tag" }
    return @('uninstall', '--yes', $Tag)
}

function Invoke-PyManagerUninstall {
    param([Parameter(Mandatory=$true)][string]$Tag, [int]$TimeoutSeconds = 600)
    $arguments = Get-PyManagerUninstallArgumentList -Tag $Tag
    $process = Invoke-SafeProcess -FilePath 'pymanager' -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -CloseInput
    $stableCode = 0
    if ($process.ExitCode -eq 127) { $stableCode = 22 }
    elseif ($process.TimedOut) { $stableCode = 20 }
    elseif ($process.ExitCode -ne 0) { $stableCode = 40 }
    [pscustomobject]@{ Process = $process; StableCode = $stableCode; RestartRequired = $false }
}

function Get-PyManagerManagedRuntime {
    # Parses allowlisted scalars (tag, executable) from `pymanager list --only-managed --format=json`.
    $process = Invoke-SafeProcess -FilePath 'pymanager' -ArgumentList @('list', '--only-managed', '--format=json') -TimeoutSeconds 60 -CloseInput
    if ($process.ExitCode -ne 0) { return @() }
    try { $parsed = $process.StdOut | ConvertFrom-Json } catch { return @() }
    $items = @()
    if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'versions')) { $items = @($parsed.versions) } else { $items = @($parsed) }
    $runtimes = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        if (-not $item) { continue }
        $names = @($item.PSObject.Properties.Name)
        $tag = $(if ($names -contains 'tag') { [string]$item.tag } elseif ($names -contains 'id') { [string]$item.id } else { $null })
        $executable = $(if ($names -contains 'executable') { [string]$item.executable } else { $null })
        $version = $(if ($names -contains 'sort-version') { [string]$item.'sort-version' } elseif ($names -contains 'version') { [string]$item.version } else { $null })
        if ($tag -and $executable) { [void]$runtimes.Add([pscustomobject]@{ Tag = $tag; Executable = $executable; Version = $version }) }
    }
    return @($runtimes)
}
