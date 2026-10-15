#requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDirectory = Join-Path $PSScriptRoot '../.log/repository-sync'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory ('{0}-{1}.jsonl' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
$module = Join-Path $PSScriptRoot 'AgentWorkflow.psm1'
Import-Module $module -Force

$problems = 0
try {
    $problems = Sync-AgentRepositoryMap -LogPath $logPath
}
catch {
    Write-AgentRepositorySyncEvent -LogPath $logPath -Event @{ type = 'fatal'; status = 'failed'; reason = $_.Exception.Message }
    $problems = 1
}

if ($problems -gt 0) {
    try {
        Import-Module (Join-Path $HOME 'local-repository-map/RepositoryMap.psm1') -ErrorAction Stop
        $notificationRepo = Get-LocalRepositoryPath 'expgolemclone/notifaction'
        $notificationScript = Join-Path $notificationRepo 'scripts\notify-repository-sync.ts'
        if (-not (Test-Path -LiteralPath $notificationScript -PathType Leaf)) {
            throw "Notification script does not exist: $notificationScript"
        }
        $nodePath = 'C:\Program Files\nodejs\node.exe'
        $entry = Join-Path $env:LOCALAPPDATA 'envx/runtimes/node/node_modules/@expgolemclone/envx-runtime/cli.mjs'
        foreach ($path in @($nodePath, $entry)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required Node runtime entrypoint not found: $path"
            }
        }
        $arguments = '"{0}" run --import tsx "{1}" "{2}"' -f $entry, $notificationScript, $logPath
        Write-AgentRepositorySyncEvent -LogPath $logPath -Event @{ type = 'notification-launching' }
        [void](Start-Process -FilePath $nodePath -ArgumentList $arguments -WorkingDirectory $notificationRepo -WindowStyle Hidden -PassThru)
    }
    catch {
        Write-AgentRepositorySyncEvent -LogPath $logPath -Event @{ type = 'notification-failed'; reason = $_.Exception.Message }
    }
}

if ($problems -gt 0) { exit 1 }
exit 0
