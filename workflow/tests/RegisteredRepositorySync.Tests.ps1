#requires -Version 7.4
BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AgentWorkflow.psm1'
    Import-Module $modulePath -Force
    Import-Module "$HOME/local-repository-map/RepositoryMap.psm1"
    $fixtureRoot = Join-Path 'C:/dev/tmp' ('ars-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($fixtureRoot)

    function Invoke-SyncTestJj {
        param([string]$Path, [string[]]$Arguments)
        $output = @(& jj --no-pager --color never -R $Path @Arguments 2>&1)
        if ($LASTEXITCODE) { throw ($output -join "`n") }
        return ($output -join "`n")
    }
    function New-SyncFixture {
        $root = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($root)
        $seed = Join-Path $root 'seed'
        $work = Join-Path $root 'work'
        $null = & jj git init --colocate $seed 2>&1
        if ($LASTEXITCODE) { throw 'Fixture init failed.' }
        [IO.File]::WriteAllText((Join-Path $seed 'base.txt'), "base`n")
        $null = Invoke-SyncTestJj $seed @('describe', '-m', 'test: seed')
        $null = Invoke-SyncTestJj $seed @('bookmark', 'set', 'main')
        $null = Invoke-SyncTestJj $seed @('git', 'export')
        $remote = (Join-Path $seed '.git').Replace('\', '/')
        $null = & jj git clone --branch main $remote $work 2>&1
        if ($LASTEXITCODE) { throw 'Fixture clone failed.' }
        $null = Invoke-SyncTestJj $work @('bookmark', 'track', 'main@origin')
        return @{ path = $work; remote = $remote; seed = $seed }
    }
    function Update-SyncFixtureRemote {
        param($Fixture)
        $null = Invoke-SyncTestJj $Fixture.seed @('new', 'main')
        [IO.File]::WriteAllText((Join-Path $Fixture.seed 'remote.txt'), "remote`n")
        $null = Invoke-SyncTestJj $Fixture.seed @('describe', '-m', 'test: remote advance')
        $null = Invoke-SyncTestJj $Fixture.seed @('bookmark', 'set', 'main')
        $null = Invoke-SyncTestJj $Fixture.seed @('git', 'export')
    }
}
AfterAll {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $protectedAttributes = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force | Where-Object { $_.Attributes -band $protectedAttributes } | ForEach-Object {
            $_.Attributes = $_.Attributes -band (-bnot $protectedAttributes)
        }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -ErrorAction Stop
    }
}

Describe 'shared registered repository synchronization' {
    It 'does not recreate an already current working copy' {
        $f = New-SyncFixture
        $before = Invoke-SyncTestJj $f.path @('log', '-r', '@', '--no-graph', '-T', 'commit_id')
        $result = Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote
        $result.Status | Should -Be 'Synchronized'
        (Invoke-SyncTestJj $f.path @('log', '-r', '@', '--no-graph', '-T', 'commit_id')) | Should -Be $before
    }

    It 'advances only main to the fetched remote and preserves handoff bookmarks' {
        $f = New-SyncFixture
        $null = Invoke-SyncTestJj $f.path @('bookmark', 'set', 'handoff/test', '-r', 'main')
        $handoff = Invoke-SyncTestJj $f.path @('log', '-r', 'handoff/test', '--no-graph', '-T', 'commit_id')
        Update-SyncFixtureRemote $f
        $result = Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote
        (Invoke-SyncTestJj $f.path @('log', '-r', 'main', '--no-graph', '-T', 'commit_id')) | Should -Be $result.Main
        Test-Path (Join-Path $f.path 'remote.txt') | Should -BeTrue
        (Invoke-SyncTestJj $f.path @('log', '-r', 'handoff/test', '--no-graph', '-T', 'commit_id')) | Should -Be $handoff
    }

    It 'rejects non-main bookmarks without changing references or workspace targets' {
        $f = New-SyncFixture
        $null = Invoke-SyncTestJj $f.path @('bookmark', 'set', 'master', '-r', 'main')
        $before = Invoke-SyncTestJj $f.path @('bookmark', 'list')
        $target = Invoke-SyncTestJj $f.path @('workspace', 'list', '-T', 'target.commit_id()')
        { Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote } | Should -Throw '*Unexpected bookmarks*master*'
        (Invoke-SyncTestJj $f.path @('bookmark', 'list')) | Should -Be $before
        (Invoke-SyncTestJj $f.path @('workspace', 'list', '-T', 'target.commit_id()')) | Should -Be $target
    }

    It 'rejects origin mismatch before fetching' {
        $f = New-SyncFixture
        Mock Fetch-Branch { throw 'Must not fetch.' } -ModuleName AgentWorkflow
        { Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote 'https://github.com/expgolemclone/other.git' } | Should -Throw '*origin differs*'
        Should -Invoke Fetch-Branch -ModuleName AgentWorkflow -Times 0 -Exactly
    }

    It 'preserves dirty working-copy files and refuses to fetch' {
        $f = New-SyncFixture
        [IO.File]::WriteAllText((Join-Path $f.path 'base.txt'), 'private edit')
        Mock Fetch-Branch { throw 'Must not fetch.' } -ModuleName AgentWorkflow
        { Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote } | Should -Throw '*has changes*'
        [IO.File]::ReadAllText((Join-Path $f.path 'base.txt')) | Should -Be 'private edit'
        Should -Invoke Fetch-Branch -ModuleName AgentWorkflow -Times 0 -Exactly
    }

    It 'preserves local unpublished main instead of replacing it' {
        $f = New-SyncFixture
        [IO.File]::WriteAllText((Join-Path $f.path 'private.txt'), 'private')
        $null = Invoke-SyncTestJj $f.path @('describe', '-m', 'test: private')
        $null = Invoke-SyncTestJj $f.path @('bookmark', 'set', 'main')
        $local = Invoke-SyncTestJj $f.path @('log', '-r', 'main', '--no-graph', '-T', 'commit_id')
        $null = Invoke-SyncTestJj $f.path @('new', 'main')
        { Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote } | Should -Throw '*unpublished or divergent*'
        (Invoke-SyncTestJj $f.path @('log', '-r', 'main', '--no-graph', '-T', 'commit_id')) | Should -Be $local
        [IO.File]::ReadAllText((Join-Path $f.path 'private.txt')) | Should -Be 'private'
    }

    It 'retains a described empty working copy' {
        $f = New-SyncFixture
        $null = Invoke-SyncTestJj $f.path @('describe', '-m', 'test: meaningful empty work')
        $target = Invoke-SyncTestJj $f.path @('workspace', 'list', '-T', 'target.commit_id()')
        { Sync-AgentRegisteredRepository -RepositoryPath $f.path -ExpectedRemote $f.remote } | Should -Throw '*unpublished work*'
        (Invoke-SyncTestJj $f.path @('workspace', 'list', '-T', 'target.commit_id()')) | Should -Be $target
    }

    It 'rejects Box paths before any jj operation' {
        Mock Invoke-Jj { throw 'Must not run jj.' } -ModuleName AgentWorkflow
        { Sync-AgentRegisteredRepository -RepositoryPath 'C:/dev/box_projects/repo' -ExpectedRemote 'https://github.com/expgolemclone/repo.git' } | Should -Throw '*Box repositories*'
        Should -Invoke Invoke-Jj -ModuleName AgentWorkflow -Times 0 -Exactly
    }

    It 'stops before jj when the registered path lock is busy' {
        Mock Invoke-AgentRepositoryLock { throw 'Registered repository synchronization is busy.' } -ModuleName AgentWorkflow
        Mock Invoke-Jj { throw 'Must not run jj.' } -ModuleName AgentWorkflow
        { Sync-AgentRegisteredRepository -RepositoryPath (Join-Path $TestDrive 'busy') -ExpectedRemote 'https://github.com/expgolemclone/repo.git' } | Should -Throw '*busy*'
        Should -Invoke Invoke-Jj -ModuleName AgentWorkflow -Times 0 -Exactly
    }
}

Describe 'mapped repository synchronization reporting' {
    It 'logs failures and excluded paths and finishes without touching missing or Box repositories' {
        $log = Join-Path $TestDrive 'sync.jsonl'
        $missing = Join-Path $TestDrive 'missing'
        Mock Read-LocalRepositoryMap {
            @{ ProfileName = 'test'; MapPath = 'fixture.json'; repositories = @(
                @{ repository = 'owner/missing'; path = $missing; remote = 'https://github.com/owner/missing.git' }
                @{ repository = 'owner/box'; path = 'C:/dev/box_projects/repo'; remote = 'https://github.com/owner/box.git' }
                @{ repository = 'owner/local'; path = 'unused'; remote = '' }
            ) }
        } -ModuleName AgentWorkflow
        Mock Invoke-Jj { throw 'Must not run jj.' } -ModuleName AgentWorkflow
        (Sync-AgentRepositoryMap -LogPath $log) | Should -Be 1
        $events = @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object type -EQ 'repository').Count | Should -Be 2
        @($events | Where-Object status -EQ 'failed').Count | Should -Be 1
        @($events | Where-Object status -EQ 'excluded').Count | Should -Be 1
        $events[-1].type | Should -Be 'finish'
        $events[-1].problems | Should -Be 1
        Should -Invoke Invoke-Jj -ModuleName AgentWorkflow -Times 0 -Exactly
    }

    It 'uses the native Node entrypoint for its notification action without inherited Node PATH' {
        $source = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'sync-repositories.ps1'))
        $source | Should -Match ([regex]::Escape('C:\Program Files\nodejs\node.exe'))
        $source | Should -Match '@expgolemclone/envx-runtime/cli.mjs'
        $source | Should -Match 'Start-Process -FilePath \$nodePath'
        $source | Should -Not -Match 'Get-Command node|Invoke-RepositorySync|RepositorySync.psm1'
    }
}
