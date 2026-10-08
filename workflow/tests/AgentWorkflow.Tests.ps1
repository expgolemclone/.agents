#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../AgentWorkflow.psm1'))
$module = Import-Module $modulePath -Force -PassThru
$root = "C:/dev/tmp/expgolemclone--.agents--workflow-tests--$([guid]::NewGuid().ToString('N').Substring(0,8))"
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
    param($Fixture, [string]$Name, [switch]$Plan, [Collections.IDictionary]$PreserveRemoteBranch = @{})
    $filter = "$($Fixture.repository -replace '/', '--')--$Name--*"
    $before = @(Get-ChildItem 'C:/dev/tmp' -Directory -Filter $filter | ForEach-Object FullName)
    try {
        & $module { param($e, $n, $execute, $preserved) New-Task $e $n -Execute:$execute -PreserveRemoteBranch $preserved } $Fixture $Name (-not $Plan) $PreserveRemoteBranch
    } finally {
        foreach ($path in @(Get-ChildItem 'C:/dev/tmp' -Directory -Filter $filter | ForEach-Object FullName)) {
            if ($path -notin $before) { $script:Tasks.Add($path) }
        }
    }
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

# Scheduled sync and workflow completion share one normalized-path lock and Box policy.
foreach ($path in @('C:/dev/Box/repo', 'C:/dev/box_projects/repo')) {
    Assert (-not (Test-AgentRepositoryPathAllowed $path)) 'Box paths are excluded'
    Expect-Error { Invoke-AgentRepositoryLock -RepositoryPath $path -Action { throw 'Must not run' } } 'Box repositories'
}
$lockPath = Join-Path $root 'lock-repository'
Assert ((Invoke-AgentRepositoryLock -RepositoryPath $lockPath -Action { 'result' }) -eq 'result') 'Lock returns action output'
Expect-Error { Invoke-AgentRepositoryLock -RepositoryPath $lockPath -Action { throw 'action failed' } } 'action failed'
Assert ((Invoke-AgentRepositoryLock -RepositoryPath $lockPath -TimeoutSeconds 0 -Action { 'released' }) -eq 'released') 'Failure releases lock'
Invoke-AgentRepositoryLock -RepositoryPath $lockPath -Action {
    $job = Start-Job -ArgumentList $modulePath, ($lockPath.ToUpperInvariant() + '/') -ScriptBlock {
        param($modulePath, $path)
        Import-Module $modulePath
        try { Invoke-AgentRepositoryLock -RepositoryPath $path -TimeoutSeconds 0 -Action { 'incorrectly acquired' } }
        catch { $_.Exception.Message }
    }
    try {
        $output = Receive-Job $job -Wait -AutoRemoveJob
        Assert ($output -eq 'Registered repository synchronization is busy.') 'Concurrent normalized path cannot acquire held lock'
    } finally { if (Get-Job -Id $job.Id -ErrorAction SilentlyContinue) { Remove-Job $job } }
}

# Default planning phase blocks every remote mutation, while research clones work.
$f = New-Fixture 'normal'
$p = Task $f 'planning' -Plan
$leaf = Split-Path $p.TaskDirectory -Leaf
Assert ($leaf -cmatch '^expgolemclone--workflow-test--planning--[0-9a-f]{8}$') 'Task directory uses owner--repo--task--random-id without timestamp'
Assert ($p.TaskId -cmatch '^planning-\d{8}-\d{6}-\d{3}-[0-9a-f]{8}$') 'Task ID format stays unchanged'
Assert ($p.TaskId.EndsWith('-' + ($leaf -split '--')[-1])) 'Directory random ID still correlates with task ID'
Assert ($p.Repository -eq (Join-Path $p.TaskDirectory 'repository')) 'Internal repository layout stays unchanged'
$repeat = Task $f 'planning' -Plan
Assert ($repeat.TaskDirectory -ne $p.TaskDirectory) 'Repeated task names get independent directories'
$null = Remove-AgentTask $repeat.TaskDirectory -ResearchComplete
$namedEntry = [pscustomobject]@{ repository = 'Example-Owner/.dot_repo-name'; remote = $f.remote; path = $f.path }
$named = Task $namedEntry 'path-check' -Plan
Assert ((Split-Path $named.TaskDirectory -Leaf) -cmatch '^Example-Owner--\.dot_repo-name--path-check--[0-9a-f]{8}$') 'Mapped owner/repo punctuation and case are preserved'
$null = Remove-AgentTask $named.TaskDirectory -ResearchComplete
$unsafeEntry = [pscustomobject]@{ repository = 'owner/../escape'; remote = $f.remote; path = $f.path }
Expect-Error { & $module { param($e) New-Task $e 'path-check' } $unsafeEntry } 'owner/repo'
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

# Multiple registered workspaces and published merge parents are safe, without moving other workspaces.
$mf = New-Fixture 'multiple-workspaces'
$seedTip = Tip $mf.path
$fixtureRoot = Split-Path $mf.path -Parent
$publishedWorkspace = Join-Path $fixtureRoot 'published'
$emptyWorkspace = Join-Path $fixtureRoot 'empty'
$mergeWorkspace = Join-Path $fixtureRoot 'published-merge'
$null = Jj $mf.path @('workspace', 'add', '--name', 'published', '-r', 'main', $publishedWorkspace)
[IO.File]::WriteAllText((Join-Path $publishedWorkspace 'published.txt'), 'published')
$null = Jj $publishedWorkspace @('describe', '-m', 'test: published workspace')
$publishedTip = (Jj $publishedWorkspace @('log', '--no-graph', '-r', '@', '-T', 'commit_id')).Trim()
$null = Jj $mf.path @('bookmark', 'set', 'main', '-r', $publishedTip)
$null = Jj $mf.path @('git', 'push', '--remote', 'origin', '--bookmark', 'exact:main')
$null = Jj $mf.path @('workspace', 'add', '--name', 'empty', '-r', 'main', $emptyWorkspace)
$null = Jj $mf.path @('workspace', 'add', '--name', 'published-merge', '-r', $seedTip, '-r', $publishedTip, $mergeWorkspace)
Assert ((Jj $mf.path @('workspace', 'list', '-T', 'if(name == "published", if(target.empty(), "empty", "nonempty"))')).Trim() -eq 'nonempty') 'Fixture includes a nonempty published workspace'
Assert ((Jj $mf.path @('workspace', 'list', '-T', 'if(name == "published-merge", if(target.empty(), target.parents().map(|p| "parent").join(",")))')).Trim() -eq 'parent,parent') 'Fixture includes an empty merge with two published parents'
$otherTargets = Jj $mf.path @('workspace', 'list', '-T', 'if(name != "default", name ++ ":" ++ target.commit_id() ++ "\n")')
$multi = Task $mf 'multi-workspace-sync'
[IO.File]::WriteAllText((Join-Path $multi.Repository 'remote.txt'), 'remote')
$null = Complete-AgentTask $multi.TaskDirectory 'feat: multiple workspaces' {}
Assert (Test-Path (Join-Path $mf.path 'remote.txt')) 'Multiple safe workspaces synchronize to latest main'
Assert ((Jj $mf.path @('workspace', 'list', '-T', 'if(name != "default", name ++ ":" ++ target.commit_id() ++ "\n")')) -eq $otherTargets) 'Synchronization preserves every other workspace target'

# Any unsafe secondary workspace or merge parent still blocks synchronization.
$privateWorkspace = Join-Path $fixtureRoot 'private'
$null = Jj $mf.path @('workspace', 'add', '--name', 'private', '-r', 'main', $privateWorkspace)
[IO.File]::WriteAllText((Join-Path $privateWorkspace 'private.txt'), 'private')
$null = Jj $privateWorkspace @('describe', '-m', 'wip: private workspace')
$privateTip = (Jj $privateWorkspace @('log', '--no-graph', '-r', '@', '-T', 'commit_id')).Trim()
Expect-Error { Sync-AgentRepository $multi.TaskDirectory } 'unpublished work'
Assert ([IO.File]::ReadAllText((Join-Path $privateWorkspace 'private.txt')) -eq 'private') 'Unpublished secondary workspace content preserved'
$null = Jj $privateWorkspace @('new', '@')
Expect-Error { Sync-AgentRepository $multi.TaskDirectory } 'unpublished work'
$null = Jj $privateWorkspace @('new', 'main', $privateTip)
Assert ((Jj $mf.path @('workspace', 'list', '-T', 'if(name == "private", if(target.empty(), target.parents().map(|p| if(p.contained_in("::main@origin"), "yes", "no")).join(",")))')).Trim() -eq 'yes,no') 'Fixture includes an empty merge with one unpublished parent'
$blockedTargets = Jj $mf.path @('workspace', 'list', '-T', 'name ++ ":" ++ target.commit_id() ++ "\n"')
Expect-Error { Sync-AgentRepository $multi.TaskDirectory } 'unpublished work'
Assert ((Jj $mf.path @('workspace', 'list', '-T', 'name ++ ":" ++ target.commit_id() ++ "\n"')) -eq $blockedTargets) 'Blocked synchronization changes no workspace target'
Assert ([IO.File]::ReadAllText((Join-Path $privateWorkspace 'private.txt')) -eq 'private') 'Unpublished merge content preserved'

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

# User-approved preservation is exact, task-scoped, read-only and checked after tests.
$pf = New-Fixture 'preserved'
$producer = Task $pf 'legacy-producer'
[IO.File]::WriteAllText((Join-Path $producer.Repository 'legacy.txt'), 'legacy content, not approved for integration')
$null = Jj $producer.Repository @('describe', '-m', 'test: legacy branch')
$null = Jj $producer.Repository @('bookmark', 'set', 'quality-work/audit')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
$legacy = Tip $producer.Repository 'quality-work/audit'
Expect-Error { Task $pf 'unapproved' } 'Unexpected remote branches'
Expect-Error { Task $pf 'wrong-tip' -PreserveRemoteBranch @{ 'quality-work/audit' = ('0' * 40) } } 'changed or disappeared'
foreach ($approval in @(@{ main = $legacy }, @{ 'handoff/task' = $legacy }, @{ 'quality-work/*' = $legacy },
        @{ 'quality-work/audit' = $legacy.Substring(0,8) })) {
    Expect-Error { & $module { param($a) Assert-PreservedBranches $a } $approval } 'exact non-workflow branch'
}
$approved = Task $pf 'approved' -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
Assert (-not (Test-Path (Join-Path $approved.Repository 'legacy.txt'))) 'Preservation never imports legacy content'
$approvalState = Get-Content (Join-Path $approved.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
Assert ($approvalState.preservedBranches.'quality-work/audit' -eq $legacy) 'Exact approved tip recorded only in task metadata'
Expect-Error { & $module { param($s, $tip) Push-Branch $s 'quality-work/audit' $tip } $approvalState $legacy } 'read-only'
[IO.File]::WriteAllText((Join-Path $approved.Repository 'normal.txt'), 'normal work')
$null = Complete-AgentTask $approved.TaskDirectory 'feat: work beside preserved branch' {}
Assert ((Tip $approved.Repository 'quality-work/audit') -eq $legacy) 'Normal main publication preserves legacy tip'
Assert (-not (Test-Path (Join-Path $pf.path 'legacy.txt'))) 'Registered checkout excludes legacy work'
Assert (-not (Test-Path (Join-Path $pf.path 'task.json'))) 'Approval metadata never reaches main'
Expect-Error { Task $pf 'not-inherited' } 'Unexpected remote branches'

$planned = Task $pf 'preserved-plan' -Plan -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
Expect-Error { Complete-AgentTask $planned.TaskDirectory 'fix: not authorized' {} } 'plan phase'
$approvalSource = Task $pf 'preserved-handoff' -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $approvalSource.TaskDirectory 'PLAN.md'), '- [ ] finish independent work')
$null = Publish-AgentHandoff $approvalSource.TaskDirectory
$approvalOwner = Task $pf 'preserved-owner' -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
$null = Receive-AgentHandoff $approvalOwner.TaskDirectory $approvalSource.TaskId
$null = Complete-AgentTask $approvalOwner.TaskDirectory 'chore: finish independent work' {}
Assert ((Tip $approvalOwner.Repository 'quality-work/audit') -eq $legacy) 'Handoff claim/completion/deletion never changes preserved branch'

$late = Task $pf 'late-branch' -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $late.Repository 'late.txt'), 'candidate')
$beforeLate = Tip $late.Repository
$lateTest = {
    $null = Jj $producer.Repository @('bookmark', 'set', 'another-branch', '-r', 'main@origin')
    $null = Jj $producer.Repository @('git', 'push', '--bookmark', 'another-branch')
}.GetNewClosure()
Expect-Error { Complete-AgentTask $late.TaskDirectory 'fix: late branch' $lateTest } 'Unexpected remote branches'
Assert ((Tip $late.Repository) -eq $beforeLate) 'New unapproved branch during tests blocks main publication'
$null = Jj $producer.Repository @('bookmark', 'delete', 'another-branch')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'another-branch')

$changed = Task $pf 'changed-preserved' -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $changed.Repository 'changed.txt'), 'candidate')
$beforeChanged = Tip $changed.Repository
$changeTest = {
    [IO.File]::WriteAllText((Join-Path $producer.Repository 'legacy.txt'), 'external update')
    $null = Jj $producer.Repository @('describe', '-m', 'test: external legacy update')
    $null = Jj $producer.Repository @('bookmark', 'set', 'quality-work/audit')
    $null = Jj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
}.GetNewClosure()
Expect-Error { Complete-AgentTask $changed.TaskDirectory 'fix: changed approval' $changeTest } 'changed or disappeared'
Assert ((Tip $changed.Repository) -eq $beforeChanged) 'Changed approved tip during tests blocks main publication'
$externalTip = Tip $producer.Repository 'quality-work/audit'
Assert ($externalTip -ne $legacy) 'External branch update is preserved, not reset to approved tip'
$deleted = Task $pf 'deleted-preserved' -PreserveRemoteBranch @{ 'quality-work/audit' = $externalTip }
$null = Jj $producer.Repository @('bookmark', 'delete', 'quality-work/audit')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
Expect-Error { Complete-AgentTask $deleted.TaskDirectory 'fix: missing approval' {} } 'changed or disappeared'
Assert (-not (Tip $deleted.Repository 'quality-work/audit')) 'Externally deleted branch is not recreated'

# Unsafe cleanup paths are rejected before deletion.
Expect-Error { Remove-AgentTask 'C:/dev/tmp' } 'direct child'
$linkRoot = Join-Path 'C:/dev/tmp' "expgolemclone--.agents--workflow-link--$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Junction -Path $linkRoot -Target $b.TaskDirectory
Expect-Error { Remove-AgentTask $linkRoot } 'link or junction'
Remove-Item -LiteralPath $linkRoot
Assert (Test-Path $b.TaskDirectory) 'Link rejection preserved target'

# Test fixture teardown is explicit, not production cleanup of unfinished tasks.
foreach ($task in $script:Tasks) { if (Test-Path -LiteralPath $task) { Clean-TestDirectory $task } }
Clean-TestDirectory $root
"PASS: $script:Checks checks; local-only integration fixtures removed."
