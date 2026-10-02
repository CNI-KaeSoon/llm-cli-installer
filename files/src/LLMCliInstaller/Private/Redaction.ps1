function Protect-SensitiveText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = [string]$Text
    # 0) PEM private key blocks (complete first, then a truncated block without END), before anything else can split them.
    $safe = [regex]::Replace($safe, '(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----', '[REDACTED:pem]')
    $safe = [regex]::Replace($safe, '(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*$', '[REDACTED:pem]')
    # 1) Authorization schemes first, so the credential itself (not only the scheme word) is masked.
    $safe = [regex]::Replace($safe, '(?i)\b(Bearer|Basic)\s+(?!\[REDACTED)[A-Za-z0-9._~+/=-]+', '$1 [REDACTED:auth]')
    # 2) JWTs: three base64url segments starting with eyJ.
    $safe = [regex]::Replace($safe, '\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*', '[REDACTED:jwt]')
    # 3) Vendor key prefixes with hyphen or underscore separators (OpenAI/Anthropic sk-, xAI, GitHub PAT/OAuth), Google API keys and npm tokens.
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])(?:sk|xai|ghp|gho|ghu|ghs|ghr|github_pat)[-_][A-Za-z0-9_-]{20,}', '[REDACTED:token]')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])', '[REDACTED:token]')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])', '[REDACTED:token]')
    # 4) key=value, key: value and JSON "key": "value"; the key may carry a prefix such as VENDOR_API_KEY.
    $keyNames = '(?:api[_-]?key|access[_-]?key|token|password|passwd|secret|cookie|authorization|credential|auth)s?'
    # 4a) quoted values (single or double, optionally JSON-escaped): everything up to the closing quote, spaces included.
    $safe = [regex]::Replace($safe, ('(?i)(?<![A-Za-z0-9])([A-Za-z0-9_.-]*?' + $keyNames + ')(\\?["'']?\s*[:=]\s*)(\\?)(["''])(?!\[REDACTED)(.*?)\3\4'), '$1$2$3$4[REDACTED:key]$3$4')
    # 4b) unquoted values.
    $safe = [regex]::Replace($safe, ('(?i)(?<![A-Za-z0-9])([A-Za-z0-9_.-]*?' + $keyNames + ')(\\?["'']?\s*[:=]\s*\\?"?)(?!\[REDACTED)([^\s"'',;&\\]+)'), '$1$2[REDACTED:key]')
    # 4c) space-separated command-line flag values such as --api-key <value>.
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9-])(--?(?:api[_-]?key|access[_-]?key|token|auth[_-]?token|password|secret))(\s+)(?!\[REDACTED)(?!-)([^\s"'']+)', '$1$2[REDACTED:key]')
    # 5) URL userinfo and query secrets.
    $safe = [regex]::Replace($safe, '(https?://)[^/@\s]+@', '$1[REDACTED:userinfo]@')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|key|password|secret)=)[^&#\s]+', '$1[REDACTED:url]')
    # 6) Windows profile paths on any drive, with \ or / or JSON-escaped \\ separators; names may contain spaces.
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z])[a-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/)[^\\/"''\r\n;|<>]+', '%USERPROFILE%')
    # 7) Exact profile path from the environment.
    if ($env:USERPROFILE) {
        $safe = $safe.Replace($env:USERPROFILE, '%USERPROFILE%')
        $safe = $safe.Replace($env:USERPROFILE.Replace('\', '\\'), '%USERPROFILE%')
    }
    # 8) The account name itself, as a whole word.
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) {
        $safe = [regex]::Replace($safe, ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:USERNAME) + '(?![A-Za-z0-9])'), '<USER>')
    }
    return $safe
}

function ConvertTo-MaskedValue {
    # Masks every string inside nested dictionaries, arrays and PSCustomObjects before JSON escaping doubles backslashes.
    param($Value, [int]$Depth = 8)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Protect-SensitiveText -Text $Value) }
    if ($Value -is [ValueType]) { return $Value }
    if ($Depth -le 0) { return (Protect-SensitiveText -Text ([string]$Value)) }
    if ($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) { $copy[[string]$key] = ConvertTo-MaskedValue -Value $Value[$key] -Depth ($Depth - 1) }
        return $copy
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-MaskedValue -Value $item -Depth ($Depth - 1))) }
        return ,($items.ToArray())
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[$property.Name] = ConvertTo-MaskedValue -Value $property.Value -Depth ($Depth - 1) }
        return $copy
    }
    return $Value
}

function ConvertTo-SafeJson {
    param($Value, [int]$Depth = 8)
    $masked = ConvertTo-MaskedValue -Value $Value -Depth $Depth
    Protect-SensitiveText -Text (ConvertTo-Json -InputObject $masked -Compress -Depth $Depth)
}
