# Test-only barrier before the shared-store transaction, never while holding its lock.
param([string]$ModulePath, [string]$TaskDirectory, [string]$TaskId, [string]$Barrier, [string]$Name)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru
[IO.File]::WriteAllText((Join-Path $Barrier "$Name.ready"), '')
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path (Join-Path $Barrier 'go'))) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Claim barrier timed out.' }
    Start-Sleep -Milliseconds 25
}
try {
    $receipt = Receive-AgentHandoff -TaskDirectory $TaskDirectory -TaskId $TaskId
    if (-not $receipt.Plan) { throw 'Winner did not receive PLAN.' }
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.result"), 'claimed')
} catch {
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.result"), 'rejected')
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.error"), $_.Exception.Message)
}
