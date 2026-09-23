param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][string]$MarkerPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
if ($request.schemaVersion -ne 1 -or $request.operation -ne 'winget-install' -or -not $request.operationId) { exit 33 }
$arguments = @($request.arguments.arguments | ForEach-Object { [string]$_ })
$process = Start-Process -FilePath 'winget.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
$result = @{ schemaVersion = 1; operationId = $request.operationId; rawExitCode = $process.ExitCode }
$tempResult = $ResultPath + '.tmp'
[IO.File]::WriteAllText($tempResult, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tempResult -Destination $ResultPath -Force
[IO.File]::WriteAllText($MarkerPath, $request.operationId, (New-Object Text.UTF8Encoding($false)))
exit 0
