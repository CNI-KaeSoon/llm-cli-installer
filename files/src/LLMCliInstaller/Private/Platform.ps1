function Get-PlatformDiagnostic {
    $platformIsWindows = ($env:OS -eq 'Windows_NT')
    $architecture = if ($env:PROCESSOR_ARCHITECTURE) { [string]$env:PROCESSOR_ARCHITECTURE } else { [string][IntPtr]::Size }
    $build = 0
    if ($platformIsWindows) { $build = [Environment]::OSVersion.Version.Build }
    [pscustomobject]@{
        IsWindows = $platformIsWindows
        Architecture = $architecture
        IsSupported = ($platformIsWindows -and $architecture -eq 'AMD64' -and $build -ge 22000)
        Build = $build
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        IsAdministrator = $(if ($platformIsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } else { $false })
    }
}

function Test-CommandAvailable {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1))
}
