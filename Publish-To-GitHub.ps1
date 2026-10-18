$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repo = 'mokeling/GamePresenceBridge'
$sourceUrl = 'https://github.com/samuelthomas2774/nxapi.git'
$sourceCommit = '47c9d35d9d51d33e62dd6d3733b616e0ad31b02b'
$nxapiDir = Join-Path $root 'runtime\nxapi'

function Invoke-Git {
    param([string[]]$GitArgs)
    & $script:Git.Source @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Git 命令失败：git $($GitArgs -join ' ')"
    }
}

try {
    $script:Git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $script:Git) { $script:Git = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $script:Git) { throw '未找到 Git for Windows。' }

    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Write-Host '[1/5] 初始化本地 Git 仓库...' -ForegroundColor Cyan
        Invoke-Git @('-C', $root, 'init')
        Invoke-Git @('-C', $root, 'branch', '-M', 'main')
    }

    if (-not (Test-Path -LiteralPath (Join-Path $root '.gitmodules'))) {
        Write-Host '[2/5] 将 nxapi 注册为 Git 子模块...' -ForegroundColor Cyan

        # If setup was already run from a ZIP, replace its temporary clone with a clean gitlink.
        $backup = Join-Path $root 'runtime\nxapi-local-backup'
        $movedExisting = $false
        if (Test-Path -LiteralPath $nxapiDir) {
            $nxapiGit = Join-Path $nxapiDir '.git'
            if (Test-Path -LiteralPath $nxapiGit) {
                if (Test-Path -LiteralPath $backup) {
                    throw 'runtime\nxapi-local-backup 已存在；请先检查并移走该备份目录。'
                }
                Move-Item -LiteralPath $nxapiDir -Destination $backup
                $movedExisting = $true
            } else {
                $children = @(Get-ChildItem -LiteralPath $nxapiDir -Force -ErrorAction SilentlyContinue)
                if ($children.Count -gt 0) {
                    throw 'runtime\nxapi 目录存在但不是 Git 仓库；请先备份并移走该目录。'
                }
                Remove-Item -LiteralPath $nxapiDir -Force -ErrorAction SilentlyContinue
            }
        }

        try {
            Invoke-Git @('-C', $root, 'submodule', 'add', $sourceUrl, 'runtime/nxapi')
            Invoke-Git @('-C', $nxapiDir, 'checkout', '--detach', $sourceCommit)
            if ($movedExisting) {
                # Preserve locally generated files if Setup-Nxapi.cmd was run before publishing.
                # The upstream .gitignore excludes both folders, so they are never committed.
                foreach ($generatedName in @('node_modules', 'dist')) {
                    $sourceGenerated = Join-Path $backup $generatedName
                    $targetGenerated = Join-Path $nxapiDir $generatedName
                    if (Test-Path -LiteralPath $sourceGenerated) {
                        New-Item -ItemType Directory -Path $targetGenerated -Force | Out-Null
                        Get-ChildItem -LiteralPath $sourceGenerated -Force |
                            Copy-Item -Destination $targetGenerated -Recurse -Force
                    }
                }
                Remove-Item -LiteralPath $backup -Recurse -Force
            }
        } catch {
            if ($movedExisting -and (Test-Path -LiteralPath $backup)) {
                if (Test-Path -LiteralPath $nxapiDir) {
                    Remove-Item -LiteralPath $nxapiDir -Recurse -Force
                }
                Move-Item -LiteralPath $backup -Destination $nxapiDir
            }
            throw
        }
    } else {
        Write-Host '[2/5] 已检测到 .gitmodules，检查子模块...' -ForegroundColor Cyan
        Invoke-Git @('-C', $root, 'submodule', 'update', '--init', '--recursive', '--', 'runtime/nxapi')
        Invoke-Git @('-C', $nxapiDir, 'checkout', '--detach', $sourceCommit)
    }

    Write-Host '[3/5] 检查 Git 身份...' -ForegroundColor Cyan
    $gitName = (& $script:Git.Source -C $root config user.name 2>$null | Select-Object -First 1)
    $gitEmail = (& $script:Git.Source -C $root config user.email 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace([string]$gitName) -or [string]::IsNullOrWhiteSpace([string]$gitEmail)) {
        throw 'Git 尚未配置提交身份。请先运行 git config --global user.name "你的名字" 和 git config --global user.email "你的邮箱"，再重新运行本脚本。'
    }

    Invoke-Git @('-C', $root, 'add', '-A')
    $status = (& $script:Git.Source -C $root status --porcelain | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        Write-Host '[4/5] 创建本地初始提交...' -ForegroundColor Cyan
        Invoke-Git @('-C', $root, 'commit', '-m', 'Initial commit: Game Presence Bridge 0.5.4')
    } else {
        Write-Host '[4/5] 本地文件已提交，无需重复提交。' -ForegroundColor DarkGray
    }

    $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
    if (-not $gh) { $gh = Get-Command gh -ErrorAction SilentlyContinue }

    $ghReady = $false
    if ($gh) {
        & $gh.Source auth status *> $null
        $ghReady = ($LASTEXITCODE -eq 0)
    }

    if ($ghReady) {
        Write-Host '[5/5] 正在创建/推送 GitHub 仓库...' -ForegroundColor Cyan
        & $gh.Source repo view $repo --json name *> $null
        $repoExists = ($LASTEXITCODE -eq 0)

        $origin = (& $script:Git.Source -C $root remote get-url origin 2>$null | Select-Object -First 1)
        if ($repoExists) {
            $expectedUrl = 'https://github.com/mokeling/GamePresenceBridge.git'
            if ([string]::IsNullOrWhiteSpace([string]$origin)) {
                Invoke-Git @('-C', $root, 'remote', 'add', 'origin', $expectedUrl)
            } elseif ($origin -notmatch 'github\.com[:/]mokeling/GamePresenceBridge(\.git)?$') {
                throw "origin 已指向其他仓库：$origin。为避免误推送，脚本已停止。"
            }
            Invoke-Git @('-C', $root, 'push', '-u', 'origin', 'main')
        } else {
            & $gh.Source repo create $repo --public --source $root --remote origin --push
            if ($LASTEXITCODE -ne 0) {
                throw 'GitHub 仓库创建或推送失败。可按下方手动步骤继续。'
            }
        }

        Write-Host ''
        Write-Host ('已推送到 https://github.com/{0}' -f $repo) -ForegroundColor Green
        Write-Host '仓库设为 Public，未设置 Description。' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host '本地提交已准备好，但未自动推送：未检测到已登录的 GitHub CLI（gh）。' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '请在浏览器打开 https://github.com/new 并创建仓库：' -ForegroundColor White
        Write-Host '  Repository name：GamePresenceBridge' -ForegroundColor White
        Write-Host '  Visibility：Public' -ForegroundColor White
        Write-Host '  Description：留空' -ForegroundColor White
        Write-Host '  不要勾选 README、.gitignore 或 License 初始化选项。' -ForegroundColor White
        Write-Host ''
        Write-Host '创建完成后，在项目目录打开 PowerShell 执行：' -ForegroundColor Cyan
        $existingOrigin = (& $script:Git.Source -C $root remote get-url origin 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace([string]$existingOrigin)) {
            Write-Host '  git remote add origin https://github.com/mokeling/GamePresenceBridge.git' -ForegroundColor Green
        }
        Write-Host '  git push -u origin main' -ForegroundColor Green
        Write-Host ''
        Write-Host '如果安装了 GitHub CLI，可先运行 gh auth login，再重新运行本脚本。' -ForegroundColor DarkGray
    }
} catch {
    Write-Host ''
    Write-Host ('发布准备失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    exit 1
}
