# Test-only barrier: both real remote pushes use the same expected branch tip.
param([string]$ModulePath, [string]$TaskDirectory, [string]$TaskId, [string]$Barrier, [string]$Name)
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru
& $module {
    param($Barrier, $Name)
    $script:OriginalInvokeJj = ${function:Invoke-Jj}
    $script:Barrier = $Barrier
    $script:WorkerName = $Name
    function script:Invoke-Jj {
        param([string]$Directory, [string[]]$Arguments)
        if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'git' -and $Arguments[1] -eq 'push') {
            [IO.File]::WriteAllText((Join-Path $script:Barrier "$($script:WorkerName).ready"), '')
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path (Join-Path $script:Barrier 'go'))) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Claim barrier timed out.' }
                Start-Sleep -Milliseconds 25
            }
        }
        & $script:OriginalInvokeJj $Directory $Arguments
    }
} $Barrier $Name
try {
    $null = Receive-AgentHandoff -TaskDirectory $TaskDirectory -TaskId $TaskId
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.result"), 'claimed')
} catch {
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.result"), 'rejected')
    [IO.File]::WriteAllText((Join-Path $Barrier "$Name.error"), $_.Exception.Message)
}
