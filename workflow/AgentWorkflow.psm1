#requires -Version 7.4
Set-StrictMode -Version Latest
$script:TmpRoot = 'C:/dev/tmp'
$script:HandoffPath = '.handoff/PLAN.md'
$script:Marker = 'agent-workflow/v1'

function Invoke-Jj {
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
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "jj $($Arguments[0]) failed: $($errorText.Trim())"
        }
        return $output
    } finally { $process.Dispose() }
}

function Get-CurrentId {
    param([string]$Directory)
    # Snapshot first. workspace list has no snapshot of its own in some jj versions.
    $null = Invoke-Jj $Directory @('status')
    $ids = (Invoke-Jj $Directory @('workspace', 'list', '-T', 'target.commit_id() ++ "\n"')).Trim() -split '\r?\n'
    if ($ids.Count -ne 1 -or $ids[0] -notmatch '^[0-9a-f]{40,64}$') {
        throw 'Only independent, single-workspace task repositories are supported.'
    }
    return $ids[0]
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

function Assert-RemoteBranches {
    param([string]$Directory)
    $null = Invoke-Jj $Directory @('git', 'fetch', '--remote', 'origin', '--branch', '*')
    $names = (Invoke-Jj $Directory @('bookmark', 'list', '--remote', 'origin', '-T',
        'if(remote == "origin", name ++ "\n")')) -split '\r?\n' | Where-Object { $_ }
    $unexpected = @($names | Where-Object { $_ -cne 'main' -and $_ -cnotmatch '^handoff/[a-z0-9-]+$' })
    if ($unexpected.Count) { throw "Unexpected remote branches; ask before changing them: $($unexpected -join ', ')" }
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
    if ($entries[0].path -match '(?i)[\\/]box(?:[\\/]|$)|[\\/]box_projects[\\/]') { throw 'Box repositories are not supported.' }
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
    if ($State.phase -ne 'execute') { throw 'This task is in plan phase. Explicit doit authorization is required.' }
    Assert-PushAllowed $State.remote
    Assert-Origin (Join-Path $State.path 'repository') $State.remote
}

function New-Task {
    param($Entry, [string]$Name, [switch]$Execute)
    if ($Name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Task name must be a lowercase slug.' }
    $id = "$Name-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $repoName = $Entry.repository -replace '[^a-zA-Z0-9-]', '-'
    $path = Join-Path $script:TmpRoot "$repoName-$id"
    $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
    $path = Assert-SafeTaskPath $path
    $state = [pscustomobject]@{
        marker = $script:Marker; path = $path; taskId = $id
        remote = [string]$Entry.remote; registeredPath = [IO.Path]::GetFullPath($Entry.path)
        phase = $(if ($Execute) { 'execute' } else { 'plan' })
        base = ''; branch = ''; owner = $null; branchTip = ''
        candidate = ''; candidateChange = ''; candidateBase = ''; published = ''; branchDeleted = $false; synchronized = $false
    }
    Save-Task $state
    $repo = Join-Path $path 'repository'
    $null = Invoke-Jj $path @('git', 'clone', '--branch', 'main', $state.remote, $repo)
    $state.base = Get-RemoteTip $repo 'main'
    if (-not $state.base) { throw 'Remote main is required.' }
    $null = Invoke-Jj $repo @('bookmark', 'track', 'main@origin')
    Save-Task $state
    Assert-RemoteBranches $repo
    return [pscustomobject]@{ TaskDirectory = $path; Repository = $repo; Phase = $state.phase; TaskId = $id }
}

function Start-AgentTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Name, [switch]$Execute)
    New-Task (Resolve-Repository $Repository) $Name -Execute:$Execute
}

function Enable-AgentTaskExecution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [Parameter(Mandatory)][switch]$Doit)
    if (-not $Doit) { throw 'Explicit doit authorization is required.' }
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

function Push-Branch {
    param([string]$Directory, [string]$Branch, [string]$Revision)
    if (Get-RemoteTip $Directory $Branch) {
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

function Publish-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
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
    Push-Branch $repo $branch $tip
    $state.branch = $branch; $state.branchTip = $tip; $state.base = $base
    $state.candidate = ''; $state.candidateChange = ''; $state.candidateBase = ''
    Save-Task $state
    Remove-Item -LiteralPath $plan -ErrorAction Stop
    [pscustomobject]@{ TaskId = $state.taskId; Status = 'Available' }
}

function Receive-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [Parameter(Mandatory)][string]$TaskId)
    $state = Read-Task $TaskDirectory
    Assert-Execute $state
    if ($TaskId -notmatch '^[a-z0-9-]+$') { throw 'Invalid task ID.' }
    if ($state.branch -or $state.candidate -or $state.published) { throw 'Use a fresh task clone to claim a handoff.' }
    $repo = Join-Path $state.path 'repository'
    if ((Invoke-Jj $repo @('diff', '--from', $state.base, '--to', '@', '--summary')).Trim()) {
        throw 'Claim requires an unchanged task clone.'
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
    # Never fetch/rebase/retry this claim on failure. jj compares the remote's expected tip.
    Push-Branch $repo $branch $claim
    $state.taskId = $TaskId; $state.base = $record.Meta.base; $state.branch = $branch
    $state.owner = $owner; $state.branchTip = $claim
    Save-Task $state
    [pscustomobject]@{ TaskId = $TaskId; PlanPath = Join-Path $repo $script:HandoffPath; Plan = $record.Body }
}

function Assert-Owned {
    param($State, [string]$Directory)
    if (-not $State.branch -or $null -eq $State.owner) { throw 'Task does not own a handoff.' }
    Fetch-Branch $Directory $State.branch
    $tip = Get-RemoteTip $Directory $State.branch
    if ($tip -ne $State.branchTip) { throw 'Handoff changed remotely. Stop; do not retry ownership automatically.' }
    $record = Read-Handoff $Directory $tip $State.taskId
    if ($null -eq $record.Meta.owner -or $record.Meta.owner.token -ne $State.owner.token) { throw 'Handoff ownership lost.' }
    return $record
}

function Unlock-AgentHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
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
    Push-Branch $repo $state.branch $tip
    $state.owner = $null; $state.branchTip = $tip; $state.base = $record.Meta.base
    $state.candidate = ''; $state.candidateChange = ''; $state.candidateBase = ''
    Save-Task $state
    if ($fromCandidate) { Remove-Item -LiteralPath (Join-Path $state.path 'PLAN.md') -ErrorAction Stop }
    [pscustomobject]@{ TaskId = $state.taskId; Status = 'Available' }
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

function Sync-AgentRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory)
    $state = Read-Task $TaskDirectory
    Assert-Execute $state
    if (-not $state.published) { throw 'Main publication must be confirmed before synchronization.' }
    $registered = $state.registeredPath
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($registered.ToLowerInvariant().TrimEnd('\', '/'))))
    $mutex = [Threading.Mutex]::new($false, "Local\AgentRepoSync-$hash")
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Registered repository synchronization is busy.' }
        Assert-Origin $registered $state.remote
        if ((Invoke-Jj $registered @('diff', '--summary')).Trim()) { throw 'Registered repository has changes; synchronization stopped.' }
        $before = Invoke-Jj $registered @('bookmark', 'list', 'exact:main', '-T', 'if(!remote, normal_target.commit_id())')
        if (-not $before.Trim()) { throw 'Registered local main is missing or conflicted.' }
        Fetch-Branch $registered 'main'
        $tip = Get-RemoteTip $registered 'main'
        # Local unpublished ancestors must not be silently discarded.
        $safe = Invoke-Jj $registered @('bookmark', 'list', '--remote', 'origin', 'exact:main', '-T',
            ('if(remote == "origin", if(normal_target.contained_in("' + $before.Trim() + '::"), "yes"))'))
        if ($safe.Trim() -ne 'yes') { throw 'Registered main has unpublished or divergent work.' }
        $publishedParents = Invoke-Jj $registered @('workspace', 'list', '-T',
            'if(target.contained_in("::main@origin"), "yes", if(target.empty(), target.parents().map(|p| if(p.contained_in("::main@origin"), "yes", "no")).join(","), "no"))')
        if ($publishedParents.Trim() -ne 'yes') { throw 'Registered working copy contains unpublished work.' }
        $null = Invoke-Jj $registered @('new', $tip)
        $null = Invoke-Jj $registered @('bookmark', 'set', 'main', '-r', $tip)
        if ((Invoke-Jj $registered @('diff', '--from', $tip, '--to', '@', '--summary')).Trim()) {
            throw 'Registered checkout differs from main; synchronization stopped.'
        }
        $state.synchronized = $true
        Save-Task $state
        [pscustomobject]@{ Status = 'Synchronized'; Main = $tip }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
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
                $state.candidateChange = (Invoke-Jj $repo @('workspace', 'list', '-T', 'target.change_id()')).Trim()
                Save-Task $state
            }
            for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
                Fetch-Branch $repo 'main'
                $main = Get-RemoteTip $repo 'main'
                $null = Invoke-Jj $repo @('edit', $state.candidateChange)
                $null = Invoke-Jj $repo @('rebase', '-r', '@', '-o', $main)
                $state.candidate = Get-CurrentId $repo
                $state.candidateBase = $main
                Save-Task $state
                Assert-NoConflicts $repo
                if ((Invoke-Jj $repo @('file', 'list', 'root:.handoff')).Trim()) { throw 'Handoff metadata must not reach main.' }
                Invoke-TaskTest $state $Test
                # Save exact validated tip before push; retries detect a completed ambiguous push.
                $state.candidate = Get-CurrentId $repo
                Save-Task $state
                if (-not (Invoke-Jj $repo @('diff', '--summary')).Trim()) {
                    Fetch-Branch $repo 'main'
                    if ((Get-RemoteTip $repo 'main') -ne $main) {
                        if ($attempt -eq $Attempts) { throw 'Main kept advancing; rerun completion.' }
                        continue
                    }
                    $state.published = $main
                    Save-Task $state
                    break
                }
                try {
                    if ($state.branch) { $null = Assert-Owned $state $repo }
                    Push-Branch $repo 'main' $state.candidate
                    $state.published = $state.candidate
                    Save-Task $state
                    break
                } catch {
                    $pushError = $_
                    Fetch-Branch $repo 'main'
                    if (Test-Published $repo $state.candidate) {
                        $state.published = $state.candidate
                        Save-Task $state
                        break
                    }
                    if ((Get-RemoteTip $repo 'main') -eq $main -or $attempt -eq $Attempts) { throw $pushError }
                    # The next attempt rebuilds local main from this fetched expected tip.
                }
            }
        }
    }
    if ($state.branch -and -not $state.branchDeleted) {
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
    Sync-AgentRepository $TaskDirectory
    [pscustomobject]@{ Status = 'Complete'; Main = $state.published; TaskDirectory = $state.path }
}

function Remove-AgentTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskDirectory, [switch]$ResearchComplete)
    $state = Read-Task $TaskDirectory
    if ($ResearchComplete) {
        if ($state.phase -ne 'plan' -or $state.branch -or $state.candidate -or $state.published) {
            throw 'Research cleanup accepts only unpublished plan-phase tasks.'
        }
    } elseif (-not $state.published -or -not $state.synchronized -or ($state.branch -and -not $state.branchDeleted)) {
        throw 'Only fully completed tasks may be deleted.'
    }
    $items = @(Get-ChildItem -LiteralPath $state.path -Recurse -Force -ErrorAction Stop)
    if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Task contains a link; automatic deletion stopped.' }
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
    Remove-Item -LiteralPath $state.path -Recurse -ErrorAction Stop
    [pscustomobject]@{ Status = 'Removed'; TaskDirectory = $state.path }
}

function Get-AgentWorkflowHelp {
    @'
Import-Module "$HOME/.agents/workflow/AgentWorkflow.psm1"
Start-AgentTask -Repository owner/name -Name task-slug [-Execute]
Enable-AgentTaskExecution -TaskDirectory <task> -Doit
Get-AgentHandoff -TaskDirectory <task>                         # available IDs only
Receive-AgentHandoff -TaskDirectory <fresh-task> -TaskId <id>   # claim, then expose PLAN
Publish-AgentHandoff -TaskDirectory <task>                     # local PLAN.md -> unowned handoff
Unlock-AgentHandoff -TaskDirectory <task>                     # update PLAN/code, then release
Complete-AgentTask -TaskDirectory <task> -Message 'fix: ...' -Test { <tests; throw on failure> }
Sync-AgentRepository -TaskDirectory <task>                     # retry sync only
Remove-AgentTask -TaskDirectory <task> [-ResearchComplete]    # completed work/research only

Default phase is plan. Use -Execute/-Doit only after explicit user authorization.
Use the returned Repository as cwd. PLAN.md and artifacts stay beside it until handoff.
Occupied handoffs are omitted, never automatically reclaimed. No crash monitoring.
Edit claimed .handoff/PLAN.md body only; do not edit its header.
If integration fails, PLAN.md moves beside repository/; edit that PLAN before releasing.
Only handoff branches may carry unfinished conflicts; main always requires resolution and passing tests.
Main gets a code-only change, not a merge of handoff history. Successful ordinary tasks publish no PLAN.
On failure retain the task directory. Retry Complete with the same arguments after resolving the cause.
Never edit the task clone after a confirmed main push; retry only pending post-push steps.
'@
}

Export-ModuleMember -Function Start-AgentTask, Enable-AgentTaskExecution, Get-AgentHandoff,
    Receive-AgentHandoff, Publish-AgentHandoff, Unlock-AgentHandoff, Complete-AgentTask,
    Sync-AgentRepository, Remove-AgentTask, Get-AgentWorkflowHelp
