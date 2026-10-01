function Invoke-WinGetInstall {
    param([string]$PackageId, [string]$VendorLog, [int]$TimeoutSeconds = 900, [ValidateSet('winget', 'msstore')][string]$Source = 'winget')
    $arguments = @('install', '--id', $PackageId, '--exact', '--source', $Source, '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
    if ($VendorLog) { $arguments += @('--log', $VendorLog) }
    # winget writes UTF-8; decoding with the OEM code page garbles Korean error messages.
    $result = Invoke-SafeProcess -FilePath 'winget' -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -CloseInput -Utf8Output
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

function Invoke-InstallerHttpRequest {
    # One HTTPS request without automatic redirects; the body is read (up to 1 MiB + 1 byte) only for 2xx responses.
    param([Parameter(Mandatory=$true)][uri]$Uri, [int]$TimeoutSeconds = 60)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $false
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $response = $null
    try {
        try {
            $response = $request.GetResponse()
        } catch [Net.WebException] {
            if ($_.Exception.Response) { $response = $_.Exception.Response } else { throw ('E_NETWORK: ' + $_.Exception.Status) }
        }
        $statusCode = [int]$response.StatusCode
        $location = [string]$response.Headers['Location']
        $body = [byte[]]@()
        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            $limit = 1048577
            $memory = New-Object IO.MemoryStream
            $stream = $response.GetResponseStream()
            $buffer = New-Object byte[] 8192
            while ($memory.Length -lt $limit) {
                $wanted = [int][Math]::Min([long]$buffer.Length, ([long]$limit - $memory.Length))
                $read = $stream.Read($buffer, 0, $wanted)
                if ($read -le 0) { break }
                $memory.Write($buffer, 0, $read)
            }
            $body = $memory.ToArray()
        }
        return [pscustomobject]@{ StatusCode = $statusCode; Location = $location; Body = $body }
    } finally {
        if ($response) { $response.Close() }
    }
}

function Get-InstallerScriptContent {
    # Every hop (including the first) must be HTTPS on the default port, without userinfo, on an allowlisted host.
    param([Parameter(Mandatory=$true)][string]$Uri, [string[]]$AllowedHosts = @(), [int]$MaxHops = 3, [scriptblock]$Fetch)
    if (-not $Fetch) { $Fetch = { param($requestUri) Invoke-InstallerHttpRequest -Uri $requestUri } }
    try { $current = New-Object Uri($Uri) } catch { throw 'E_INTEGRITY: installer URI not allowed' }
    $hops = 0
    $response = $null
    while ($true) {
        if ($current.Scheme -ne 'https' -or -not $current.IsDefaultPort -or $current.UserInfo -or @($AllowedHosts) -notcontains $current.Host) { throw 'E_INTEGRITY: installer URI not allowed' }
        $response = & $Fetch $current
        $code = [int]$response.StatusCode
        if ($code -ge 200 -and $code -lt 300) { break }
        if (@(301, 302, 303, 307, 308) -contains $code) {
            if (-not $response.Location) { throw 'E_NETWORK: redirect without location' }
            try { $current = New-Object Uri($current, [string]$response.Location) } catch { throw 'E_NETWORK: invalid redirect location' }
            $hops++
            if ($hops -gt $MaxHops) { throw 'E_NETWORK: too many redirects' }
            continue
        }
        throw ('E_NETWORK: HTTP ' + $code)
    }
    $bytes = [byte[]]@($response.Body)
    if ($bytes.Length -eq 0) { throw 'E_INTEGRITY: installer script is empty' }
    if ($bytes.Length -gt 1048576) { throw 'E_INTEGRITY: installer script is larger than 1 MiB' }
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { throw 'E_INTEGRITY: installer script is not valid UTF-8' }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    if ($text.IndexOf([char]0) -ge 0) { throw 'E_INTEGRITY: installer script contains NUL characters' }
    $trimmed = $text.TrimStart()
    if ($trimmed.Length -eq 0 -or $trimmed[0] -eq '<') { throw 'E_INTEGRITY: installer response is not a script (HTML or blank)' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
    return [pscustomobject]@{ Text = $text; DownloadSha256 = $hash; FinalHost = $current.Host; Hops = $hops; DownloadBytes = $bytes.Length }
}

function Install-OfficialPowerShellScript {
    param([string]$Uri, [string[]]$AllowedHosts = @(), [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 900, [scriptblock]$Fetch, $Context = $null, [string]$ComponentId)
    if (@($AllowedHosts).Count -eq 0) { throw 'E_INTEGRITY: no installer host allowlist' }
    $fetchArguments = @{}
    if ($Fetch) { $fetchArguments.Fetch = $Fetch }
    $content = Get-InstallerScriptContent -Uri $Uri -AllowedHosts $AllowedHosts @fetchArguments
    $powershell = Get-TrustedWindowsPowerShellPath
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('llm-cli-installer-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        # BOM keeps non-ASCII script text intact under Windows PowerShell 5.1.
        $executedBytes = [byte[]]@((New-Object Text.UTF8Encoding($true)).GetPreamble()) + (New-Object Text.UTF8Encoding($false)).GetBytes($content.Text)
        [IO.File]::WriteAllBytes($temporary, [byte[]]$executedBytes)
        # The hash of what is really on disk (and will be run), read back after writing.
        $onDisk = [IO.File]::ReadAllBytes($temporary)
        $executedHasher = [Security.Cryptography.SHA256]::Create()
        try { $executedSha256 = ([BitConverter]::ToString($executedHasher.ComputeHash($onDisk)) -replace '-', '').ToLowerInvariant() } finally { $executedHasher.Dispose() }
        $executedLength = $onDisk.Length
        if ($null -ne $Context) {
            Write-RunEvent $Context 'install' 'script-fetched' $ComponentId '공식 설치 스크립트를 받아 실행합니다.' 0 @{ installerHost=$content.FinalHost; downloadBytes=$content.DownloadBytes; downloadSha256=$content.DownloadSha256; executedBytes=$executedLength; executedSha256=$executedSha256 }
        }
        $process = Invoke-SafeProcess -FilePath $powershell -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $temporary) -TimeoutSeconds $TimeoutSeconds -Environment $Environment -CloseInput
        Add-Member -InputObject $process -NotePropertyName InstallerDownloadSha256 -NotePropertyValue $content.DownloadSha256 -Force
        Add-Member -InputObject $process -NotePropertyName InstallerExecutedSha256 -NotePropertyValue $executedSha256 -Force
        Add-Member -InputObject $process -NotePropertyName InstallerFinalHost -NotePropertyValue $content.FinalHost -Force
        Add-Member -InputObject $process -NotePropertyName InstallerDownloadBytes -NotePropertyValue $content.DownloadBytes -Force
        Add-Member -InputObject $process -NotePropertyName InstallerExecutedBytes -NotePropertyValue $executedLength -Force
        return $process
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
    if ($value -match $script:CmdUnsafePattern) { return $null }
    if (-not ($value -match '^[A-Za-z]:[\\/]' -or [IO.Path]::IsPathRooted($value))) { return $null }
    return $value
}

function Get-NpmInstallArgumentList {
    # The official registry is forced for the global setting and for the package scope, because a scope registry outranks the global one.
    param([Parameter(Mandatory=$true)][string]$Package, [string]$Prefix)
    if ($Package -cnotmatch '^(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*$') { throw "E_INTERNAL_STATE: invalid npm package name: $Package" }
    $registry = 'https://registry.npmjs.org/'
    $arguments = @('install', '--global', ('--registry=' + $registry))
    $scope = [regex]::Match($Package, '^@([^/]+)/')
    if ($scope.Success) { $arguments += ('--@' + $scope.Groups[1].Value + ':registry=' + $registry) }
    if ($Prefix) { $arguments += @('--prefix', $Prefix) }
    $arguments += $Package
    return $arguments
}

function Get-TrustedWindowsPowerShellPath {
    # Windows PowerShell 5.1 is started by absolute path under SystemRoot, never by name from PATH.
    if ($env:SystemRoot) {
        $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'E_NO_TRUSTED_INSTALL_CHANNEL: Windows PowerShell 5.1 not found'
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
    if ($Prefix -match $script:CmdUnsafePattern) { throw 'E_INTERNAL_STATE: npm prefix contains unsafe characters' }
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
