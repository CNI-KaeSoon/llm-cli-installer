[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string[]]$Components,
    [switch]$AllowLegacyGemini,
    [switch]$AllowUpgrade,
    [switch]$NonInteractive,
    [string]$LogRoot,
    [switch]$NoSupportBundle,
    [string]$ExistingInstallPolicy = 'Keep',
    [switch]$ConfirmMigration,
    [string[]]$MigrationComponents
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src/LLMCliInstaller/LLMCliInstaller.psd1'
# Package root is the folder holding installer-win.bat; this script and the rest of the app live in its files subfolder.
$packageRoot = Split-Path $PSScriptRoot -Parent

try {
    # Integrity gate: verifies manifest.sha256 before any module code is imported or run (also under -WhatIf).
    $integrityFailure = $null
    $manifestFile = Join-Path $PSScriptRoot 'manifest.sha256'
    $manifestEntries = @{}
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
        $integrityFailure = 'manifest.sha256 없음'
    } else {
        foreach ($manifestLine in [IO.File]::ReadAllLines($manifestFile)) {
            if ($manifestLine -notmatch '^([0-9a-f]{64})  (.+)$') { $integrityFailure = 'manifest.sha256 형식 오류'; break }
            $entryHash = $Matches[1]
            $entryPath = $Matches[2]
            if ($entryPath.Contains(':') -or $entryPath.StartsWith('/') -or $entryPath.StartsWith('\') -or [IO.Path]::IsPathRooted($entryPath) -or ([regex]::Split($entryPath, '[\\/]') -contains '..')) { $integrityFailure = ('허용되지 않는 경로 ' + $entryPath); break }
            if ($manifestEntries.ContainsKey($entryPath)) { $integrityFailure = ('중복 항목 ' + $entryPath); break }
            $manifestEntries[$entryPath] = $entryHash
        }
    }
    if (-not $integrityFailure) {
        foreach ($entryPath in @($manifestEntries.Keys | Sort-Object)) {
            $entryFile = Join-Path $packageRoot $entryPath
            if (-not (Test-Path -LiteralPath $entryFile -PathType Leaf)) { $integrityFailure = ('파일 없음 ' + $entryPath); break }
            if ((Get-FileHash -LiteralPath $entryFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifestEntries[$entryPath]) { $integrityFailure = ('해시 불일치 ' + $entryPath); break }
        }
    }
    if (-not $integrityFailure) {
        $rootFull = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\', '/')
        foreach ($candidate in Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force) {
            $relative = $candidate.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
            if ($relative.StartsWith('.git/')) { continue }
            if (@('.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.exe', '.com', '.msi', '.dll', '.vbs', '.js', '.wsf', '.lnk') -notcontains $candidate.Extension.ToLowerInvariant()) { continue }
            if (-not $manifestEntries.ContainsKey($relative)) { $integrityFailure = ('manifest에 없는 실행 파일 ' + $relative); break }
        }
    }
    if ($integrityFailure) {
        [Console]::Error.WriteLine(('설치기 무결성 검증 실패: {0}. 공식 릴리스 ZIP을 다시 내려받고 SHA256을 확인하세요.' -f $integrityFailure))
        exit 23
    }
    $module = Import-Module $modulePath -Force -ErrorAction Stop -PassThru
    $arguments = @{
        Components = $Components
        AllowLegacyGemini = $AllowLegacyGemini
        AllowUpgrade = $AllowUpgrade
        NonInteractive = $NonInteractive
        NoSupportBundle = $NoSupportBundle
        ExistingInstallPolicy = $ExistingInstallPolicy
        ConfirmMigration = $ConfirmMigration
    }
    if ($MigrationComponents) { $arguments.MigrationComponents = $MigrationComponents }
    if ($LogRoot) { $arguments.LogRoot = $LogRoot }
    if ($WhatIfPreference) { $arguments.WhatIf = $true }
    $result = Invoke-LlmCliInstaller @arguments
    # Plain-language result for the console; the full masked JSON stays in summary.json in the log folder.
    try { & $module { param($value) Write-ConsoleSummary -Summary $value } $result } catch { [Console]::Error.WriteLine('결과 요약을 표시하지 못했습니다. 설치 결과는 로그 폴더의 summary.json을 확인하세요.') }
    exit ([int]$result.ExitCode)
} catch {
    $message = $_.Exception.Message
    if ($message -match 'E_USER_CANCELLED') {
        [Console]::Error.WriteLine('설치를 취소했습니다. 변경된 것은 없습니다.')
        exit 70
    }
    [Console]::Error.WriteLine("설치기를 시작하지 못했습니다: {0}" -f $message)
    if ($message -match 'E_INVALID_ARGUMENT') { exit 2 }
    if ($message -match 'E_LOG_UNAVAILABLE') { exit 12 }
    exit 90
}
