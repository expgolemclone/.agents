#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../AgentWorkflow.psm1'))
$module = Import-Module $modulePath -Force -PassThru
$root = "C:/dev/tmp/agents-workflow-tests-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $root
$script:Tasks = [Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message (fixtures: $root)" }
    $script:Checks++
}
function Expect-Error {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected failure: $Pattern"
}
function Jj {
    param([string]$Directory, [string[]]$Arguments)
    & $module { param($d, $a) Invoke-Jj $d $a } $Directory $Arguments
}
function Tip {
    param([string]$Directory, [string]$Branch = 'main')
    & $module { param($d, $b) Get-RemoteTip $d $b } $Directory $Branch
}
function New-Fixture {
    param([string]$Name)
    $path = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path $path
    $seed = Join-Path $path 'seed'
    $null = Jj $path @('git', 'init', '--no-colocate', $seed)
    [IO.File]::WriteAllText((Join-Path $seed 'base.txt'), "base`n")
    $null = Jj $seed @('describe', '-m', 'test: seed')
    $null = Jj $seed @('bookmark', 'set', 'main')
    $null = Jj $seed @('git', 'export')
    $remote = Join-Path $seed '.jj/repo/store/git'
    $registered = Join-Path $path 'registered'
    $null = Jj $path @('git', 'clone', '--branch', 'main', $remote, $registered)
    $null = Jj $registered @('bookmark', 'track', 'main@origin')
    [pscustomobject]@{ repository = 'expgolemclone/workflow-test'; remote = $remote; path = $registered }
}
function Task {
    param($Fixture, [string]$Name, [switch]$Plan)
    $task = & $module { param($e, $n, $execute) New-Task $e $n -Execute:$execute } $Fixture $Name (-not $Plan)
    $script:Tasks.Add($task.TaskDirectory)
    return $task
}
function Clean-TestDirectory {
    param([string]$Path)
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Test cleanup refuses links.' }
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
    Remove-Item -LiteralPath $Path -Recurse
}

# Default planning phase blocks every remote mutation, while research clones work.
$f = New-Fixture 'normal'
$p = Task $f 'planning' -Plan
Assert ($p.Phase -eq 'plan') 'Default phase is plan'
Expect-Error { Publish-AgentHandoff $p.TaskDirectory } 'plan phase'
Expect-Error { Receive-AgentHandoff $p.TaskDirectory 'nothing' } 'plan phase'
Expect-Error { Complete-AgentTask $p.TaskDirectory 'fix: test' {} } 'plan phase'
Expect-Error { Remove-AgentTask $p.TaskDirectory } 'completed'
Expect-Error { Enable-AgentTaskExecution $p.TaskDirectory -Doit:$false } 'authorization'
$null = Enable-AgentTaskExecution $p.TaskDirectory -Doit
Assert ((Get-Content -LiteralPath (Join-Path $p.TaskDirectory 'task.json') -Raw | ConvertFrom-Json).phase -eq 'execute') 'Explicit authorization changes phase'
Expect-Error { & $module { Assert-PushAllowed 'https://github.com/other/repo' } } 'allowed only'

# Two tasks from one base integrate independently; registration stays unchanged until push.
$a = Task $f 'alpha'
$b = Task $f 'beta'
$initial = Tip $a.Repository
[IO.File]::WriteAllText((Join-Path $a.Repository 'alpha.txt'), 'alpha')
[IO.File]::WriteAllText((Join-Path $a.TaskDirectory 'PLAN.md'), '- [ ] alpha')
[IO.File]::WriteAllText((Join-Path $b.Repository 'beta.txt'), 'beta')
Assert (-not (Test-Path (Join-Path $f.path 'alpha.txt'))) 'Registered checkout untouched during development'
$null = Complete-AgentTask $a.TaskDirectory 'feat: alpha' {
    if (-not (Test-Path 'alpha.txt')) { throw 'Wrong test cwd' }
}
$null = Complete-AgentTask $b.TaskDirectory 'feat: beta' {
    if (-not (Test-Path 'alpha.txt') -or -not (Test-Path 'beta.txt')) { throw 'Rebased test tree incomplete' }
}
Assert ((Test-Path (Join-Path $f.path 'alpha.txt')) -and (Test-Path (Join-Path $f.path 'beta.txt'))) 'Main preserves both tasks'
Assert (-not (Test-Path (Join-Path $f.path 'PLAN.md'))) 'Normal PLAN never reaches main'
Assert (-not (Test-Path (Join-Path $f.path '.handoff'))) 'No handoff metadata on main'
$tipBeforeRetry = Tip $b.Repository
$null = Complete-AgentTask $b.TaskDirectory 'feat: beta' { throw 'Must not rerun after push' }
Assert ((Tip $b.Repository) -eq $tipBeforeRetry) 'Completion retry does not republish code'
$null = Remove-AgentTask $a.TaskDirectory
Assert (-not (Test-Path $a.TaskDirectory)) 'Read-only clone objects cleaned without force'

# A task with no remaining code delta completes without an empty main commit.
$empty = Task $f 'no-delta'
$emptyMain = Tip $empty.Repository
$quietResult = Complete-AgentTask $empty.TaskDirectory 'chore: no delta' { Write-Host 'PRIVATE-TEST-DETAIL' }
Assert ((Tip $empty.Repository) -eq $emptyMain) 'No-op completion does not create main context'
Assert (($quietResult | Out-String) -notmatch 'PRIVATE-TEST-DETAIL') 'Detailed test output stays out of agent context'
Assert ([IO.File]::ReadAllText((Join-Path $empty.TaskDirectory 'test.log')) -match 'PRIVATE-TEST-DETAIL') 'Detailed test output is retained in log'

# A real remote advance during testing causes a forward-push retry and a fresh test.
$raceA = Task $f 'main-race-one'
$raceB = Task $f 'main-race-two'
[IO.File]::WriteAllText((Join-Path $raceA.Repository 'race-a.txt'), 'a')
[IO.File]::WriteAllText((Join-Path $raceB.Repository 'race-b.txt'), 'b')
$gate = [pscustomobject]@{ Fired = $false; Tests = 0 }
$raceTest = {
    $gate.Tests++
    if (-not $gate.Fired) {
        $gate.Fired = $true
        $null = Complete-AgentTask $raceB.TaskDirectory 'feat: race b' {}
    } elseif (-not (Test-Path 'race-b.txt')) { throw 'Retry did not include competing main update' }
}.GetNewClosure()
$null = Complete-AgentTask $raceA.TaskDirectory 'feat: race a' $raceTest
Assert ($gate.Tests -eq 2) 'Main update race re-runs integration tests'
Assert ((Test-Path (Join-Path $f.path 'race-a.txt')) -and (Test-Path (Join-Path $f.path 'race-b.txt'))) 'Racing main updates preserve both tasks'

# Dirty checkout preserves user files and records main success separately from sync.
$d = Task $f 'dirty-checkout'
[IO.File]::WriteAllText((Join-Path $d.Repository 'done.txt'), 'done')
[IO.File]::WriteAllText((Join-Path $f.path 'base.txt'), 'user edit')
Expect-Error { Complete-AgentTask $d.TaskDirectory 'feat: done' {} } 'has changes'
$state = Get-Content -LiteralPath (Join-Path $d.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
Assert ([bool]$state.published -and -not $state.synchronized) 'Main push survives failed synchronization'
Assert ([IO.File]::ReadAllText((Join-Path $f.path 'base.txt')) -eq 'user edit') 'Dirty user files preserved'
Expect-Error { Remove-AgentTask $d.TaskDirectory } 'completed'
$null = Jj $f.path @('restore', 'base.txt')
$null = Sync-AgentRepository $d.TaskDirectory
Assert (Test-Path (Join-Path $f.path 'done.txt')) 'Sync retry picks latest remote'

# Test failures never push code and retain sources; subsequent corrections are honored.
$e = Task $f 'test-failure'
[IO.File]::WriteAllText((Join-Path $e.Repository 'test.txt'), 'before')
$before = Tip $e.Repository
Expect-Error { Complete-AgentTask $e.TaskDirectory 'fix: test' { throw 'deliberate failure' } } 'Test failed'
Assert ((Tip $e.Repository) -eq $before) 'Failed test does not push'
Assert ([IO.File]::ReadAllText((Join-Path $e.TaskDirectory 'test.log')) -match 'deliberate failure') 'Failure log retained'
Expect-Error { Complete-AgentTask $e.TaskDirectory 'fix: test' { Write-Error 'nonterminating error' -ErrorAction Continue } } 'Test failed'
Assert ([IO.File]::ReadAllText((Join-Path $e.TaskDirectory 'test.log')) -match 'nonterminating error') 'Nonterminating test errors cannot pass'
Expect-Error { Complete-AgentTask $e.TaskDirectory 'fix: test' { pwsh -NoProfile -Command 'exit 7' } } 'Test failed'
Assert ([IO.File]::ReadAllText((Join-Path $e.TaskDirectory 'test.log')) -match 'code 7') 'Native nonzero exit detected'
Expect-Error { Complete-AgentTask $e.TaskDirectory 'fix: test' { [IO.File]::WriteAllText((Join-Path $PWD 'test.txt'), 'test mutation') } } 'changed tracked files'
[IO.File]::WriteAllText((Join-Path $e.Repository 'test.txt'), 'corrected')
$null = Complete-AgentTask $e.TaskDirectory 'fix: test' {
    if ([IO.File]::ReadAllText((Join-Path $PWD 'test.txt')) -ne 'corrected') { throw 'Stale candidate' }
}
Assert ([IO.File]::ReadAllText((Join-Path $f.path 'test.txt')) -eq 'corrected') 'Retry uses rewritten candidate change'

# Unpublished local ancestors also stop synchronization, even with an empty working copy.
$u = Task $f 'unpublished-checkout'
[IO.File]::WriteAllText((Join-Path $u.Repository 'remote.txt'), 'remote')
[IO.File]::WriteAllText((Join-Path $f.path 'private.txt'), 'private')
$null = Jj $f.path @('describe', '-m', 'wip: private')
$null = Jj $f.path @('new', '@')
Expect-Error { Complete-AgentTask $u.TaskDirectory 'feat: remote' {} } 'unpublished work'
Assert (Test-Path (Join-Path $f.path 'private.txt')) 'Unpublished ancestors preserved'

# Explicit handoff publishes PLAN/code only to its branch. Occupied bodies stay out of output.
$hf = New-Fixture 'handoff'
$source = Task $hf 'unfinished'
[IO.File]::WriteAllText((Join-Path $source.Repository 'unfinished.txt'), 'unfinished')
[IO.File]::WriteAllText((Join-Path $source.TaskDirectory 'PLAN.md'), "# SECRET-PLAN-BODY`n- [ ] finish")
$null = Publish-AgentHandoff $source.TaskDirectory
Assert (-not (Test-Path (Join-Path $source.TaskDirectory 'PLAN.md'))) 'PLAN moved, not duplicated'
$observer = Task $hf 'observer' -Plan
$list = @(Get-AgentHandoff $observer.TaskDirectory)
Assert ($list.Count -eq 1 -and $list[0].TaskId -eq $source.TaskId) 'Available ID discovered'
Assert (($list | ConvertTo-Json) -notmatch 'SECRET-PLAN-BODY') 'Discovery exposes no PLAN body'
$c = Task $hf 'claim'
$receipt = Receive-AgentHandoff $c.TaskDirectory $source.TaskId
Assert ($receipt.Plan -match 'SECRET-PLAN-BODY') 'Body returned only after ownership acquired'
Assert (@(Get-AgentHandoff $observer.TaskDirectory).Count -eq 0) 'Occupied task omitted entirely'
$loser = Task $hf 'loser'
Expect-Error { Receive-AgentHandoff $loser.TaskDirectory $source.TaskId } 'already claimed'
[IO.File]::WriteAllText((Join-Path $c.Repository 'progress.txt'), 'progress')
$null = Unlock-AgentHandoff $c.TaskDirectory
Assert (@(Get-AgentHandoff $observer.TaskDirectory).Count -eq 1) 'Explicit release makes task available'
$winner = Task $hf 'finish'
$null = Receive-AgentHandoff $winner.TaskDirectory $source.TaskId
Assert (Test-Path (Join-Path $winner.Repository 'progress.txt')) 'Released progress preserved'
$handoffTip = Tip $winner.Repository "handoff/$($source.TaskId)"
$null = Complete-AgentTask $winner.TaskDirectory 'feat: finish handoff' {
    if (-not (Test-Path 'unfinished.txt') -or -not (Test-Path 'progress.txt')) { throw 'Missing handoff work' }
}
Assert ((Test-Path (Join-Path $hf.path 'progress.txt')) -and -not (Test-Path (Join-Path $hf.path '.handoff'))) 'Code-only handoff completion'
Assert (@(Get-AgentHandoff $observer.TaskDirectory).Count -eq 0) 'Completed handoff branch deleted'
$metadataAncestor = & $module { param($d, $id) Test-Published $d $id } $winner.Repository $handoffTip
Assert (-not $metadataAncestor) 'Main graph contains no handoff/ownership ancestors'
$publishedState = Get-Content -LiteralPath (Join-Path $winner.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
$publishedState.published = ''
$publishedState.branchDeleted = $false
$publishedState.synchronized = $false
[IO.File]::WriteAllText((Join-Path $winner.TaskDirectory 'task.json'), ($publishedState | ConvertTo-Json -Depth 12))
# A main push succeeded but recording the outcome was interrupted: recognize its exact candidate.
$null = Complete-AgentTask $winner.TaskDirectory 'feat: finish handoff' { throw 'Must not republish' }
Assert ((Tip $winner.Repository) -eq $publishedState.candidate) 'Ambiguous successful push recovered without duplicate publication'
$null = Jj $winner.Repository @('git', 'fetch', '--branch', '*')
$refs = (Jj $winner.Repository @('bookmark', 'list', '--remote', 'origin', '-T', 'if(remote == "origin", name ++ "\n")')).Trim()
Assert ($refs -eq 'main') 'Remote returns to main-only after handoff'

# Failed tests can be handed off after an integration candidate has been created.
$failed = Task $hf 'failed-integration'
[IO.File]::WriteAllText((Join-Path $failed.Repository 'failed.txt'), 'work')
[IO.File]::WriteAllText((Join-Path $failed.TaskDirectory 'PLAN.md'), '- [ ] repair failing tests')
Expect-Error { Complete-AgentTask $failed.TaskDirectory 'fix: failed' { throw 'blocked' } } 'Test failed'
$null = Publish-AgentHandoff $failed.TaskDirectory
$retryOwner = Task $hf 'retry-owner'
$null = Receive-AgentHandoff $retryOwner.TaskDirectory $failed.TaskId
Expect-Error { Complete-AgentTask $retryOwner.TaskDirectory 'fix: failed' { throw 'still blocked' } } 'Test failed'
[IO.File]::WriteAllText((Join-Path $retryOwner.TaskDirectory 'PLAN.md'), '- [ ] updated blocker')
[IO.File]::WriteAllText((Join-Path $retryOwner.Repository 'failed.txt'), 'progress after test failure')
$null = Unlock-AgentHandoff $retryOwner.TaskDirectory
$retryNext = Task $hf 'retry-next'
$receipt = Receive-AgentHandoff $retryNext.TaskDirectory $failed.TaskId
Assert ($receipt.Plan -match 'updated blocker') 'Release preserves PLAN edits after failed integration'
Assert ([IO.File]::ReadAllText((Join-Path $retryNext.Repository 'failed.txt')) -eq 'progress after test failure') 'Release preserves candidate edits'
$null = Complete-AgentTask $retryNext.TaskDirectory 'fix: failed' {}

# Main conflicts block completion, but unfinished conflicts may be shared on handoff only.
$conflicted = Task $hf 'conflicted'
$competing = Task $hf 'competing'
[IO.File]::WriteAllText((Join-Path $conflicted.Repository 'base.txt'), 'task version')
[IO.File]::WriteAllText((Join-Path $conflicted.TaskDirectory 'PLAN.md'), '- [ ] resolve base conflict')
[IO.File]::WriteAllText((Join-Path $competing.Repository 'base.txt'), 'main version')
$null = Complete-AgentTask $competing.TaskDirectory 'fix: competing' {}
Expect-Error { Complete-AgentTask $conflicted.TaskDirectory 'fix: conflicted' {} } 'conflicts'
$mainBeforeHandoff = Tip $conflicted.Repository
$null = Publish-AgentHandoff $conflicted.TaskDirectory
Assert ((Tip $conflicted.Repository) -eq $mainBeforeHandoff) 'Conflicted handoff does not advance main'
$resolver = Task $hf 'resolver'
$null = Receive-AgentHandoff $resolver.TaskDirectory $conflicted.TaskId
Expect-Error { Complete-AgentTask $resolver.TaskDirectory 'fix: resolve' {} } 'conflicts'
[IO.File]::WriteAllText((Join-Path $resolver.Repository 'base.txt'), 'resolved version')
$null = Complete-AgentTask $resolver.TaskDirectory 'fix: resolve' {}
Assert ([IO.File]::ReadAllText((Join-Path $hf.path 'base.txt')) -eq 'resolved version') 'Resolved handoff publishes code normally'

# Real simultaneous claims: both helpers reach push with the same expected remote tip.
$raceSource = Task $hf 'race-source'
[IO.File]::WriteAllText((Join-Path $raceSource.TaskDirectory 'PLAN.md'), '- [ ] race')
$null = Publish-AgentHandoff $raceSource.TaskDirectory
$r1 = Task $hf 'race-one'
$r2 = Task $hf 'race-two'
$barrier = Join-Path $root 'barrier'
$null = New-Item -ItemType Directory -Path $barrier
$workers = @()
foreach ($pair in @(@('one', $r1.TaskDirectory), @('two', $r2.TaskDirectory))) {
    $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'ClaimWorker.ps1'), '-ModulePath', $modulePath,
            '-TaskDirectory', $pair[1], '-TaskId', $raceSource.TaskId, '-Barrier', $barrier, '-Name', $pair[0])) {
        $info.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($info)
    $workers += [pscustomobject]@{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
}
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not ((Test-Path (Join-Path $barrier 'one.ready')) -and (Test-Path (Join-Path $barrier 'two.ready')))) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Workers did not reach claim barrier.' }
    Start-Sleep -Milliseconds 25
}
[IO.File]::WriteAllText((Join-Path $barrier 'go'), '')
foreach ($worker in $workers) {
    Assert ($worker.Process.WaitForExit(30000)) 'Claim worker completed'
    Assert ($worker.Process.ExitCode -eq 0) "Claim worker failed: $($worker.Error.GetAwaiter().GetResult())"
    $worker.Process.Dispose()
}
$results = @([IO.File]::ReadAllText((Join-Path $barrier 'one.result')), [IO.File]::ReadAllText((Join-Path $barrier 'two.result')))
Assert (@($results | Where-Object { $_ -eq 'claimed' }).Count -eq 1) 'Exactly one concurrent claimant succeeds'
Assert (@($results | Where-Object { $_ -eq 'rejected' }).Count -eq 1) 'Losing claimant is not rebased/retried'

# Explicit completed-research cleanup is allowed, but not for execution-phase tasks.
$research = Task $hf 'research-cleanup' -Plan
$null = Remove-AgentTask $research.TaskDirectory -ResearchComplete
Assert (-not (Test-Path $research.TaskDirectory)) 'Completed research cleaned without push'
Expect-Error { Remove-AgentTask $loser.TaskDirectory -ResearchComplete } 'plan-phase'

# Altered fetch or push targets are rejected before any network write.
$tampered = Task $hf 'tampered-origin'
$null = Jj $tampered.Repository @('git', 'remote', 'set-url', 'origin', '--push', 'https://github.com/other/repo')
Expect-Error { Publish-AgentHandoff $tampered.TaskDirectory } 'origin differs'
$null = Jj $tampered.Repository @('git', 'remote', 'set-url', 'origin', '--fetch', 'https://github.com/other/repo')
Expect-Error { Publish-AgentHandoff $tampered.TaskDirectory } 'origin differs'

# Unrelated remote branches stop workflow without being changed or deleted.
$null = Jj $observer.Repository @('git', 'fetch', '--branch', 'main')
$null = Jj $observer.Repository @('bookmark', 'set', 'unrelated', '-r', 'main@origin')
$null = Jj $observer.Repository @('git', 'push', '--bookmark', 'unrelated')
Expect-Error { & $module { param($d) Assert-RemoteBranches $d } $observer.Repository } 'Unexpected remote branches'
Assert ([bool](Tip $observer.Repository 'unrelated')) 'Unrelated branch preserved'

# Unsafe cleanup paths are rejected before deletion.
Expect-Error { Remove-AgentTask 'C:/dev/tmp' } 'direct child'
$linkRoot = Join-Path 'C:/dev/tmp' "agents-workflow-link-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Junction -Path $linkRoot -Target $b.TaskDirectory
Expect-Error { Remove-AgentTask $linkRoot } 'link or junction'
Remove-Item -LiteralPath $linkRoot
Assert (Test-Path $b.TaskDirectory) 'Link rejection preserved target'

# Test fixture teardown is explicit, not production cleanup of unfinished tasks.
foreach ($task in $script:Tasks) { if (Test-Path -LiteralPath $task) { Clean-TestDirectory $task } }
Clean-TestDirectory $root
"PASS: $script:Checks checks; local-only integration fixtures removed."
