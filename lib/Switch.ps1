$script:NxapiRuntime = Join-Path $script:BridgeRoot 'runtime'
$script:NxapiSource = Join-Path $script:NxapiRuntime 'nxapi'
$script:NxapiCmd = Join-Path $script:NxapiRuntime 'nxapi.cmd'
$script:NxapiLocalAppData = Join-Path $script:DataDir 'nxapi-localappdata'
$script:NxapiAppData = Join-Path $script:DataDir 'nxapi-appdata'
$script:SwitchConfigPath = Join-Path $script:DataDir 'switch.config.json'

function Get-NodeExe {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command node -ErrorAction SilentlyContinue }
    if (-not $cmd) {
        throw '未在 PATH 中找到 Node.js；当前验证版需要使用电脑中现有的 Node.js。'
    }
    return $cmd.Source
}

function Initialize-NxapiChineseLocalization {
    if (-not (Test-Path -LiteralPath $script:NxapiSource)) {
        return
    }

    # TypeScript-generated dist is ignored by the nxapi source repository.
    $dist = Join-Path $script:NxapiSource 'dist'
    if (-not (Test-Path -LiteralPath $dist)) {
        return
    }

    # 只替换本项目会实际调用到的 nxapi 用户可见提示。
    # 认证逻辑、请求参数和 API 行为完全不改。
    $targets = @(
        @{ File='cli\nso\auth.js'; Pairs=@(
            @('1. Open this URL and login to your Nintendo Account:', '1. 请打开以下网址并登录 Nintendo Account：'),
            @('2. On the "Linking an External Account" page, right click "Select this person" and copy the link. It should start with "npf71b963c1b7b6d119://auth".', '2. 在“关联外部账号”页面，右键“选择此用户”并复制链接。链接应以“npf71b963c1b7b6d119://auth”开头。'),
            @('Paste the link: ', '请粘贴完整回调链接：'),
            @("console.log('Session token', token);", "console.log('已获取 Nintendo 会话令牌（内容已隐藏）');"),
            @('Authenticated as Nintendo Account %s (NA %s, NSO %s)', '已登录 Nintendo Account %s（NA %s，NSO %s）'),
            @('Set as default user', '已设为默认用户'),
            @('Generate a link to login to a Nintendo Account', '生成 Nintendo Account 登录链接'),
            @('Authenticate immediately', '立即进行认证'),
            @('Set as default user (default: true if only user)', '设为默认用户（仅有一个用户时默认启用）')
        )},
        @{ File='cli\nso\friends.js'; Pairs=@(
            @('Listing friends', '正在读取好友列表'),
            @('List Nintendo Switch friends', '列出 Nintendo Switch 好友'),
            @('Nintendo Account ID', 'Nintendo Account ID'),
            @('Nintendo Account session token', 'Nintendo Account 会话令牌'),
            @('Output raw JSON', '输出原始 JSON'),
            @('Output pretty-printed JSON', '输出格式化 JSON')
        )},
        @{ File='common\auth\coral.js'; Pairs=@(
            @('Authenticating to Nintendo Switch Online app', '正在验证 Nintendo Switch Online 应用登录'),
            @('No token set. Set a Nintendo Account session token using the `--token` option or by running `nxapi nso token`.', '未设置令牌。请使用 --token 参数提供 Nintendo Account 会话令牌，或运行 nxapi nso token。'),
            @('Invalid token', '无效令牌')
        )},
        @{ File='common\auth\na.js'; Pairs=@(
            @('Authenticating to Nintendo Accounts', '正在验证 Nintendo Account'),
            @('Invalid Nintendo Account session token issuer', 'Nintendo Account 会话令牌签发方无效'),
            @('Invalid Nintendo Account session token type', 'Nintendo Account 会话令牌类型无效'),
            @('Invalid Nintendo Account session token audience', 'Nintendo Account 会话令牌受众无效'),
            @('Nintendo Account session token expired', 'Nintendo Account 会话令牌已过期'),
            @('Invalid Nintendo Account session token', 'Nintendo Account 会话令牌无效')
        )},
        @{ File='client\coral.js'; Pairs=@(
            @('Authenticating to Nintendo Switch Online app', '正在验证 Nintendo Switch Online 应用登录'),
            @('No user selected', '未选择用户'),
            @('Unknown user', '未知用户')
        )}
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    foreach ($target in $targets) {
        $path = Join-Path $dist $target.File
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $updated = $text

            foreach ($pair in $target.Pairs) {
                $updated = $updated.Replace([string]$pair[0], [string]$pair[1])
            }

            if ($updated -ne $text) {
                [System.IO.File]::WriteAllText($path, $updated, $utf8NoBom)
            }
        } catch {
            Write-Host ('[Switch] nxapi 中文提示补丁应用失败：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Test-NxapiInstalled {
    $cmdExists = Test-Path -LiteralPath $script:NxapiCmd
    $entryExists = Test-Path -LiteralPath (Join-Path $script:NxapiSource 'dist\cli-entry.js')
    $depsExist = Test-Path -LiteralPath (Join-Path $script:NxapiSource 'node_modules')
    return ($cmdExists -and $entryExists -and $depsExist)
}

function Get-NxapiEnvironment {
    Initialize-BridgeDirectories
    return @{
        'NXAPI_DATA_PATH' = $script:NxapiData
        'NXAPI_USER_AGENT' = 'GamePresenceBridge/0.5.4'
        'NXAPI_DEBUG_FILE' = '0'
        'NXAPI_SKIP_UPDATE_CHECK' = '1'
        'LOCALAPPDATA' = $script:NxapiLocalAppData
        'APPDATA' = $script:NxapiAppData
        'XDG_CACHE_HOME' = (Join-Path $script:DataDir 'nxapi-cache')
        'XDG_STATE_HOME' = (Join-Path $script:DataDir 'nxapi-state')
    }
}

function Quote-CmdArg {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }

    # Arguments used here are simple nxapi tokens. Quote values containing
    # whitespace or CMD metacharacters.
    if ($Value -notmatch '[\s&|<>^"]') {
        return $Value
    }

    return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Invoke-NxapiCapture {
    param([string[]]$Arguments)

    Initialize-NxapiChineseLocalization

    if (-not (Test-NxapiInstalled)) {
        throw '未找到 nxapi.cmd，请先把已验证可用的 nxapi runtime 内容复制到插件的 runtime 目录。'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec

    $quotedExe = '"' + $script:NxapiCmd + '"'
    $argText = (($Arguments | ForEach-Object { Quote-CmdArg ([string]$_) }) -join ' ')
    $psi.Arguments = '/d /s /c "' + $quotedExe + ' ' + $argText + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $envs = Get-NxapiEnvironment
    foreach ($key in $envs.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$envs[$key]
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        $detail = ($stderr + "`n" + $stdout).Trim()
        throw ("nxapi exited with code {0}: {1}" -f $p.ExitCode, $detail)
    }

    return [pscustomobject]@{
        StdOut = $stdout
        StdErr = $stderr
        ExitCode = $p.ExitCode
    }
}

function Invoke-NxapiInteractive {
    param([string[]]$Arguments)

    Initialize-NxapiChineseLocalization

    if (-not (Test-NxapiInstalled)) {
        throw '未找到 nxapi.cmd，请先把已验证可用的 nxapi runtime 内容复制到插件的 runtime 目录。'
    }

    # Do not pipe nxapi through PowerShell. nxapi writes normal instructions
    # and the login URL to stdout, but its interactive prompt to stderr.
    # Piping only stdout caused the two streams to appear out of order.
    #
    # Start cmd.exe as a child process with NO stdio redirection so it inherits
    # this console exactly like the standalone lite test did.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec

    $quotedExe = '"' + $script:NxapiCmd + '"'
    $argText = (($Arguments | ForEach-Object { Quote-CmdArg ([string]$_) }) -join ' ')
    $psi.Arguments = '/d /s /c "' + $quotedExe + ' ' + $argText + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardInput = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    $envs = Get-NxapiEnvironment
    foreach ($key in $envs.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$envs[$key]
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        throw "nxapi 交互命令执行失败，退出代码 $($p.ExitCode)."
    }
}

function Get-SwitchSafeProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }

    return $prop.Value
}

function Get-SwitchConfig {
    if (-not (Test-Path -LiteralPath $script:SwitchConfigPath)) { return $null }
    return ([System.IO.File]::ReadAllText($script:SwitchConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Save-SwitchConfig {
    param([Parameter(Mandatory=$true)]$Object)
    Write-Utf8NoBom -Path $script:SwitchConfigPath -Text ($Object | ConvertTo-Json -Depth 6)
}

function Expand-NxapiFriendItems {
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) {
        return
    }

    # Windows PowerShell 5.1 can preserve a JSON array as one Object[] value
    # when it crosses a function/pipeline boundary. Recursively flatten only
    # actual arrays/lists; PSCustomObject friend records are emitted intact.
    if (
        $Value -is [System.Array] -or
        (
            $Value -is [System.Collections.IList] -and
            -not ($Value -is [string])
        )
    ) {
        foreach ($item in $Value) {
            Expand-NxapiFriendItems -Value $item
        }
        return
    }

    Write-Output $Value
}

function Get-NxapiFriends {
    param(
        [int]$MaxAttempts = 4
    )

    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = Invoke-NxapiCapture -Arguments @('nso','friends','--json-pretty-print')

            if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
                throw 'nxapi 未返回好友 JSON。'
            }

            $parsed = $result.StdOut | ConvertFrom-Json
            $flatFriends = @(Expand-NxapiFriendItems -Value $parsed)

            if ($flatFriends.Count -eq 0) {
                return @()
            }

            # Emit friend records one by one. Callers wrapping this function in
            # @() will therefore always receive a flat friend list.
            foreach ($friendItem in $flatFriends) {
                Write-Output $friendItem
            }
            return
        } catch {
            $lastError = $_.Exception.Message

            $transient = (
                $lastError -match 'ECONNRESET' -or
                $lastError -match 'ETIMEDOUT' -or
                $lastError -match 'ECONNREFUSED' -or
                $lastError -match 'fetch failed' -or
                $lastError -match 'TLS' -or
                $lastError -match 'socket disconnected'
            )

            if (-not $transient -or $attempt -ge $MaxAttempts) {
                throw
            }

            $delay = 2 * $attempt
            Write-Host ("[Switch] nxapi 网络请求失败（第 {0}/{1} 次），{2} 秒后重试..." -f $attempt, $MaxAttempts, $delay) -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
    }

    throw $lastError
}

function Get-SwitchPresence {
    param(
        [int]$Interval,
        [Parameter(Mandatory=$true)]$Config
    )

    $sw = Get-SwitchConfig
    $targetNsaId = Get-SwitchSafeProperty -Object $sw -Name 'friend_nsaid'
    if ($null -eq $sw -or [string]::IsNullOrWhiteSpace([string]$targetNsaId)) {
        throw '尚未配置 Switch 监控目标账号。'
    }

    $friends = @(Get-NxapiFriends)

    $targetIdText = ([string]$targetNsaId).Trim()
    $friend = $null
    $returnedIds = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $friends) {
        $candidateIdValue = Get-SwitchSafeProperty -Object $candidate -Name 'nsaId'
        if ($null -eq $candidateIdValue) {
            continue
        }

        $candidateIdText = ([string]$candidateIdValue).Trim()
        $returnedIds.Add($candidateIdText)

        if ([string]::Equals(
            $candidateIdText,
            $targetIdText,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            $friend = $candidate
            break
        }
    }

    if ($null -eq $friend) {
        $seen = if ($returnedIds.Count -gt 0) {
            [string]::Join(', ', $returnedIds.ToArray())
        } else {
            '(none)'
        }
        throw "在 nxapi 好友列表中找不到已配置的 Nintendo 账号： $targetIdText. 本次返回的 NSAID： $seen"
    }

    $friendName = Get-SwitchSafeProperty -Object $friend -Name 'name'
    $friendNsaId = Get-SwitchSafeProperty -Object $friend -Name 'nsaId'
    $presence = Get-SwitchSafeProperty -Object $friend -Name 'presence'

    $stateValue = Get-SwitchSafeProperty -Object $presence -Name 'state'
    $stateText = if ($stateValue) { [string]$stateValue } else { 'OFFLINE' }
    $stateUpper = $stateText.ToUpperInvariant()
    $online = ($stateUpper -eq 'ONLINE' -or $stateUpper -eq 'PLAYING')

    # nxapi can return game: {} while offline/idle. Every game field is optional.
    $game = Get-SwitchSafeProperty -Object $presence -Name 'game'

    $titleValue = Get-SwitchSafeProperty -Object $game -Name 'name'
    $title = if ($titleValue) { [string]$titleValue } else { $null }

    $platform = 'Switch'
    $platformValue = Get-SwitchSafeProperty -Object $presence -Name 'platform'
    if ($null -ne $platformValue) {
        if ([int]$platformValue -eq 2) {
            $platform = 'Switch 2'
        }
    }

    $shopUriValue = Get-SwitchSafeProperty -Object $game -Name 'shopUri'
    $titleId = $null
    if ($shopUriValue) {
        $m = [regex]::Match([string]$shopUriValue, '/apps/([^/]+)/')
        if ($m.Success) { $titleId = $m.Groups[1].Value }
    }

    $playTimeValue = Get-SwitchSafeProperty -Object $game -Name 'totalPlayTime'
    $playMinutes = $null
    if ($null -ne $playTimeValue) {
        $playMinutes = [int]$playTimeValue
    }

    $imageUriValue = Get-SwitchSafeProperty -Object $game -Name 'imageUri'
    $firstPlayedValue = Get-SwitchSafeProperty -Object $game -Name 'firstPlayedAt'

    return [ordered]@{
        source = 'Nintendo Switch'
        ok = $true
        online = $online
        playing = ($online -and -not [string]::IsNullOrWhiteSpace($title))
        online_id = if ($friendName) { [string]$friendName } else { $null }
        account_id = if ($friendNsaId) { [string]$friendNsaId } else { $null }
        platform = $platform
        title_name = $title
        title_id = $titleId
        title_format = $null
        launch_platform = $platform
        game_status = $stateText
        icon_url = if ($imageUriValue) { [string]$imageUriValue } else { $null }
        total_play_time_minutes = $playMinutes
        first_played_at = $firstPlayedValue
        updated_at = Get-IsoUtcNow
        poll_interval_seconds = $Interval
        error = $null
    }
}

