$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$runtime = Join-Path $root 'runtime'
$nxapiDir = Join-Path $runtime 'nxapi'
$sourceUrl = 'https://github.com/samuelthomas2774/nxapi.git'
$sourceCommit = '47c9d35d9d51d33e62dd6d3733b616e0ad31b02b'
$rootGit = Join-Path $root '.git'
$gitModules = Join-Path $root '.gitmodules'

function Get-ExternalCommand {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd }
    }
    return $null
}

try {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' Game Presence Bridge - nxapi 初始化' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'nxapi 版本固定为已验证的提交：47c9d35d9d51d33e62dd6d3733b616e0ad31b02b'
    Write-Host '源码、依赖、编译文件和 npm 缓存均放在项目目录中。'
    Write-Host ''

    $git = Get-ExternalCommand @('git.exe', 'git')
    $node = Get-ExternalCommand @('node.exe', 'node')
    $npm = Get-ExternalCommand @('npm.cmd')
    $npx = Get-ExternalCommand @('npx.cmd')

    if (-not $git) { throw '未找到 Git。请先安装 Git for Windows，并确保 git.exe 在 PATH 中。' }
    if (-not $node) { throw '未找到 Node.js。请先安装 Node.js 18 或更新版本，并确保 node.exe 在 PATH 中。' }
    if (-not $npm) { throw '未找到 npm.cmd。请检查 Node.js 是否安装完整。' }
    if (-not $npx) { throw '未找到 npx.cmd。请检查 Node.js 是否安装完整。' }

    $nodeVersionText = (& $node.Source --version | Select-Object -First 1).Trim()
    $nodeVersionMatch = [regex]::Match($nodeVersionText, '^v?(\d+)')
    if (-not $nodeVersionMatch.Success -or [int]$nodeVersionMatch.Groups[1].Value -lt 18) {
        throw "需要 Node.js 18 或更新版本；当前版本为 $nodeVersionText。"
    }

    if ((Test-Path -LiteralPath $rootGit) -and (Test-Path -LiteralPath $gitModules)) {
        Write-Host '[1/4] 正在初始化 Git 子模块...' -ForegroundColor Cyan
        & $git.Source -C $root submodule update --init --recursive -- runtime/nxapi
        if ($LASTEXITCODE -ne 0) {
            throw 'Git 子模块初始化失败。请检查网络和 Git 配置。'
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $nxapiDir 'package.json'))) {
        if (Test-Path -LiteralPath $nxapiDir) {
            $children = @(Get-ChildItem -LiteralPath $nxapiDir -Force -ErrorAction SilentlyContinue)
            if ($children.Count -gt 0) {
                throw "目录 runtime\nxapi 已存在但不是有效的 nxapi 源码目录。请先备份并移走该目录后重试。"
            }
            Remove-Item -LiteralPath $nxapiDir -Force -ErrorAction SilentlyContinue
        }

        Write-Host '[1/4] 正在下载 nxapi 源代码...' -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        & $git.Source clone --no-checkout $sourceUrl $nxapiDir
        if ($LASTEXITCODE -ne 0) { throw '克隆 nxapi 源代码失败。' }

        & $git.Source -C $nxapiDir checkout --detach $sourceCommit
        if ($LASTEXITCODE -ne 0) { throw '切换到已验证的 nxapi 提交失败。' }
    } else {
        $head = (& $git.Source -C $nxapiDir rev-parse HEAD | Select-Object -First 1).Trim()
        if ($head -ne $sourceCommit) {
            Write-Host '[1/4] 正在切换到已验证的 nxapi 源码版本...' -ForegroundColor Cyan
            & $git.Source -C $nxapiDir fetch origin
            if ($LASTEXITCODE -ne 0) { throw '获取 nxapi 源码更新失败。' }
            & $git.Source -C $nxapiDir checkout --detach $sourceCommit
            if ($LASTEXITCODE -ne 0) { throw '切换到已验证的 nxapi 提交失败。' }
        }
    }

    $env:npm_config_cache = Join-Path $runtime 'npm-cache'

    Write-Host ''
    Write-Host '[2/4] 正在安装 nxapi 依赖（首次运行可能需要几分钟）...' -ForegroundColor Cyan
    Push-Location $nxapiDir
    try {
        & $npm.Source ci --force --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) {
            throw 'npm ci 安装依赖失败。可查看上方 npm 错误信息后重试。'
        }

        Write-Host ''
        Write-Host '[3/4] 正在编译 nxapi 命令行...' -ForegroundColor Cyan
        & $npx.Source tsc --pretty false
        if ($LASTEXITCODE -ne 0) {
            throw 'TypeScript 编译失败。'
        }
    } finally {
        Pop-Location
    }

    if (-not (Test-Path -LiteralPath (Join-Path $nxapiDir 'dist\cli-entry.js'))) {
        throw '编译结束但未找到 dist\cli-entry.js。'
    }

    Write-Host ''
    Write-Host '[4/4] 初始化完成。' -ForegroundColor Green
    Write-Host '现在可以运行 GamePresenceBridge.cmd。' -ForegroundColor Green
    Write-Host ''
    exit 0
} catch {
    Write-Host ''
    Write-Host ('初始化失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    exit 1
}
