function Protect-SensitiveText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = [string]$Text
    # 1) Authorization schemes first, so the credential itself (not only the scheme word) is masked.
    $safe = [regex]::Replace($safe, '(?i)\b(Bearer|Basic)\s+(?!\[REDACTED)[A-Za-z0-9._~+/=-]+', '$1 [REDACTED:auth]')
    # 2) JWTs: three base64url segments starting with eyJ.
    $safe = [regex]::Replace($safe, '\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*', '[REDACTED:jwt]')
    # 3) Vendor key prefixes with hyphen or underscore separators (OpenAI/Anthropic sk-, xAI, GitHub PAT/OAuth).
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])(?:sk|xai|ghp|gho|ghu|ghs|ghr|github_pat)[-_][A-Za-z0-9_-]{20,}', '[REDACTED:token]')
    # 4) key=value, key: value and JSON "key": "value"; the key may carry a prefix such as VENDOR_API_KEY.
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9])([A-Za-z0-9_.-]*?(?:api[_-]?key|access[_-]?key|token|password|passwd|secret|cookie|authorization|credential)s?)(\\?"?\s*[:=]\s*\\?"?)(?!\[REDACTED)([^\s"'',;&\\]+)', '$1$2[REDACTED:key]')
    $safe = [regex]::Replace($safe, '(https?://)[^/@\s]+@', '$1[REDACTED:userinfo]@')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|key|password|secret)=)[^&#\s]+', '$1[REDACTED:url]')
    # 5) Windows profile paths on any drive, with \ or / or JSON-escaped \\ separators; names may contain spaces.
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z])[a-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/)[^\\/"\r\n]+', '%USERPROFILE%')
    if ($env:USERPROFILE) {
        $safe = $safe.Replace($env:USERPROFILE, '%USERPROFILE%')
        $safe = $safe.Replace($env:USERPROFILE.Replace('\', '\\'), '%USERPROFILE%')
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
