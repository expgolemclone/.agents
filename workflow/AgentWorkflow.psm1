#requires -Version 7.4
Set-StrictMode -Version Latest
$script:TmpRoot = 'C:/dev/tmp'
$script:HandoffPath = '.handoff/PLAN.md'
$script:Marker = 'agent-workflow/v1'

function Get-JjRepositoryPath {
    param([string]$Directory)
    $path = Join-Path ([IO.Path]::GetFullPath($Directory)) '.jj/repo'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $path = [IO.Path]::GetFullPath([IO.File]::ReadAllText($path).Trim(), (Split-Path $path -Parent))
    }
    return $path
}

function Invoke-RepositoryTransaction {
    param([string]$Directory, [scriptblock]$Action)
    Invoke-AgentRepositoryLock -RepositoryPath (Get-JjRepositoryPath $Directory) -Action $Action
}

function Invoke-Jj {
    param([string]$Directory, [string[]]$Arguments)
    # The lock is shared by every workspace, including read commands that snapshot or import refs.
    Invoke-RepositoryTransaction $Directory { Invoke-JjProcess $Directory $Arguments }
}

function Invoke-JjProcess {
    param([string]$Directory, [string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new('jj')
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in @('--no-pager', '--color', 'never', '--quiet') + $Arguments) {
        $info.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timeout = 300000
        if (-not $process.WaitForExit($timeout)) {
            if (-not $process.HasExited) { $process.Kill($true) }
            $process.WaitForExit()
            throw "jj $($Arguments[0]) timed out in $Directory after $($timeout / 1000) seconds."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "jj $($Arguments[0]) failed in ${Directory}: $($errorText.Trim())"
        }
        return $output
    } finally { $process.Dispose() }
}

function Get-CurrentId {
    param([string]$Directory)
    $id = (Invoke-Jj $Directory @('log', '-r', '@', '--no-graph', '-T', 'commit_id')).Trim()
    if ($id -notmatch '^[0-9a-f]{40,64}$') { throw 'Invalid current workspace commit.' }
    return $id
}

function Get-RemoteTip {
    param([string]$Directory, [string]$Branch)
    $text = Invoke-Jj $Directory @('bookmark', 'list', '--remote', 'origin', "exact:$Branch", '-T',
        'if(remote == "origin", if(conflict, "conflict", normal_target.commit_id()) ++ "\n")')
    $tip = $text.Trim()
    if ($tip -and $tip -notmatch '^[0-9a-f]{40,64}$') { throw "Conflicted remote branch: $Branch" }
    return $tip
}

function Fetch-Branch {
    param([string]$Directory, [string]$Branch)
    $null = Invoke-Jj $Directory @('git', 'fetch', '--remote', 'origin', '--branch', "exact:$Branch")
}

function Assert-PreservedBranches {
    param([Collections.IDictionary]$Branches)
    foreach ($branch in $Branches.Keys) {
        if ($branch -isnot [string] -or $branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
            $branch -match '\.\.|//|/$' -or $branch -ieq 'main' -or $branch -imatch '^handoff/' -or
            $Branches[$branch] -isnot [string] -or $Branches[$branch] -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
            throw 'Preservation requires an exact non-workflow branch name and full lowercase tip approved by the user.'
        }
    }
}

function Assert-TaskBranches {
    param($State)
    $branches = @{}
    # Approval is optional task metadata, never inferred from remote refs.
    $approval = $State.PSObject.Properties['preservedBranches']
    if ($approval) {
        foreach ($property in $approval.Value.PSObject.Properties) { $branches[$property.Name] = $property.Value }
    }
    Assert-RemoteBranches (Join-Path $State.path 'repository') $branches
}

function Assert-RemoteBranches {
    param([string]$Directory, [Collections.IDictionary]$PreservedBranches = @{})
    Invoke-RepositoryTransaction $Directory {
        Assert-PreservedBranches $PreservedBranches
        $null = Invoke-Jj $Directory @('git', 'fetch', '--remote', 'origin', '--branch', '*')
        $names = (Invoke-Jj $Directory @('bookmark', 'list', '--remote', 'origin', '-T',
            'if(remote == "origin", name ++ "\n")')) -split '\r?\n' | Where-Object { $_ }
        $unexpected = @($names | Where-Object { $_ -cne 'main' -and $_ -cnotmatch '^handoff/[a-z0-9-]+$' -and
            $_ -cnotin @($PreservedBranches.Keys) })
        if ($unexpected.Count) { throw "Unexpected remote branches; ask before changing them: $($unexpected -join ', ')" }
        foreach ($branch in $PreservedBranches.Keys) {
            if ((Get-RemoteTip $Directory $branch) -cne $PreservedBranches[$branch]) {
                throw "Preserved branch changed or disappeared; ask for new approval: $branch"
            }
        }
    }
}

function Assert-PushAllowed {
    param([string]$Remote)
    if ($Remote -match '^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)expgolemclone/[^/]+?/?$') { return }
    # Disposable local remotes used by the integration tests never leave the tmp sandbox.
    if (Test-Path -LiteralPath $Remote) {
        $path = [IO.Path]::GetFullPath($Remote)
        if ($path.StartsWith([IO.Path]::GetFullPath($script:TmpRoot) + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    throw 'Push is allowed only to expgolemclone repositories or local tmp test remotes.'
}

function Resolve-Repository {
    param([string]$Repository)
    Import-Module "$HOME/local-repository-map/RepositoryMap.psm1" -ErrorAction Stop
    $entries = @((Read-LocalRepositoryMap).repositories | Where-Object repository -eq $Repository)
    if ($entries.Count -ne 1 -or -not $entries[0].remote) { throw 'A unique mapped repository with a remote is required.' }
    if (-not (Test-AgentRepositoryPathAllowed $entries[0].path)) { throw 'Box repositories are not supported.' }
    return $entries[0]
}

function Assert-SafeTaskPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($script:TmpRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($full) -ne $root) { throw 'Task must be a direct child of C:/dev/tmp.' }
    $item = Get-Item -LiteralPath $full -ErrorAction Stop
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Task path crosses a link or junction.' }
        $item = $item.Parent
    }
    return $full
}

function Save-Task {
    param($State)
    $path = Join-Path $State.path 'task.json'
    $pending = "$path.pending"
    [IO.File]::WriteAllText($pending, ($State | ConvertTo-Json -Depth 12) + "`n")
    [IO.File]::Move($pending, $path, $true)
}

function Read-Task {
    param([string]$TaskDirectory)
    $path = Assert-SafeTaskPath $TaskDirectory
    $state = [IO.File]::ReadAllText((Join-Path $path 'task.json')) | ConvertFrom-Json
    if ($state.marker -ne $script:Marker -or $state.path -ne $path -or $state.taskId -notmatch '^[a-z0-9-]+$') {
        throw 'Invalid task identity.'
    }
    $null = Assert-SafeTaskPath $state.path
    return $state
}

function Assert-Origin {
    param([string]$Directory, [string]$Expected)
    $remotes = Invoke-Jj $Directory @('git', 'remote', 'list')
    $match = [regex]::Match($remotes, '(?m)^origin\s+([^\r\n]+)\r?$')
    if (-not $match.Success) { throw 'Task origin is missing.' }
    $actual = $match.Groups[1].Value
    if ($actual -match ' \(push:') { throw 'Task origin differs from its mapped remote. Stop before publishing.' }
    if ([IO.Path]::IsPathFullyQualified($expected)) {
        if (-not [IO.Path]::IsPathFullyQualified($actual)) { throw 'Task origin differs from its mapped remote. Stop before publishing.' }
        $actual = [IO.Path]::GetFullPath($actual)
        $expected = [IO.Path]::GetFullPath($expected)
    }
    if ($actual -ne $Expected) { throw 'Task origin differs from its mapped remote. Stop before publishing.' }
}

function Assert-Execute {
    param($State)
    if ($State.phase -ne 'execute') { throw 'This task is in plan phase. Explicit user do authorization is required.' }
    Assert-PushAllowed $State.remote
    Assert-Origin (Join-Path $State.path 'repository') $State.remote
    Assert-TaskBranches $State
}

function New-Task {
    param($Entry, [switch]$Execute, [Collections.IDictionary]$PreserveRemoteBranch = @{})
    Assert-PreservedBranches $PreserveRemoteBranch
    if ($Entry.repository -cnotmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw 'Repository must be owner/repo with filesystem-safe names.' }
    $id = [guid]::NewGuid().ToString('N')
    $path = Join-Path $script:TmpRoot $id
    $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
    $path = Assert-SafeTaskPath $path
    $state = [pscustomobject]@{
        marker = $script:Marker; path = $path; taskId = $id
        remote = [string]$Entry.remote; registeredPath = [IO.Path]::GetFullPath($Entry.path)
        phase = $(if ($Execute) { 'execute' } else { 'plan' })
        base = ''; branch = ''; owner = $null; branchTip = ''
        candidate = ''; candidateChange = ''; candidateBase = ''; published = ''; branchDeleted = $false; synchronized = $false
    }
    if ($PreserveRemoteBranch.Count) {
        $state | Add-Member -NotePropertyName preservedBranches -NotePropertyValue ([pscustomobject]$PreserveRemoteBranch)
    }
    $repo = Join-Path $path 'repository'
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($state.remote))).ToLowerInvariant()
    $store = Join-Path $script:TmpRoot "task-stores/$key"
    Invoke-RepositoryTransaction $store {
        # Never use a link/junction or the user's registered repository as the task store.
        $item = [IO.DirectoryInfo]::new($store)
        while ($null -ne $item) {
            if ($item.Exists -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Task store crosses a link or junction.' }
            $item = $item.Parent
        }
        if (-not (Test-Path -LiteralPath $store)) {
            $null = [IO.Directory]::CreateDirectory((Split-Path $store -Parent))
            $null = Invoke-Jj $path @('git', 'init', '--no-colocate', $store)
            $null = Invoke-Jj $store @('sparse', 'set', '--clear')
            $null = Invoke-Jj $store @('config', 'set', '--repo', 'git.abandon-unreachable-commits', 'false')
            $null = Invoke-Jj $store @('git', 'remote', 'add', 'origin', $state.remote)
        }
        Assert-Origin $store $state.remote
        Assert-RemoteBranches $store $PreserveRemoteBranch
        $state.base = Get-RemoteTip $store 'main'
        if (-not $state.base) { throw 'Remote main is required.' }
        $null = Invoke-Jj $store @('bookmark', 'track', 'main@origin')
        $null = Invoke-Jj $store @('workspace', 'add', '--name', $id, '--sparse-patterns', 'full', '-r', $state.base, $repo)
        Save-Task $state
    }
    return [pscustomobject]@{ TaskDirectory = $path; Repository = $repo; Phase = $state.phase; TaskId = $id }
}

function Start-AgentTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository, [switch]$Execute,
        [Collections.IDictionary]$PreserveRemoteBranch = @{})
    New-Task (Resolve-Repository $Repository) -Execute:$Execute -PreserveRemoteBranch $PreserveRemoteBranch
}

function Enable-AgentTaskExecution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [Parameter(Mandatory)][switch]$Doit)
    if (-not $Doit) { throw 'Explicit user do authorization is required.' }
    $state = Read-Task $TaskDirectory
    $state.phase = 'execute'
    Save-Task $state
    [pscustomobject]@{ TaskDirectory = $state.path; Phase = $state.phase }
}

function Read-Handoff {
    param([string]$Directory, [string]$Tip, [string]$TaskId)
    $text = Invoke-Jj $Directory @('file', 'show', '-r', $Tip, $script:HandoffPath)
    $match = [regex]::Match($text, '\A---\r?\n([^\r\n]+)\r?\n---\r?\n')
    if (-not $match.Success) { throw "Invalid handoff header: $TaskId" }
    $meta = $match.Groups[1].Value | ConvertFrom-Json
    if ($meta.schema -ne 1 -or $meta.taskId -ne $TaskId -or $meta.base -notmatch '^[0-9a-f]{40,64}$' -or $meta.phase -ne 'execute') {
        throw "Invalid handoff identity: $TaskId"
    }
    return [pscustomobject]@{ Meta = $meta; Body = $text.Substring($match.Length) }
}

function Write-Handoff {
    param([string]$Directory, $Meta, [string]$Body)
    $path = Join-Path $Directory $script:HandoffPath
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -ErrorAction Stop -Force
    [IO.File]::WriteAllText($path, "---`n$($Meta | ConvertTo-Json -Depth 8 -Compress)`n---`n$Body")
    # Some repositories ignore new directories globally. Track this one explicitly.
    $null = Invoke-Jj $Directory @('file', 'track', '--include-ignored', $script:HandoffPath)
}

function Get-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
    $repo = Join-Path $state.path 'repository'
    Invoke-RepositoryTransaction $repo {
        Assert-Origin $repo $state.remote
        $null = Invoke-Jj $repo @('git', 'fetch', '--remote', 'origin', '--branch', 'handoff/*')
        $names = (Invoke-Jj $repo @('bookmark', 'list', '--remote', 'origin', 'handoff/*', '-T',
            'if(remote == "origin", name ++ "\n")')) -split '\r?\n' | Where-Object { $_ }
        foreach ($branch in $names) {
            $id = $branch.Substring('handoff/'.Length)
            if ($id -notmatch '^[a-z0-9-]+$') { continue }
            $record = Read-Handoff $repo (Get-RemoteTip $repo $branch) $id
            # Only explicit unowned handoffs are available. No process/crash monitoring.
            if ($null -eq $record.Meta.owner) { [pscustomobject]@{ TaskId = $id } }
        }
    }
}

function Push-Branch {
    param($State, [string]$Branch, [string]$Revision, [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedTip)
    Invoke-RepositoryTransaction (Join-Path $State.path 'repository') {
        if ($Branch -cne 'main' -and $Branch -cnotmatch '^handoff/[a-z0-9-]+$') {
            throw 'Only main and handoff refs can be push targets; preserved refs are read-only.'
        }
        Assert-Execute $State
        $Directory = Join-Path $State.path 'repository'
        if ((Get-RemoteTip $Directory $Branch) -cne $ExpectedTip) { throw "Remote branch changed before publication: $Branch" }
        if ($ExpectedTip) {
            # Reset only the local reference, never the saved changes or expected remote tip.
            $null = Invoke-Jj $Directory @('bookmark', 'forget', "exact:$Branch")
            $null = Invoke-Jj $Directory @('bookmark', 'track', "$Branch@origin")
        }
        $null = Invoke-Jj $Directory @('bookmark', 'set', $Branch, '-r', $Revision)
        $args = @('git', 'push', '--remote', 'origin', '--bookmark', "exact:$Branch")
        # Unfinished handoffs may contain conflicts; main never gets this permission.
        if ($Branch.StartsWith('handoff/')) { $args += '--allow-conflicts' }
        $null = Invoke-Jj $Directory $args
    }
}

function Publish-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
    Invoke-RepositoryTransaction (Join-Path $state.path 'repository') {
        Assert-Execute $state
        if ($state.branch -or $state.published) { throw 'Use Unlock-AgentHandoff for a claimed task; already-published code cannot be handed off.' }
        $repo = Join-Path $state.path 'repository'
        $plan = Join-Path $state.path 'PLAN.md'
        if (-not (Test-Path -LiteralPath $plan)) { throw 'A PLAN.md with remaining work and blockers is required.' }
        $branch = "handoff/$($state.taskId)"
        Fetch-Branch $repo $branch
        if (Get-RemoteTip $repo $branch) { throw 'Handoff branch already exists; inspect the previous publication.' }
        $base = if ($state.candidate) { $state.candidateBase } else { $state.base }
        if ($base -notmatch '^[0-9a-f]{40,64}$') { throw 'Task base is missing.' }
        $meta = [pscustomobject]@{ schema = 1; taskId = $state.taskId; base = $base; phase = 'execute'; owner = $null }
        $source = Get-CurrentId $repo
        $null = Invoke-Jj $repo @('new', $base, '-m', "wip: handoff $($state.taskId)")
        $null = Invoke-Jj $repo @('restore', '--from', $source, '~root:.handoff')
        Write-Handoff $repo $meta ([IO.File]::ReadAllText($plan))
        $tip = Get-CurrentId $repo
        Push-Branch $state $branch $tip ''
        $state.branch = $branch; $state.branchTip = $tip; $state.base = $base
        $state.candidate = ''; $state.candidateChange = ''; $state.candidateBase = ''
        Save-Task $state
        Remove-Item -LiteralPath $plan -ErrorAction Stop
        [pscustomobject]@{ TaskId = $state.taskId; Status = 'Available' }
    }
}

function Receive-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [Parameter(Mandatory)][string]$TaskId)
    $state = Read-Task $TaskDirectory
    Invoke-RepositoryTransaction (Join-Path $state.path 'repository') {
        Assert-Execute $state
        if ($TaskId -notmatch '^[a-z0-9-]+$') { throw 'Invalid task ID.' }
        if ($state.branch -or $state.candidate -or $state.published) { throw 'Use a fresh task workspace to claim a handoff.' }
        $repo = Join-Path $state.path 'repository'
        if ((Invoke-Jj $repo @('diff', '--from', $state.base, '--to', '@', '--summary')).Trim()) {
            throw 'Claim requires an unchanged task workspace.'
        }
        $branch = "handoff/$TaskId"
        Fetch-Branch $repo $branch
        $tip = Get-RemoteTip $repo $branch
        if (-not $tip) { throw 'Handoff no longer exists.' }
        $record = Read-Handoff $repo $tip $TaskId
        if ($null -ne $record.Meta.owner) { throw 'Handoff is already claimed. PLAN body was not exposed.' }
        $owner = [pscustomobject]@{ token = [guid]::NewGuid().ToString('N') }
        $null = Invoke-Jj $repo @('new', $tip, '-m', "chore: claim handoff $TaskId")
        $record.Meta.owner = $owner
        Write-Handoff $repo $record.Meta $record.Body
        $claim = Get-CurrentId $repo
        # Freeze the observed tip, not the shared remote bookmark that a peer could refresh.
        Push-Branch $state $branch $claim $tip
        $state.taskId = $TaskId; $state.base = $record.Meta.base; $state.branch = $branch
        $state.owner = $owner; $state.branchTip = $claim
        Save-Task $state
        [pscustomobject]@{ TaskId = $TaskId; PlanPath = Join-Path $repo $script:HandoffPath; Plan = $record.Body }
    }
}

function Assert-Owned {
    param($State, [string]$Directory)
    Invoke-RepositoryTransaction $Directory {
        if (-not $State.branch -or $null -eq $State.owner) { throw 'Task does not own a handoff.' }
        Fetch-Branch $Directory $State.branch
        $tip = Get-RemoteTip $Directory $State.branch
        if ($tip -ne $State.branchTip) { throw 'Handoff changed remotely. Stop; do not retry ownership automatically.' }
        $record = Read-Handoff $Directory $tip $State.taskId
        if ($null -eq $record.Meta.owner -or $record.Meta.owner.token -ne $State.owner.token) { throw 'Handoff ownership lost.' }
        return $record
    }
}

function Unlock-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
    Invoke-RepositoryTransaction (Join-Path $state.path 'repository') {
        Assert-Execute $state
        if ($state.published) { throw 'Finish post-push steps instead of releasing.' }
        $repo = Join-Path $state.path 'repository'
        $owned = Assert-Owned $state $repo
        $fromCandidate = [bool]$state.candidate
        if ($fromCandidate) {
            $record = $owned
            $record.Body = [IO.File]::ReadAllText((Join-Path $state.path 'PLAN.md'))
        } else {
            $record = Read-Handoff $repo (Get-CurrentId $repo) $state.taskId
        }
        if ($record.Meta.owner.token -ne $state.owner.token) { throw 'Local ownership header was changed.' }
        $record.Meta.owner = $null
        if ($fromCandidate) { $record.Meta.base = $state.candidateBase }
        $source = Get-CurrentId $repo
        # Publish one described descendant, not the working copy's incidental ancestry.
        $null = Invoke-Jj $repo @('new', $state.branchTip, '-m', "wip: release handoff $($state.taskId)")
        $null = Invoke-Jj $repo @('restore', '--from', $source, '~root:.handoff')
        Write-Handoff $repo $record.Meta $record.Body
        $tip = Get-CurrentId $repo
        Push-Branch $state $state.branch $tip $state.branchTip
        $state.owner = $null; $state.branchTip = $tip; $state.base = $record.Meta.base
        $state.candidate = ''; $state.candidateChange = ''; $state.candidateBase = ''
        Save-Task $state
        if ($fromCandidate) { Remove-Item -LiteralPath (Join-Path $state.path 'PLAN.md') -ErrorAction Stop }
        [pscustomobject]@{ TaskId = $state.taskId; Status = 'Available' }
    }
}

function Assert-NoConflicts {
    param([string]$Directory)
    $conflicts = Invoke-Jj $Directory @('file', 'list', '-T', 'if(conflict, path ++ "\n")')
    if ($conflicts.Trim()) { throw 'Resolve task conflicts before publishing.' }
}

function Invoke-TaskTest {
    param($State, [scriptblock]$Test)
    $repo = Join-Path $State.path 'repository'
    $before = Get-CurrentId $repo
    $lines = [Collections.Generic.List[string]]::new()
    $ErrorActionPreference = 'Stop'
    Push-Location $repo
    try {
        $global:LASTEXITCODE = 0
        & $Test *>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) { throw $_ }
            $lines.Add($_.ToString())
        }
        if ($LASTEXITCODE -ne 0) { throw "Test exited with code $LASTEXITCODE." }
    } catch {
        $lines.Add($_.Exception.Message)
        throw "Test failed. Task retained at $($State.path). See test.log."
    } finally {
        [IO.File]::WriteAllLines((Join-Path $State.path 'test.log'), $lines)
        Pop-Location
    }
    if ((Get-CurrentId $repo) -ne $before) { throw 'Tests changed tracked files. Review changes and retry explicitly.' }
}

function Test-Published {
    param([string]$Directory, [string]$Commit)
    # A current-reference predicate, not a history listing.
    $result = Invoke-Jj $Directory @('bookmark', 'list', '--remote', 'origin', 'exact:main', '-T',
        ('if(remote == "origin", if(normal_target.contained_in("' + $Commit + '::"), "yes"))'))
    return $result.Trim() -eq 'yes'
}

function Test-AgentRepositoryPathAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $path = [IO.Path]::GetFullPath($RepositoryPath)
    return $path -notmatch '(?i)[\\/]box(?:[\\/]|$)|[\\/]box_projects(?:[\\/]|$)'
}

function Invoke-AgentRepositoryLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 60
    )
    $mutexPath = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\', '/')
    if (-not (Test-AgentRepositoryPathAllowed $mutexPath)) { throw 'Box repositories are not supported.' }
    $mutexHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($mutexPath.ToLowerInvariant())))
    $mutex = [Threading.Mutex]::new($false, "Global\AgentRepoSync-$mutexHash")
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Registered repository synchronization is busy.' }
        & $Action
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Sync-RegisteredRepository {
    param([string]$RepositoryPath, [string]$ExpectedRemote)
    $registered = $RepositoryPath
    if (-not (Test-Path -LiteralPath (Join-Path $registered '.jj') -PathType Container)) {
        throw 'Local repository is not managed by jj.'
    }
    Assert-Origin $registered $ExpectedRemote
    $names = (Invoke-Jj $registered @('--ignore-working-copy', 'bookmark', 'list', '-T', 'name ++ "\n"')) -split '\r?\n' |
        Where-Object { $_ } | Sort-Object -Unique
    $unexpected = @($names | Where-Object { $_ -cne 'main' -and $_ -cnotmatch '^handoff/[a-z0-9-]+$' })
    if ($unexpected.Count) { throw "Unexpected bookmarks; ask before changing them: $($unexpected -join ', ')" }
    if ((Invoke-Jj $registered @('diff', '--summary')).Trim()) { throw 'Registered repository has changes; synchronization stopped.' }
    $before = Invoke-Jj $registered @('bookmark', 'list', 'exact:main', '-T', 'if(!remote, normal_target.commit_id())')
    if (-not $before.Trim()) { throw 'Registered local main is missing or conflicted.' }
    Fetch-Branch $registered 'main'
    if ((Invoke-Jj $registered @('diff', '--summary')).Trim()) { throw 'Registered repository changed during fetch.' }
    $tip = Get-RemoteTip $registered 'main'
    # Local unpublished ancestors must not be silently discarded.
    $safe = Invoke-Jj $registered @('bookmark', 'list', '--remote', 'origin', 'exact:main', '-T',
        ('if(remote == "origin", if(normal_target.contained_in("' + $before.Trim() + '::"), "yes"))'))
    if ($safe.Trim() -ne 'yes') { throw 'Registered main has unpublished or divergent work.' }
    # Safe workspaces emit nothing; any unpublished workspace or parent blocks synchronization.
    $unpublished = Invoke-Jj $registered @('workspace', 'list', '-T',
        'if(!target.contained_in("::main@origin"), if(target.empty() && !target.description(), target.parents().map(|p| if(!p.contained_in("::main@origin"), "no")).join(""), "no"))')
    if ($unpublished.Trim()) { throw 'Registered working copy contains unpublished work.' }
    $parent = (Invoke-Jj $registered @('log', '-r', '@-', '--no-graph', '-T', 'commit_id')).Trim()
    if ($parent -ne $tip) { $null = Invoke-Jj $registered @('new', $tip) }
    $null = Invoke-Jj $registered @('bookmark', 'set', 'main', '-r', $tip)
    if ((Invoke-Jj $registered @('diff', '--from', $tip, '--to', '@', '--summary')).Trim()) {
        throw 'Registered checkout differs from main; synchronization stopped.'
    }

    return [pscustomobject]@{ Status = 'Synchronized'; Main = $tip }
}

function Sync-AgentRegisteredRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$ExpectedRemote
    )
    Invoke-AgentRepositoryLock -RepositoryPath $RepositoryPath -Action {
        Sync-RegisteredRepository -RepositoryPath $RepositoryPath -ExpectedRemote $ExpectedRemote
    }
}

function Write-AgentRepositorySyncEvent {
    param([string]$LogPath, [hashtable]$Event)
    $record = [ordered]@{ at = (Get-Date).ToString('o') }
    foreach ($key in $Event.Keys) { $record[$key] = $Event[$key] }
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ($record | ConvertTo-Json -Depth 8 -Compress)
}

function Sync-AgentRepositoryMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogPath)
    Write-AgentRepositorySyncEvent $LogPath @{ type = 'start'; computer = $env:COMPUTERNAME }
    $problems = 0
    try {
        Import-Module "$HOME/local-repository-map/RepositoryMap.psm1" -ErrorAction Stop
        $map = Read-LocalRepositoryMap
        Write-AgentRepositorySyncEvent $LogPath @{ type = 'profile'; profile = $map.ProfileName; map = $map.MapPath }
        foreach ($entry in @($map.repositories | Where-Object { $_.remote })) {
            $event = @{ type = 'repository'; repository = $entry.repository; path = $entry.path; status = 'excluded'; reason = 'Box policy prohibits VCS operations.' }
            if (Test-AgentRepositoryPathAllowed -RepositoryPath $entry.path) {
                try {
                    $result = Sync-AgentRegisteredRepository -RepositoryPath $entry.path -ExpectedRemote $entry.remote
                    $event.status = 'synchronized'
                    $event.reason = 'Registered checkout matches origin/main.'
                    $event.remote = $result.Main
                } catch {
                    $event.status = 'failed'
                    $event.reason = $_.Exception.Message
                    $problems++
                }
            }
            Write-AgentRepositorySyncEvent $LogPath $event
        }
    } catch {
        Write-AgentRepositorySyncEvent $LogPath @{ type = 'fatal'; status = 'failed'; reason = $_.Exception.Message }
        $problems++
    }
    Write-AgentRepositorySyncEvent $LogPath @{ type = 'finish'; problems = $problems }
    return $problems
}

function Sync-AgentRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
    Assert-Execute $state
    if (-not $state.published) { throw 'Main publication must be confirmed before synchronization.' }
    $registered = $state.registeredPath
    Invoke-AgentRepositoryLock -RepositoryPath $registered -Action {
        Assert-Origin $registered $state.remote
        $ingress = $state.PSObject.Properties['canonicalWork']
        if ($ingress) {
            $expected = $ingress.Value
            $main = (Invoke-Jj $registered @('log', '-r', 'main', '--no-graph', '-T', 'commit_id')).Trim()
            $parent = (Invoke-Jj $registered @('log', '-r', '@-', '--no-graph', '-T', 'commit_id')).Trim()
            if ($main -ne $expected.main -or $parent -ne $expected.main) { throw 'Canonical ingress source changed before synchronization.' }
            foreach ($property in $expected.files.PSObject.Properties) {
                $path = Join-Path $registered $property.Name
                if ($null -eq $property.Value) {
                    if (Test-Path -LiteralPath $path) { throw 'Canonical ingress file changed before synchronization.' }
                } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $property.Value) {
                    throw 'Canonical ingress file changed before synchronization.'
                }
            }
            Fetch-Branch $registered 'main'
            if ((Get-RemoteTip $registered 'main') -ne $state.published) { throw 'Canonical ingress publication changed before synchronization.' }
            if (@($expected.files.PSObject.Properties).Count) {
                $null = Invoke-Jj $registered @('rebase', '-r', '@', '-o', $state.published)
                Assert-NoConflicts $registered
                $null = Invoke-Jj $registered @('bookmark', 'set', 'main', '-r', $state.published)
            }
            $state.synchronized = $true
            Save-Task $state
            return [pscustomobject]@{ Status = 'Synchronized'; Main = $state.published }
        }
        $sync = Sync-RegisteredRepository -RepositoryPath $registered -ExpectedRemote $state.remote
        $tip = $sync.Main
        $state.synchronized = $true
        Save-Task $state
        [pscustomobject]@{ Status = 'Synchronized'; Main = $tip }
    }
}

function Complete-AgentCanonicalWork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40,64}$')][string]$ExpectedMain,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$Test,
        [Collections.IDictionary]$ExpectedFiles = @{}
    )
    $state = Read-Task $TaskDirectory
    Assert-Execute $state
    if ($state.published) { return Sync-AgentRepository -TaskDirectory $TaskDirectory }
    if ($state.candidate -and $state.PSObject.Properties['canonicalWork']) {
        Fetch-Branch (Join-Path $state.path 'repository') 'main'
        if (Test-Published (Join-Path $state.path 'repository') $state.candidate) {
            $state.published = $state.candidate; Save-Task $state
            return Sync-AgentRepository -TaskDirectory $TaskDirectory
        }
        throw 'Canonical candidate is retained but publication is not confirmed; inspect exact remote tip before retrying.'
    }
    if ($state.branch -or $state.candidate) { throw 'Canonical ingress requires a fresh, unpublished task.' }
    if ($Message -notmatch '^[a-z]+(?:\([^)]+\))?!?: .+') { throw 'A Conventional Commit message is required.' }
    $repo = Join-Path $state.path 'repository'
    if ((Invoke-Jj $repo @('diff', '--from', $state.base, '--to', '@', '--summary')).Trim()) { throw 'Canonical ingress requires an unchanged task.' }
    $registered = $state.registeredPath
    $files = @{}
    foreach ($path in $ExpectedFiles.Keys) {
        if ($path -isnot [string] -or $path -match '(^/|[:\r\n]|\\|(^|/)\.\.?(/|$)|(^|/)\.(git|jj|state|cache|env|handoff)(/|\.|$))' -or
            [IO.Path]::IsPathRooted($path) -or $path.Split('/') -contains '' -or
            ($null -ne $ExpectedFiles[$path] -and $ExpectedFiles[$path] -cnotmatch '^[0-9a-f]{64}$')) {
            throw 'Ingress requires safe relative file paths and exact SHA256 or null for deletion.'
        }
        $files[$path] = $ExpectedFiles[$path]
    }
    function Assert-CanonicalInput {
        $main = (Invoke-Jj $registered @('log', '-r', 'main', '--no-graph', '-T', 'commit_id')).Trim()
        $parent = (Invoke-Jj $registered @('log', '-r', '@-', '--no-graph', '-T', 'commit_id')).Trim()
        if ($main -ne $ExpectedMain -or $parent -ne $ExpectedMain) { throw 'Canonical main or working-copy parent changed; preserve work and inspect ownership.' }
        foreach ($path in $files.Keys) {
            $full = Join-Path $registered $path
            $item = if (Test-Path -LiteralPath $full) { Get-Item -LiteralPath $full -Force } else { $null }
            if ($null -eq $files[$path]) {
                if ($item) { throw "Canonical file changed: $path" }
                continue
            }
            if (-not $item -or $item.PSIsContainer) { throw "Canonical file changed: $path" }
            $ancestor = $item
            while ($ancestor -and $ancestor.FullName -ne $registered) {
                if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Ingress refuses links or junctions.' }
                $ancestor = if ($ancestor -is [IO.FileInfo]) { $ancestor.Directory } else { $ancestor.Parent }
            }
            $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -cne $files[$path]) { throw "Canonical file changed: $path" }
        }
    }
    Invoke-AgentRepositoryLock -RepositoryPath $registered -Action {
        Assert-Origin $registered $state.remote
        Assert-CanonicalInput
        $null = Invoke-Jj $registered @('git', 'export')
        $backend = Join-Path $registered '.git'
        if (-not (Test-Path -LiteralPath $backend -PathType Container)) { $backend = Join-Path $registered '.jj/repo/store/git' }
        # Lock order is registered source, then task store; never sync registration under the store lock.
        Invoke-RepositoryTransaction $repo {
            Assert-Origin $repo $state.remote
            $null = Invoke-Jj $repo @('git', 'remote', 'add', 'canonical', $backend)
            try { $null = Invoke-Jj $repo @('git', 'fetch', '--remote', 'canonical', '--branch', 'main') }
            finally { $null = Invoke-Jj $repo @('git', 'remote', 'remove', 'canonical') }
            Fetch-Branch $repo 'main'
            $remote = Get-RemoteTip $repo 'main'
            $ancestor = (Invoke-Jj $repo @('log', '-r', "$remote & ::$ExpectedMain", '--no-graph', '-T', 'commit_id')).Trim()
            if ($ancestor -ne $remote) { throw 'Canonical main does not descend from published main.' }
            $null = Invoke-Jj $repo @('new', $ExpectedMain, '-m', $Message)
        }
        foreach ($path in $files.Keys) {
            $destination = Join-Path $repo $path
            if ($null -eq $files[$path]) { if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination }; continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            [IO.File]::WriteAllBytes($destination, [IO.File]::ReadAllBytes((Join-Path $registered $path)))
        }
        Assert-CanonicalInput
    }
    Assert-NoConflicts $repo
    if ((Invoke-Jj $repo @('file', 'list', 'root:.handoff')).Trim()) { throw 'Handoff metadata must not reach canonical main.' }
    Invoke-TaskTest $state $Test
    $candidate = if ($files.Count) { Get-CurrentId $repo } else { $ExpectedMain }
    Invoke-AgentRepositoryLock -RepositoryPath $registered -Action {
        Assert-CanonicalInput
        Invoke-RepositoryTransaction $repo {
            Assert-Execute $state
            Fetch-Branch $repo 'main'
            $remote = Get-RemoteTip $repo 'main'
            $ancestor = (Invoke-Jj $repo @('log', '-r', "$remote & ::$ExpectedMain", '--no-graph', '-T', 'commit_id')).Trim()
            if ($ancestor -ne $remote) { throw 'Published main advanced outside the validated canonical prefix.' }
            $state | Add-Member -NotePropertyName canonicalWork -NotePropertyValue ([pscustomobject]@{ main = $ExpectedMain; files = [pscustomobject]$files }) -Force
            $state.candidate = $candidate
            Save-Task $state
            Push-Branch $state 'main' $candidate $remote
            $state.published = $candidate
            Save-Task $state
        }
    }
    Sync-AgentRepository -TaskDirectory $TaskDirectory
}

function Complete-AgentTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$Test, [ValidateRange(1,20)][int]$Attempts = 3)
    $state = Read-Task $TaskDirectory
    Assert-Execute $state
    if ($Message -notmatch '^[a-z]+(?:\([^)]+\))?!?: .+') { throw 'A Conventional Commit message is required.' }
    $repo = Join-Path $state.path 'repository'
    if (-not $state.published) {
        Fetch-Branch $repo 'main'
        if ($state.candidate -and (Test-Published $repo $state.candidate)) {
            $state.published = $state.candidate
            Save-Task $state
        } else {
            if ($state.branch) { $null = Assert-Owned $state $repo }
            if (-not $state.candidate) {
                Assert-NoConflicts $repo
                $source = Get-CurrentId $repo
                if ($state.branch) {
                    $record = Read-Handoff $repo $source $state.taskId
                    if ($record.Meta.owner.token -ne $state.owner.token) { throw 'Local ownership header was changed.' }
                    # PLAN follows the active task outside the code-only integration candidate.
                    [IO.File]::WriteAllText((Join-Path $state.path 'PLAN.md'), $record.Body)
                }
                # Build a code-only sibling at the original base, preserving the source change.
                $null = Invoke-Jj $repo @('new', $state.base, '-m', $Message)
                $null = Invoke-Jj $repo @('restore', '--from', $source, '~root:.handoff')
                $state.candidate = Get-CurrentId $repo
                $state.candidateBase = $state.base
                $state.candidateChange = (Invoke-Jj $repo @('log', '-r', '@', '--no-graph', '-T', 'change_id')).Trim()
                Save-Task $state
            }
            for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
                $main = Invoke-RepositoryTransaction $repo {
                    Fetch-Branch $repo 'main'
                    Get-RemoteTip $repo 'main'
                }
                $null = Invoke-Jj $repo @('edit', $state.candidateChange)
                $null = Invoke-Jj $repo @('rebase', '-r', '@', '-o', $main)
                $state.candidate = Get-CurrentId $repo
                $state.candidateBase = $main
                Save-Task $state
                Assert-NoConflicts $repo
                if ((Invoke-Jj $repo @('file', 'list', 'root:.handoff')).Trim()) { throw 'Handoff metadata must not reach main.' }
                Invoke-TaskTest $state $Test
                # Tests run without the store lock. A peer may have advanced shared refs meanwhile.
                $state.candidate = Get-CurrentId $repo
                Save-Task $state
                try {
                    $published = Invoke-RepositoryTransaction $repo {
                        Assert-Execute $state
                        if ((Get-RemoteTip $repo 'main') -ne $main) { return $false }
                        if ($state.branch) { $null = Assert-Owned $state $repo }
                        if ((Invoke-Jj $repo @('diff', '--summary')).Trim()) {
                            Push-Branch $state 'main' $state.candidate $main
                            $state.published = $state.candidate
                        } else { $state.published = $main }
                        Save-Task $state
                        return $true
                    }
                    if ($published) { break }
                    if ($attempt -eq $Attempts) { throw 'Main kept advancing; rerun completion.' }
                } catch {
                    $pushError = $_
                    $current = Invoke-RepositoryTransaction $repo {
                        Fetch-Branch $repo 'main'
                        if (Test-Published $repo $state.candidate) {
                            $state.published = $state.candidate
                            Save-Task $state
                        }
                        Get-RemoteTip $repo 'main'
                    }
                    if ($state.published) { break }
                    if ($current -eq $main -or $attempt -eq $Attempts) { throw $pushError }
                    # The next attempt rebases and tests against a fresh exact main tip.
                }
            }
        }
    }
    if ($state.branch -and -not $state.branchDeleted) {
        Invoke-RepositoryTransaction $repo {
            Assert-Execute $state
            Fetch-Branch $repo $state.branch
            $tip = Get-RemoteTip $repo $state.branch
            if ($tip) {
                $null = Assert-Owned $state $repo
                $null = Invoke-Jj $repo @('bookmark', 'delete', "exact:$($state.branch)")
                $null = Invoke-Jj $repo @('git', 'push', '--remote', 'origin', '--bookmark', "exact:$($state.branch)")
            }
            $state.branchDeleted = $true
            Save-Task $state
        }
    }
    Sync-AgentRepository $TaskDirectory
    [pscustomobject]@{ Status = 'Complete'; Main = $state.published; TaskDirectory = $state.path }
}

function Get-AgentWorkflowHelp {
    @'
Import-Module "$HOME/.agents/workflow/AgentWorkflow.psm1"
Start-AgentTask -Repository owner/name [-Execute] [-PreserveRemoteBranch @{ 'approved/name' = '<full-tip>' }]
Enable-AgentTaskExecution -TaskDirectory <task> -Doit
Get-AgentHandoff -TaskDirectory <task>                         # available IDs only
Receive-AgentHandoff -TaskDirectory <fresh-task> -TaskId <id>   # claim, then expose PLAN
Publish-AgentHandoff -TaskDirectory <task>                     # local PLAN.md -> unowned handoff
Unlock-AgentHandoff -TaskDirectory <task>                     # update PLAN/code, then release
Complete-AgentTask -TaskDirectory <task> -Message 'fix: ...' -Test { <tests; throw on failure> }
Sync-AgentRepository -TaskDirectory <task>                     # retry sync only
Sync-AgentRegisteredRepository -RepositoryPath <path> -ExpectedRemote <remote>
Sync-AgentRepositoryMap -LogPath <jsonl>
Complete-AgentCanonicalWork -TaskDirectory <fresh-task> -ExpectedMain <exact-tip> -Message 'chore: ...' -ExpectedFiles @{ 'owned/file' = '<sha256>' } -Test { <isolated tests> }
Invoke-AgentRepositoryLock -RepositoryPath <path> -Action { <sync> }
Test-AgentRepositoryPathAllowed -RepositoryPath <path>         # Box policy

Default phase is plan. Use -Execute/-Doit only after explicit user do authorization.
Preservation requires explicit user approval of each exact branch and full tip; it grants no integration or ownership.
Approvals belong to this task only. Unapproved refs and changed/missing approved tips stop remote mutations.
Task directory: C:/dev/tmp/<id>/ (id = a full GUID as 32 lowercase hex digits, also the initial TaskId).
Tasks use separate workspaces backed by one full-history store per origin under C:/dev/tmp/task-stores/.
The registered repository remains independent. Do not remove a task store while its workspaces exist.
Use the returned Repository as cwd. PLAN.md and artifacts stay beside it until handoff.
Occupied handoffs are omitted, never automatically reclaimed. No crash monitoring.
Edit claimed .handoff/PLAN.md body only; do not edit its header.
If integration fails, PLAN.md moves beside repository/; edit that PLAN before releasing.
Only handoff branches may carry unfinished conflicts; main always requires resolution and passing tests.
Main gets a code-only change, not a merge of handoff history. Successful ordinary tasks publish no PLAN.
Retry Complete with the same arguments after resolving the cause.
Never edit the task workspace after a confirmed main push; retry only pending post-push steps.
'@
}

Export-ModuleMember -Function Start-AgentTask, Enable-AgentTaskExecution, Get-AgentHandoff,
    Receive-AgentHandoff, Publish-AgentHandoff, Unlock-AgentHandoff, Complete-AgentTask,
    Sync-AgentRepository, Sync-AgentRegisteredRepository, Sync-AgentRepositoryMap, Write-AgentRepositorySyncEvent,
    Complete-AgentCanonicalWork, Invoke-AgentRepositoryLock, Test-AgentRepositoryPathAllowed,
    Get-AgentWorkflowHelp
