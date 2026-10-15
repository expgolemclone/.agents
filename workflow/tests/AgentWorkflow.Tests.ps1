#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../AgentWorkflow.psm1'))
$module = Import-Module $modulePath -Force -PassThru
$root = "C:/dev/tmp/awt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$null = New-Item -ItemType Directory -Path $root
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
    param($Fixture, [switch]$Plan, [Collections.IDictionary]$PreserveRemoteBranch = @{})
    & $module { param($e, $execute, $preserved) New-Task $e -Execute:$execute -PreserveRemoteBranch $preserved } $Fixture (-not $Plan) $PreserveRemoteBranch
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

# Default planning phase blocks every remote mutation, while research workspaces work.
$f = New-Fixture 'normal'
$p = Task $f -Plan
$leaf = Split-Path $p.TaskDirectory -Leaf
Assert ($leaf -cmatch '^[0-9a-f]{32}$') 'Task directory is an opaque full GUID'
Assert ($p.TaskId -ceq $leaf) 'Initial TaskId is the directory GUID'
Assert ([guid]::ParseExact($leaf, 'N').ToString('N') -ceq $leaf) 'ID is a standard N-format GUID'
Assert ((Split-Path $p.TaskDirectory -Parent) -eq [IO.Path]::GetFullPath('C:/dev/tmp')) 'Task is a direct child of tmp'
Assert ($p.Repository -eq (Join-Path $p.TaskDirectory 'repository')) 'Internal repository layout stays unchanged'
Assert (-not (Get-Command Start-AgentTask).Parameters.ContainsKey('Name')) 'Public task creation has no Name parameter'
Assert (-not (& $module { (Get-Command New-Task).Parameters.ContainsKey('Name') })) 'Internal task creation has no Name parameter'
$repeat = Task $f -Plan
Assert ($repeat.TaskDirectory -ne $p.TaskDirectory -and $repeat.TaskId -ne $p.TaskId) 'Repeated starts get independent GUIDs'
Assert (Test-Path (Join-Path $repeat.TaskDirectory 'task.json')) 'Repeated plan task remains available'
$namedEntry = [pscustomobject]@{ repository = 'Example-Owner/.dot_repo-name'; remote = $f.remote; path = $f.path }
$named = Task $namedEntry -Plan
Assert ((Split-Path $named.TaskDirectory -Leaf) -cmatch '^[0-9a-f]{32}$') 'Repository names do not appear in task paths'
Assert (Test-Path $named.Repository) 'Research clone remains available'
$unsafeEntry = [pscustomobject]@{ repository = 'owner/../escape'; remote = $f.remote; path = $f.path }
Expect-Error { & $module { param($e) New-Task $e } $unsafeEntry } 'owner/repo'

# Simulate another creator occupying the chosen GUID just before exclusive creation.
$collision = & $module {
    param($fixture)
    $script:CollisionPath = ''
    function script:New-Item {
        [CmdletBinding()]
        param([string]$ItemType, [string]$Path)
        $script:CollisionPath = $Path
        $null = Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        [IO.File]::WriteAllText((Join-Path $Path 'task.json'), 'occupied state')
        [IO.File]::WriteAllText((Join-Path $Path 'existing.txt'), 'occupied source')
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    try {
        try { $null = New-Task $fixture; throw 'Expected collision rejection' }
        catch { [pscustomobject]@{ Path = $script:CollisionPath; ErrorId = $_.FullyQualifiedErrorId } }
    } finally {
        Remove-Item Function:New-Item
        Remove-Variable CollisionPath -Scope Script
    }
} $f
Assert ($collision.ErrorId -match '^DirectoryExist,') 'An occupied GUID directory stops creation'
Assert ([IO.File]::ReadAllText((Join-Path $collision.Path 'task.json')) -eq 'occupied state') 'Collision preserves existing task state'
Assert ([IO.File]::ReadAllText((Join-Path $collision.Path 'existing.txt')) -eq 'occupied source') 'Collision preserves existing files'
Assert (-not (Test-Path (Join-Path $collision.Path 'repository'))) 'Collision stops before cloning'
Assert ($p.Phase -eq 'plan') 'Default phase is plan'
Expect-Error { Publish-AgentHandoff $p.TaskDirectory } 'plan phase'
Expect-Error { Receive-AgentHandoff $p.TaskDirectory 'nothing' } 'plan phase'
Expect-Error { Complete-AgentTask $p.TaskDirectory 'fix: test' {} } 'plan phase'
Expect-Error { Enable-AgentTaskExecution $p.TaskDirectory -Doit:$false } 'authorization'
$null = Enable-AgentTaskExecution $p.TaskDirectory -Doit
Assert ((Get-Content -LiteralPath (Join-Path $p.TaskDirectory 'task.json') -Raw | ConvertFrom-Json).phase -eq 'execute') 'Explicit authorization changes phase'
Expect-Error { & $module { Assert-PushAllowed 'https://github.com/other/repo' } } 'allowed only'

# Full-history objects are stored once; task directories contain only checkout/workspace metadata.
$sf = New-Fixture 'shared-history'
$historySeed = Join-Path (Split-Path $sf.path -Parent) 'seed'
for ($i = 0; $i -lt 8; $i++) {
    $null = Jj $historySeed @('new', 'main')
    $bytes = [byte[]]::new(131072)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    [IO.File]::WriteAllBytes((Join-Path $historySeed 'history.bin'), $bytes)
    $null = Jj $historySeed @('describe', '-m', "test: history $i")
    $null = Jj $historySeed @('bookmark', 'set', 'main')
}
$null = Jj $historySeed @('new', 'main')
Remove-Item (Join-Path $historySeed 'history.bin')
$null = Jj $historySeed @('describe', '-m', 'test: remove historical blob')
$null = Jj $historySeed @('bookmark', 'set', 'main')
$null = Jj $historySeed @('git', 'export')
$s1 = Task $sf -Plan
$sharedRepo = & $module { param($d) Get-JjRepositoryPath $d } $s1.Repository
$objectsPath = Join-Path $sharedRepo 'store/git/objects'
$initialObjectBytes = (Get-ChildItem $objectsPath -Force -Recurse -File | Measure-Object Length -Sum).Sum
$beforeStoreBytes = (Get-ChildItem $sharedRepo -Force -Recurse -File | Measure-Object Length -Sum).Sum
$s2 = Task $sf -Plan
$afterObjectBytes = (Get-ChildItem $objectsPath -Force -Recurse -File | Measure-Object Length -Sum).Sum
$afterStoreBytes = (Get-ChildItem $sharedRepo -Force -Recurse -File | Measure-Object Length -Sum).Sum
$workspaceBytes = (Get-ChildItem $s2.Repository -Force -Recurse -File | Measure-Object Length -Sum).Sum
Assert ($initialObjectBytes -gt 1MB) 'Fixture actually contains substantial full-history objects'
Assert ((& $module { param($d) Get-JjRepositoryPath $d } $s2.Repository) -eq $sharedRepo) 'Tasks reuse exactly the same native store'
Assert (-not (Test-Path (Join-Path $s2.Repository '.git'))) 'Task workspace does not create another Git object store'
Assert ($workspaceBytes -lt 16KB) 'A new tiny checkout writes only small workspace metadata'
Assert (($afterObjectBytes - $initialObjectBytes) -lt 16KB) 'New task does not fetch or duplicate historical blobs'
Assert (($afterStoreBytes - $beforeStoreBytes) -lt 128KB) 'New task has bounded shared metadata growth'
$registeredRepo = & $module { param($d) Get-JjRepositoryPath $d } $sf.path
Assert ($registeredRepo -ne $sharedRepo) 'Registered repository store remains independent'
Assert ((Jj $s1.Repository @('workspace', 'list', '-T', 'name ++ "\n"')) -match (Split-Path $s2.TaskDirectory -Leaf)) 'Workspace names are the original GUIDs'
[IO.File]::WriteAllText((Join-Path $s1.Repository 'isolated.txt'), 'one task only')
$id1 = & $module { param($d) Get-CurrentId $d } $s1.Repository
$id2 = & $module { param($d) Get-CurrentId $d } $s2.Repository
Assert ($id1 -ne $id2 -and -not (Test-Path (Join-Path $s2.Repository 'isolated.txt'))) 'Current IDs and checked-out changes are workspace-local'
[pscustomobject]@{ InitialObjectBytes=$initialObjectBytes; NextTaskObjectGrowth=($afterObjectBytes - $initialObjectBytes); NextTaskStoreGrowth=($afterStoreBytes - $beforeStoreBytes); NextTaskWorkspaceBytes=$workspaceBytes } |
    ConvertTo-Json | Set-Content (Join-Path $root 'size-report.json')
# Manual removal of one task cannot remove a peer's store or invalidate its commit.
Get-ChildItem $s1.TaskDirectory -Force -Recurse | ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
Remove-Item $s1.TaskDirectory -Recurse -Force
Assert ((& $module { param($d) Get-CurrentId $d } $s2.Repository) -eq $id2) 'Peer workspace survives removal of another task directory'
Assert (Test-Path $sharedRepo) 'Shared store is outside removable task directories'

# Two processes racing on a cold origin initialize one native store, then distinct workspaces.
$coldFixture = New-Fixture 'cold-start'
$coldBarrier = Join-Path $root 'cold-barrier'
$null = New-Item -ItemType Directory $coldBarrier
$coldJobs = @()
foreach ($name in @('one', 'two')) {
    $coldJobs += Start-Job -ArgumentList $modulePath, $coldFixture, $coldBarrier, $name -ScriptBlock {
        param($modulePath, $fixture, $barrier, $name)
        $ErrorActionPreference = 'Stop'
        $m = Import-Module $modulePath -Force -PassThru
        [IO.File]::WriteAllText((Join-Path $barrier "$name.ready"), '')
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path (Join-Path $barrier 'go'))) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Cold-start barrier timed out.' }
            Start-Sleep -Milliseconds 25
        }
        & $m { param($e) New-Task $e } $fixture
    }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not ((Test-Path (Join-Path $coldBarrier 'one.ready')) -and (Test-Path (Join-Path $coldBarrier 'two.ready')))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Cold-start workers did not reach barrier.' }
        Start-Sleep -Milliseconds 25
    }
    [IO.File]::WriteAllText((Join-Path $coldBarrier 'go'), '')
    $coldTasks = @(Receive-Job $coldJobs -Wait -ErrorAction Stop)
    Assert ($coldTasks.Count -eq 2) 'Both cold starts succeeded'
    $coldStore = & $module { param($d) Get-JjRepositoryPath $d } $coldTasks[0].Repository
    Assert ((& $module { param($d) Get-JjRepositoryPath $d } $coldTasks[1].Repository) -eq $coldStore) 'Concurrent cold starts share one published store'
    Assert ($coldTasks[0].TaskId -ne $coldTasks[1].TaskId) 'Concurrent starts retain unique task IDs'
    Assert (@((Jj $coldTasks[0].Repository @('workspace', 'list', '-T', 'name ++ "\n"')).Trim() -split '\r?\n').Count -eq 3) 'Only default and two task workspaces were initialized'
    Assert ((Jj $coldTasks[0].Repository @('config', 'get', 'git.abandon-unreachable-commits')).Trim() -eq 'false') 'Fetch will not abandon retained peer work'
} finally { Remove-Job $coldJobs -Force }

# Failed initialization never publishes task state that could be used as a valid task.
$invalidFixture = New-Fixture 'missing-main'
$invalidSeed = Join-Path (Split-Path $invalidFixture.path -Parent) 'seed'
$null = Jj $invalidSeed @('bookmark', 'delete', 'main')
$null = Jj $invalidSeed @('git', 'export')
$beforeTasks = @(Get-ChildItem 'C:/dev/tmp' -Directory -Force | Where-Object Name -cmatch '^[0-9a-f]{32}$' | ForEach-Object FullName)
Expect-Error { Task $invalidFixture -Plan } 'Remote main is required'
$failedTasks = @(Get-ChildItem 'C:/dev/tmp' -Directory -Force | Where-Object { $_.Name -cmatch '^[0-9a-f]{32}$' -and $_.FullName -notin $beforeTasks })
Assert ($failedTasks.Count -eq 1 -and -not (Test-Path (Join-Path $failedTasks[0].FullName 'task.json'))) 'Failed start has no usable task.json'
$null = Jj $invalidSeed @('bookmark', 'set', 'main')
$null = Jj $invalidSeed @('git', 'export')
$recoveredStart = Task $invalidFixture -Plan
Assert (Test-Path (Join-Path $recoveredStart.TaskDirectory 'task.json')) 'A later fetch can initialize a previously missing main safely'

# Two tasks from one base integrate independently; registration stays unchanged until push.
$a = Task $f
$b = Task $f
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
foreach ($completed in @($a, $b)) {
    foreach ($path in @('repository', 'task.json', 'test.log')) {
        Assert (Test-Path (Join-Path $completed.TaskDirectory $path)) 'Completed task retains repository, state and test log'
    }
}

# A task with no remaining code delta completes without an empty main commit.
$empty = Task $f
$emptyMain = Tip $empty.Repository
$quietResult = Complete-AgentTask $empty.TaskDirectory 'chore: no delta' { Write-Host 'PRIVATE-TEST-DETAIL' }
Assert ((Tip $empty.Repository) -eq $emptyMain) 'No-op completion does not create main context'
Assert (($quietResult | Out-String) -notmatch 'PRIVATE-TEST-DETAIL') 'Detailed test output stays out of agent context'
Assert ([IO.File]::ReadAllText((Join-Path $empty.TaskDirectory 'test.log')) -match 'PRIVATE-TEST-DETAIL') 'Detailed test output is retained in log'

# A real remote advance during testing causes a forward-push retry and a fresh test.
$raceA = Task $f
$raceB = Task $f
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
# A peer-ref refresh cannot authorize publication against a stale frozen main tip.
$staleTip = $initial
$sharedTip = Tip $raceA.Repository
$sharedState = Get-Content (Join-Path $raceA.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
Expect-Error { & $module { param($s, $candidate, $expected) Push-Branch $s 'main' $candidate $expected } $sharedState $sharedTip $staleTip } 'changed before publication'
Assert ((Tip $raceA.Repository) -eq $sharedTip) 'Stale expected tip cannot overwrite refreshed shared main'

# A no-op task must also retest if a peer advances main during its validation.
$noopA = Task $f
$noopB = Task $f
[IO.File]::WriteAllText((Join-Path $noopB.Repository 'noop-race.txt'), 'peer work')
$noopGate = [pscustomobject]@{ Tests = 0 }
$noopTest = {
    $noopGate.Tests++
    if ($noopGate.Tests -eq 1) { $null = Complete-AgentTask $noopB.TaskDirectory 'feat: noop race peer' {} }
    elseif (-not (Test-Path 'noop-race.txt')) { throw 'No-op retry did not see peer tree' }
}.GetNewClosure()
$null = Complete-AgentTask $noopA.TaskDirectory 'chore: noop race' $noopTest
Assert ($noopGate.Tests -eq 2) 'No-op completion revalidates after a shared main update'
Assert ((Get-Content (Join-Path $noopA.TaskDirectory 'task.json') -Raw | ConvertFrom-Json).published -eq (Tip $noopB.Repository)) 'No-op records the newly validated main, not its stale base'

# Dirty checkout preserves user files and records main success separately from sync.
$d = Task $f
[IO.File]::WriteAllText((Join-Path $d.Repository 'done.txt'), 'done')
[IO.File]::WriteAllText((Join-Path $f.path 'base.txt'), 'user edit')
Expect-Error { Complete-AgentTask $d.TaskDirectory 'feat: done' {} } 'has changes'
$state = Get-Content -LiteralPath (Join-Path $d.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
Assert ([bool]$state.published -and -not $state.synchronized) 'Main push survives failed synchronization'
Assert ([IO.File]::ReadAllText((Join-Path $f.path 'base.txt')) -eq 'user edit') 'Dirty user files preserved'
Assert (Test-Path $d.Repository) 'Synchronization failure retains task clone'
$null = Jj $f.path @('restore', 'base.txt')
$null = Sync-AgentRepository $d.TaskDirectory
Assert (Test-Path (Join-Path $f.path 'done.txt')) 'Sync retry picks latest remote'

# Test failures never push code and retain sources; subsequent corrections are honored.
$e = Task $f
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
$u = Task $f
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
$multi = Task $mf
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
$source = Task $hf
[IO.File]::WriteAllText((Join-Path $source.Repository 'unfinished.txt'), 'unfinished')
[IO.File]::WriteAllText((Join-Path $source.TaskDirectory 'PLAN.md'), "# SECRET-PLAN-BODY`n- [ ] finish")
$null = Publish-AgentHandoff $source.TaskDirectory
Assert (-not (Test-Path (Join-Path $source.TaskDirectory 'PLAN.md'))) 'PLAN moved, not duplicated'
$observer = Task $hf -Plan
$list = @(Get-AgentHandoff $observer.TaskDirectory)
Assert ($list.Count -eq 1 -and $list[0].TaskId -eq $source.TaskId) 'Available ID discovered'
Assert (($list | ConvertTo-Json) -notmatch 'SECRET-PLAN-BODY') 'Discovery exposes no PLAN body'
$c = Task $hf
$claimPath = $c.TaskDirectory
$receipt = Receive-AgentHandoff $c.TaskDirectory $source.TaskId
$claimState = Get-Content (Join-Path $claimPath 'task.json') -Raw | ConvertFrom-Json
Assert ($claimState.path -eq $claimPath -and (Test-Path $c.Repository)) 'Handoff receipt preserves local clone location'
Assert ($claimState.taskId -eq $source.TaskId -and $claimState.taskId -ne (Split-Path $claimPath -Leaf)) 'Shared handoff ID replaces local initial ID without renaming'
Assert ($source.TaskId -cmatch '^[0-9a-f]{32}$') 'New handoff IDs are opaque full GUIDs'
Assert ($receipt.Plan -match 'SECRET-PLAN-BODY') 'Body returned only after ownership acquired'
Assert (@(Get-AgentHandoff $observer.TaskDirectory).Count -eq 0) 'Occupied task omitted entirely'
$loser = Task $hf
Expect-Error { Receive-AgentHandoff $loser.TaskDirectory $source.TaskId } 'already claimed'
[IO.File]::WriteAllText((Join-Path $c.Repository 'progress.txt'), 'progress')
$null = Unlock-AgentHandoff $c.TaskDirectory
Assert (@(Get-AgentHandoff $observer.TaskDirectory).Count -eq 1) 'Explicit release makes task available'
$winner = Task $hf
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

# A handoff predating many main commits retains its base and rebases only its own code delta.
$oldFixture = New-Fixture 'older-handoff'
$oldSource = Task $oldFixture
$oldBase = Tip $oldSource.Repository
[IO.File]::WriteAllText((Join-Path $oldSource.Repository 'old-task.txt'), 'old task progress')
[IO.File]::WriteAllText((Join-Path $oldSource.TaskDirectory 'PLAN.md'), '- [ ] finish older task')
$null = Publish-AgentHandoff $oldSource.TaskDirectory
$oldSeed = Join-Path (Split-Path $oldFixture.path -Parent) 'seed'
for ($i = 0; $i -lt 8; $i++) {
    $null = Jj $oldSeed @('new', 'main')
    [IO.File]::WriteAllText((Join-Path $oldSeed "later-$i.txt"), "later $i")
    $null = Jj $oldSeed @('describe', '-m', "test: later main $i")
    $null = Jj $oldSeed @('bookmark', 'set', 'main')
}
$null = Jj $oldSeed @('git', 'export')
$oldOwner = Task $oldFixture
$null = Receive-AgentHandoff $oldOwner.TaskDirectory $oldSource.TaskId
Assert ((Get-Content (Join-Path $oldOwner.TaskDirectory 'task.json') -Raw | ConvertFrom-Json).base -eq $oldBase) 'Received older handoff preserves its original base'
Assert ((Jj $oldOwner.Repository @('log', '-r', "$oldBase & ::main@origin", '--no-graph', '-T', 'commit_id')).Trim() -eq $oldBase) 'Old handoff base remains a real ancestor of current main'
$null = Complete-AgentTask $oldOwner.TaskDirectory 'feat: finish older handoff' {
    if (-not (Test-Path 'old-task.txt')) { throw 'Missing older task delta' }
    for ($i = 0; $i -lt 8; $i++) {
        if (-not (Test-Path "later-$i.txt")) { throw 'Older handoff overwrote newer main' }
    }
}
Assert ((Test-Path (Join-Path $oldFixture.path 'old-task.txt')) -and (Test-Path (Join-Path $oldFixture.path 'later-7.txt'))) 'Older handoff integration preserves all newer main work'

# Failed tests can be handed off after an integration candidate has been created.
$failed = Task $hf
[IO.File]::WriteAllText((Join-Path $failed.Repository 'failed.txt'), 'work')
[IO.File]::WriteAllText((Join-Path $failed.TaskDirectory 'PLAN.md'), '- [ ] repair failing tests')
Expect-Error { Complete-AgentTask $failed.TaskDirectory 'fix: failed' { throw 'blocked' } } 'Test failed'
$null = Publish-AgentHandoff $failed.TaskDirectory
$retryOwner = Task $hf
$null = Receive-AgentHandoff $retryOwner.TaskDirectory $failed.TaskId
Expect-Error { Complete-AgentTask $retryOwner.TaskDirectory 'fix: failed' { throw 'still blocked' } } 'Test failed'
[IO.File]::WriteAllText((Join-Path $retryOwner.TaskDirectory 'PLAN.md'), '- [ ] updated blocker')
[IO.File]::WriteAllText((Join-Path $retryOwner.Repository 'failed.txt'), 'progress after test failure')
$null = Unlock-AgentHandoff $retryOwner.TaskDirectory
$retryNext = Task $hf
$receipt = Receive-AgentHandoff $retryNext.TaskDirectory $failed.TaskId
Assert ($receipt.Plan -match 'updated blocker') 'Release preserves PLAN edits after failed integration'
Assert ([IO.File]::ReadAllText((Join-Path $retryNext.Repository 'failed.txt')) -eq 'progress after test failure') 'Release preserves candidate edits'
$null = Complete-AgentTask $retryNext.TaskDirectory 'fix: failed' {}

# Main conflicts block completion, but unfinished conflicts may be shared on handoff only.
$conflicted = Task $hf
$competing = Task $hf
[IO.File]::WriteAllText((Join-Path $conflicted.Repository 'base.txt'), 'task version')
[IO.File]::WriteAllText((Join-Path $conflicted.TaskDirectory 'PLAN.md'), '- [ ] resolve base conflict')
[IO.File]::WriteAllText((Join-Path $competing.Repository 'base.txt'), 'main version')
$null = Complete-AgentTask $competing.TaskDirectory 'fix: competing' {}
Expect-Error { Complete-AgentTask $conflicted.TaskDirectory 'fix: conflicted' {} } 'conflicts'
$mainBeforeHandoff = Tip $conflicted.Repository
$null = Publish-AgentHandoff $conflicted.TaskDirectory
Assert ((Tip $conflicted.Repository) -eq $mainBeforeHandoff) 'Conflicted handoff does not advance main'
$resolver = Task $hf
$null = Receive-AgentHandoff $resolver.TaskDirectory $conflicted.TaskId
Expect-Error { Complete-AgentTask $resolver.TaskDirectory 'fix: resolve' {} } 'conflicts'
[IO.File]::WriteAllText((Join-Path $resolver.Repository 'base.txt'), 'resolved version')
$null = Complete-AgentTask $resolver.TaskDirectory 'fix: resolve' {}
Assert ([IO.File]::ReadAllText((Join-Path $hf.path 'base.txt')) -eq 'resolved version') 'Resolved handoff publishes code normally'

# Real simultaneous claims contend on one shared store; exactly one may acquire ownership.
$raceSource = Task $hf
[IO.File]::WriteAllText((Join-Path $raceSource.TaskDirectory 'PLAN.md'), '- [ ] race')
$null = Publish-AgentHandoff $raceSource.TaskDirectory
$r1 = Task $hf
$r2 = Task $hf
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
foreach ($pair in @(@('one', $r1.Repository), @('two', $r2.Repository))) {
    if ([IO.File]::ReadAllText((Join-Path $barrier "$($pair[0]).result")) -eq 'rejected') {
        Assert ([IO.File]::ReadAllText((Join-Path $barrier "$($pair[0]).error")) -match 'already claimed') 'Loser was rejected by ownership, not an incidental worker error'
        Assert (-not (Test-Path (Join-Path $pair[1] '.handoff/PLAN.md'))) 'Losing workspace never receives PLAN body'
    }
}

# Altered fetch or push targets are rejected before any network write.
$tf = New-Fixture 'tampered'
$tampered = Task $tf
$null = Jj $tampered.Repository @('git', 'remote', 'set-url', 'origin', '--push', 'https://github.com/other/repo')
Expect-Error { Publish-AgentHandoff $tampered.TaskDirectory } 'origin differs'
$null = Jj $tampered.Repository @('git', 'remote', 'set-url', 'origin', '--fetch', 'https://github.com/other/repo')
Expect-Error { Publish-AgentHandoff $tampered.TaskDirectory } 'origin differs'
Expect-Error { Task $tf } 'origin differs'

# Unrelated remote branches stop workflow without being changed or deleted.
$null = Jj $observer.Repository @('git', 'fetch', '--branch', 'main')
$null = Jj $observer.Repository @('bookmark', 'set', 'unrelated', '-r', 'main@origin')
$null = Jj $observer.Repository @('git', 'push', '--bookmark', 'unrelated')
Expect-Error { & $module { param($d) Assert-RemoteBranches $d } $observer.Repository } 'Unexpected remote branches'
Assert ([bool](Tip $observer.Repository 'unrelated')) 'Unrelated branch preserved'

# User-approved preservation is exact, task-scoped, read-only and checked after tests.
$pf = New-Fixture 'preserved'
$producer = Task $pf
[IO.File]::WriteAllText((Join-Path $producer.Repository 'legacy.txt'), 'legacy content, not approved for integration')
$null = Jj $producer.Repository @('describe', '-m', 'test: legacy branch')
$null = Jj $producer.Repository @('bookmark', 'set', 'quality-work/audit')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
$legacy = Tip $producer.Repository 'quality-work/audit'
Expect-Error { Task $pf } 'Unexpected remote branches'
Expect-Error { Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = ('0' * 40) } } 'changed or disappeared'
foreach ($approval in @(@{ main = $legacy }, @{ 'handoff/task' = $legacy }, @{ 'quality-work/*' = $legacy },
        @{ 'quality-work/audit' = $legacy.Substring(0,8) })) {
    Expect-Error { & $module { param($a) Assert-PreservedBranches $a } $approval } 'exact non-workflow branch'
}
$approved = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
Assert (-not (Test-Path (Join-Path $approved.Repository 'legacy.txt'))) 'Preservation never imports legacy content'
$approvalState = Get-Content (Join-Path $approved.TaskDirectory 'task.json') -Raw | ConvertFrom-Json
Assert ($approvalState.preservedBranches.'quality-work/audit' -eq $legacy) 'Exact approved tip recorded only in task metadata'
Expect-Error { & $module { param($s, $tip) Push-Branch $s 'quality-work/audit' $tip $tip } $approvalState $legacy } 'read-only'
[IO.File]::WriteAllText((Join-Path $approved.Repository 'normal.txt'), 'normal work')
$null = Complete-AgentTask $approved.TaskDirectory 'feat: work beside preserved branch' {}
Assert ((Tip $approved.Repository 'quality-work/audit') -eq $legacy) 'Normal main publication preserves legacy tip'
Assert (-not (Test-Path (Join-Path $pf.path 'legacy.txt'))) 'Registered checkout excludes legacy work'
Assert (-not (Test-Path (Join-Path $pf.path 'task.json'))) 'Approval metadata never reaches main'
Expect-Error { Task $pf } 'Unexpected remote branches'

$planned = Task $pf -Plan -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
Expect-Error { Complete-AgentTask $planned.TaskDirectory 'fix: not authorized' {} } 'plan phase'
$approvalSource = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $approvalSource.TaskDirectory 'PLAN.md'), '- [ ] finish independent work')
$null = Publish-AgentHandoff $approvalSource.TaskDirectory
$approvalOwner = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
$null = Receive-AgentHandoff $approvalOwner.TaskDirectory $approvalSource.TaskId
$null = Complete-AgentTask $approvalOwner.TaskDirectory 'chore: finish independent work' {}
Assert ((Tip $approvalOwner.Repository 'quality-work/audit') -eq $legacy) 'Handoff claim/completion/deletion never changes preserved branch'

$late = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $late.Repository 'late.txt'), 'candidate')
$beforeLate = Tip $late.Repository
$closureJj = { param($directory, $arguments) & $module { param($d, $a) Invoke-Jj $d $a } $directory $arguments }.GetNewClosure()
$lateTest = {
    $null = & $closureJj $producer.Repository @('bookmark', 'set', 'another-branch', '-r', 'main@origin')
    $null = & $closureJj $producer.Repository @('git', 'push', '--bookmark', 'another-branch')
}.GetNewClosure()
Expect-Error { Complete-AgentTask $late.TaskDirectory 'fix: late branch' $lateTest } 'Unexpected remote branches'
Assert ((Tip $late.Repository) -eq $beforeLate) 'New unapproved branch during tests blocks main publication'
$null = Jj $producer.Repository @('bookmark', 'delete', 'another-branch')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'another-branch')

$changed = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $legacy }
[IO.File]::WriteAllText((Join-Path $changed.Repository 'changed.txt'), 'candidate')
$beforeChanged = Tip $changed.Repository
$changeTest = {
    [IO.File]::WriteAllText((Join-Path $producer.Repository 'legacy.txt'), 'external update')
    $null = & $closureJj $producer.Repository @('describe', '-m', 'test: external legacy update')
    $null = & $closureJj $producer.Repository @('bookmark', 'set', 'quality-work/audit')
    $null = & $closureJj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
}.GetNewClosure()
Expect-Error { Complete-AgentTask $changed.TaskDirectory 'fix: changed approval' $changeTest } 'changed or disappeared'
Assert ((Tip $changed.Repository) -eq $beforeChanged) 'Changed approved tip during tests blocks main publication'
$externalTip = Tip $producer.Repository 'quality-work/audit'
Assert ($externalTip -ne $legacy) 'External branch update is preserved, not reset to approved tip'
$deleted = Task $pf -PreserveRemoteBranch @{ 'quality-work/audit' = $externalTip }
$null = Jj $producer.Repository @('bookmark', 'delete', 'quality-work/audit')
$null = Jj $producer.Repository @('git', 'push', '--bookmark', 'quality-work/audit')
Expect-Error { Complete-AgentTask $deleted.TaskDirectory 'fix: missing approval' {} } 'changed or disappeared'
Assert (-not (Tip $deleted.Repository 'quality-work/audit')) 'Externally deleted branch is not recreated'

# Canonical prefixes preserve their original ancestry and unrelated dirty work.
$cf = New-Fixture 'canonical-ingress'
$canonicalSeed = Tip $cf.path
[IO.File]::WriteAllText((Join-Path $cf.path 'prefix.txt'), 'prefix')
$null = Jj $cf.path @('describe', '-m', 'fix: canonical prefix')
$null = Jj $cf.path @('bookmark', 'set', 'main')
$prefix = (& $module { param($d) Get-CurrentId $d } $cf.path).Trim()
$null = Jj $cf.path @('new', $prefix)
[IO.File]::WriteAllText((Join-Path $cf.path 'unrelated.txt'), 'other owner')
$ct = Task $cf
$null = Complete-AgentCanonicalWork -TaskDirectory $ct.TaskDirectory -ExpectedMain $prefix -Message 'chore: validate prefix' -Test {
    if ([IO.File]::ReadAllText((Join-Path $PWD 'prefix.txt')) -ne 'prefix') { throw 'Prefix source missing' }
    if (Test-Path (Join-Path $PWD 'unrelated.txt')) { throw 'Unrelated dirty source was imported' }
}
Assert ((Tip $ct.Repository) -eq $prefix) 'Canonical prefix keeps the exact commit identity and ancestry'
Assert ([IO.File]::ReadAllText((Join-Path $cf.path 'unrelated.txt')) -eq 'other owner') 'Prefix ingress preserves unrelated dirty files'
Assert ((Get-Content (Join-Path $ct.TaskDirectory 'task.json') -Raw | ConvertFrom-Json).synchronized) 'Exact same canonical main is synchronized without restoring dirty work'

# Only an explicitly fingerprinted result is integrated.
[IO.File]::WriteAllText((Join-Path $cf.path 'result.txt'), 'observed output')
$resultHash = (Get-FileHash (Join-Path $cf.path 'result.txt')).Hash.ToLowerInvariant()
$rt = Task $cf
$null = Complete-AgentCanonicalWork -TaskDirectory $rt.TaskDirectory -ExpectedMain $prefix -ExpectedFiles @{ 'result.txt' = $resultHash } -Message 'chore: preserve observed result' -Test {
    if ([IO.File]::ReadAllText((Join-Path $PWD 'result.txt')) -ne 'observed output') { throw 'Wrong observed result' }
    if (Test-Path (Join-Path $PWD 'unrelated.txt')) { throw 'Unrelated source entered candidate' }
}
Assert ([IO.File]::ReadAllText((Join-Path $cf.path 'result.txt')) -eq 'observed output') 'Owned result source remains intact'
Assert ([IO.File]::ReadAllText((Join-Path $cf.path 'unrelated.txt')) -eq 'other owner') 'Owned result ingress preserves unrelated dirty source'
Assert ((Jj $cf.path @('diff', '--summary')) -notmatch 'result.txt') 'Owned result is committed, not left dirty'
$mainAfterResult = Tip $rt.Repository
Assert ((Jj $cf.path @('log', '-r', '@-', '--no-graph', '-T', 'commit_id')).Trim() -eq $mainAfterResult) 'Canonical result working-copy parent advances to published main'

$stale = Task $cf
Expect-Error { Complete-AgentCanonicalWork -TaskDirectory $stale.TaskDirectory -ExpectedMain $mainAfterResult -ExpectedFiles @{ 'result.txt' = ('a' * 64) } -Message 'chore: stale' -Test {} } 'Canonical file changed'
Assert ((Tip $stale.Repository) -eq $mainAfterResult) 'Stale fingerprint does not push'
$unsafe = Task $cf
Expect-Error { Complete-AgentCanonicalWork -TaskDirectory $unsafe.TaskDirectory -ExpectedMain $mainAfterResult -ExpectedFiles @{ '../secret' = ('a' * 64) } -Message 'chore: unsafe' -Test {} } 'safe relative'
Expect-Error { Complete-AgentCanonicalWork -TaskDirectory $unsafe.TaskDirectory -ExpectedMain $mainAfterResult -ExpectedFiles @{ '.env.local' = ('a' * 64) } -Message 'chore: unsafe' -Test {} } 'safe relative'
$beforeAdvance = Task $cf
$advanceTest = {
    [IO.File]::WriteAllText((Join-Path $cf.path 'result.txt'), 'other owner changed output')
}.GetNewClosure()
Expect-Error { Complete-AgentCanonicalWork -TaskDirectory $beforeAdvance.TaskDirectory -ExpectedMain $mainAfterResult -ExpectedFiles @{ 'result.txt' = $resultHash } -Message 'chore: raced' -Test $advanceTest } 'Canonical file changed'
Assert ((Tip $beforeAdvance.Repository) -eq $mainAfterResult) 'Concurrent owned-file changes stop publication'

# Concurrent canonical ingress follows registered-then-store lock order and never mixes inputs.
$ccf = New-Fixture 'canonical-concurrent'
$ccMain = Tip $ccf.path
$ccA = Task $ccf
$ccB = Task $ccf
[IO.File]::WriteAllText((Join-Path $ccf.path 'one.txt'), 'one owned input')
[IO.File]::WriteAllText((Join-Path $ccf.path 'two.txt'), 'two owned input')
$ccBarrier = Join-Path $root 'canonical-barrier'
$null = New-Item -ItemType Directory $ccBarrier
$ccJobs = @()
foreach ($pair in @(@('one', $ccA.TaskDirectory), @('two', $ccB.TaskDirectory))) {
    $hash = (Get-FileHash (Join-Path $ccf.path "$($pair[0]).txt")).Hash.ToLowerInvariant()
    $ccJobs += Start-Job -ArgumentList $modulePath, $pair[1], $ccMain, $hash, $ccBarrier, $pair[0] -ScriptBlock {
        param($modulePath, $task, $expectedMain, $hash, $barrier, $name)
        $ErrorActionPreference = 'Stop'
        Import-Module $modulePath -Force
        $validation = {
            if (-not (Test-Path "$name.txt")) { throw 'Missing owned canonical input' }
            $other = if ($name -eq 'one') { 'two' } else { 'one' }
            if (Test-Path "$other.txt") { throw 'Imported another task input' }
            [IO.File]::WriteAllText((Join-Path $barrier "$name.ready"), '')
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path (Join-Path $barrier 'go'))) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Canonical barrier timed out' }
                Start-Sleep -Milliseconds 25
            }
        }.GetNewClosure()
        try {
            $null = Complete-AgentCanonicalWork -TaskDirectory $task -ExpectedMain $expectedMain -Message "feat: canonical $name" -ExpectedFiles @{ "$name.txt" = $hash } -Test $validation
            [pscustomobject]@{ Name=$name; Status='published'; Error='' }
        } catch { [pscustomobject]@{ Name=$name; Status='rejected'; Error=$_.Exception.Message } }
    }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while (-not ((Test-Path (Join-Path $ccBarrier 'one.ready')) -and (Test-Path (Join-Path $ccBarrier 'two.ready')))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Concurrent canonical workers did not reach test barrier.' }
        Start-Sleep -Milliseconds 25
    }
    [IO.File]::WriteAllText((Join-Path $ccBarrier 'go'), '')
    $null = Wait-Job $ccJobs -Timeout 45
    Assert (@($ccJobs | Where-Object State -ne 'Completed').Count -eq 0) 'Concurrent canonical work finishes without lock inversion'
    $ccResults = @(Receive-Job $ccJobs -ErrorAction Stop)
    Assert (@($ccResults | Where-Object Status -eq 'published').Count -eq 1) 'One canonical candidate publishes'
    $ccLosers = @($ccResults | Where-Object Status -eq 'rejected')
    Assert ($ccLosers.Count -eq 1 -and $ccLosers[0].Error -match 'working-copy parent changed|outside the validated canonical prefix') 'Other canonical candidate stops on source/main advance'
    $publishedFiles = Jj $ccA.Repository @('file', 'list', '-r', 'main@origin')
    $winnerName = ($ccResults | Where-Object Status -eq 'published').Name
    Assert ($publishedFiles -match "$winnerName.txt" -and $publishedFiles -notmatch "$($ccLosers[0].Name).txt") 'Main includes only the winning canonical input'
    Assert ((Jj $ccA.Repository @('git', 'remote', 'list')) -notmatch '(?m)^canonical\s') 'Shared canonical remote is removed after both imports'
    Assert ([IO.File]::ReadAllText((Join-Path $ccf.path 'one.txt')) -eq 'one owned input' -and [IO.File]::ReadAllText((Join-Path $ccf.path 'two.txt')) -eq 'two owned input') 'Both canonical source files survive the race'
} finally { Remove-Job $ccJobs -Force }

# Task path validation protects every operation, not just removal.
Expect-Error { & $module { Read-Task 'C:/dev/tmp' } } 'direct child'
$linkRoot = Join-Path 'C:/dev/tmp' ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Junction -Path $linkRoot -Target $b.TaskDirectory
Expect-Error { & $module { param($d) Read-Task $d } $linkRoot } 'link or junction'
Assert (Test-Path $b.TaskDirectory) 'Link rejection preserved target'

Assert (-not $module.ExportedCommands.ContainsKey('Remove-AgentTask')) 'Workflow exports no temporary-folder removal command'
Assert ((Get-AgentWorkflowHelp) -notmatch 'Remove-AgentTask|ResearchComplete') 'Help contains no cleanup procedure'
Assert ((Get-AgentWorkflowHelp) -match 'C:/dev/tmp/<id>/' -and (Get-AgentWorkflowHelp) -notmatch '-Name|<owner>--|8 random') 'Help describes GUID-only task creation'
foreach ($path in @('repository', 'task.json', 'test.log')) {
    Assert (Test-Path (Join-Path $winner.TaskDirectory $path)) 'Handoff completion retains local artifacts'
}
"PASS: $script:Checks checks; local-only fixtures retained at $root."
