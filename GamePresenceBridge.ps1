Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Game Presence Bridge'

$root = $PSScriptRoot

. (Join-Path $root 'lib\Common.ps1')
. (Join-Path $root 'lib\PSN.ps1')
. (Join-Path $root 'lib\Switch.ps1')

Initialize-BridgeDirectories
$config = Get-BridgeConfig

# 清理上一次异常退出可能残留的状态，并启动隐藏看门进程。
Remove-PresenceOutput
Start-PresenceCleanupWatchdog

$activityPath = Join-Path $script:DataDir 'activity-state.json'

function Test-PsnConfigured {
    try {
        $cred = Get-PsnCredentials
        return ($null -ne $cred -and (($cred.npsso) -or ($cred.refresh_token)))
    } catch { return $false }
}

function Test-SwitchConfigured {
    try {
        $sw = Get-SwitchConfig
        return ($null -ne $sw -and -not [string]::IsNullOrWhiteSpace([string]$sw.friend_nsaid))
    } catch { return $false }
}

function Setup-PsnInteractive {
    if (Test-PsnConfigured) {
        Write-Host '[PSN] 已检测到现有认证，无需重新输入。' -ForegroundColor Green
        return $true
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' PlayStation 登录说明' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '1. 请打开 PlayStation 香港官网并登录你的 PSN 账号：' -ForegroundColor White
    Write-Host '   https://www.playstation.com/zh-hans-hk/' -ForegroundColor Green
    Write-Host ''
    Write-Host '2. 保持同一浏览器的登录状态，再打开：' -ForegroundColor White
    Write-Host '   https://ca.account.sony.com/api/v1/ssocookie' -ForegroundColor Green
    Write-Host ''
    Write-Host '3. 页面会显示类似下面的 JSON：' -ForegroundColor White
    Write-Host '   {"npsso":"xxxxxxxx...","expires_in":123456}' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '4. 下面可以直接粘贴完整 JSON，也可以只粘贴 npsso 的值。' -ForegroundColor White
    Write-Host '   粘贴内容时将隐藏输入；直接回车可跳过 PSN。' -ForegroundColor DarkGray
    Write-Host ''
    $secureNpsso = Read-Host '请粘贴 NPSSO 或完整 ssocookie JSON' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureNpsso)
    try {
        $npsso = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    if ([string]::IsNullOrWhiteSpace($npsso)) {
        Write-Host '[PSN] 已跳过。' -ForegroundColor DarkGray
        return $false
    }

    $npsso = $npsso.Trim()

    # Accept either the token itself or the complete JSON returned by ssocookie.
    if ($npsso.StartsWith('{')) {
        try {
            $cookieJson = $npsso | ConvertFrom-Json
            if ($cookieJson.npsso) {
                $npsso = [string]$cookieJson.npsso
            }
        } catch {
            Write-Host '[PSN] 无法解析粘贴的 JSON。' -ForegroundColor Yellow
            return $false
        }
    }

    $npsso = $npsso.Trim().Trim('"')
    if ($npsso.Length -lt 32) {
        Write-Host '[PSN] NPSSO 长度异常，已跳过 PSN 配置。' -ForegroundColor Yellow
        return $false
    }

    try {
        Set-PsnNpsso -Npsso $npsso
        Write-Host '[PSN] 正在验证登录...' -ForegroundColor Gray
        $state = Get-PsnPresence -Interval ([int]$config.poll_interval_seconds) -Config $config
        Write-Host ('[PSN] 验证成功：{0}' -f $state.online_id) -ForegroundColor Green
        if ($state.title_name) {
            Write-Host ('      {0} | {1}' -f $state.launch_platform, $state.title_name)
        }
        return $true
    } catch {
        Write-Host ('[PSN] 配置失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Setup-SwitchInteractive {
    $reselectTarget = $false
    $nintendoAuthSucceeded = $false

    if (Test-SwitchConfigured) {
        $sw = Get-SwitchConfig
        Write-Host ('[Switch] 当前监控目标：{0} ({1})' -f $sw.friend_name, $sw.friend_nsaid) -ForegroundColor Green
        $reuse = Read-Host '直接回车沿用；输入 R 重新选择好友；输入 S 本次跳过 Switch'

        if ([string]::IsNullOrWhiteSpace($reuse)) {
            return $true
        }

        if ($reuse -match '^[Ss]$') {
            Write-Host '[Switch] 本次运行已跳过。' -ForegroundColor DarkGray
            return $false
        }

        if ($reuse -match '^[Rr]$') {
            $reselectTarget = $true
        } else {
            Write-Host '[Switch] 输入无法识别，将沿用当前监控目标。' -ForegroundColor DarkGray
            return $true
        }
    } else {
        Write-Host ''
        Write-Host '[Switch] 可选配置' -ForegroundColor Cyan
        $answer = Read-Host '输入 Y 配置 Nintendo Switch，直接回车跳过'

        if ($answer -notmatch '^[Yy]$') {
            Write-Host '[Switch] 已跳过。' -ForegroundColor DarkGray
            return $false
        }
    }

    try {
        if (-not (Test-NxapiInstalled)) {
            Write-Host '[Switch] 尚未初始化 nxapi 源码或编译文件。' -ForegroundColor Yellow
            Write-Host '首次初始化需要 Git、Node.js 18+、npm 和网络连接。' -ForegroundColor DarkGray
            $setupAnswer = Read-Host '输入 Y 现在自动初始化 nxapi；直接回车跳过 Switch'

            if ($setupAnswer -match '^[Yy]$') {
                $setupScript = Join-Path $script:BridgeRoot 'Setup-Nxapi.ps1'
                if (-not (Test-Path -LiteralPath $setupScript)) {
                    Write-Host '[Switch] 未找到 Setup-Nxapi.ps1，请重新下载完整项目。' -ForegroundColor Red
                    return $false
                }

                $setupArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $setupScript + '"'
                $setupProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $setupArgs -NoNewWindow -Wait -PassThru
                if ($setupProcess.ExitCode -ne 0) {
                    Write-Host '[Switch] nxapi 初始化失败；请查看上方错误后重新运行 Setup-Nxapi.cmd。' -ForegroundColor Red
                    return $false
                }
            } else {
                Write-Host '[Switch] 本次运行已跳过配置。需要 Switch 时可运行 Setup-Nxapi.cmd。' -ForegroundColor DarkGray
                return $false
            }

            if (-not (Test-NxapiInstalled)) {
                Write-Host '[Switch] nxapi 初始化后仍未就绪，请运行 Setup-Nxapi.cmd 检查。' -ForegroundColor Red
                return $false
            }
        }

        $friends = @()
        $cachedSessionWorks = $false

        # If this plugin data folder already contains a valid nxapi session,
        # reuse it. Otherwise perform the normal interactive login.
        try {
            $friends = @(Get-NxapiFriends)
            if ($friends.Count -gt 0) {
                $cachedSessionWorks = $true
                Write-Host '[Switch] 已检测到现有 nxapi 登录，将直接复用。' -ForegroundColor Green
            }
        } catch {}

        if (-not $cachedSessionWorks) {
            Write-Host ''
            Write-Host '============================================================' -ForegroundColor DarkCyan
            Write-Host ' Nintendo Switch 登录说明' -ForegroundColor Cyan
            Write-Host '============================================================' -ForegroundColor DarkCyan
            Write-Host ''
            Write-Host '1. nxapi 会在下方输出 Nintendo Account 登录网址。' -ForegroundColor White
            Write-Host '   请复制该网址并在浏览器中打开。' -ForegroundColor White
            Write-Host ''
            Write-Host '2. 请使用“小号”Nintendo Account 登录。' -ForegroundColor Yellow
            Write-Host '   这个账号只用于读取好友的在线/游戏状态。' -ForegroundColor White
            Write-Host '   你真正要展示状态的主号必须已经是这个小号的好友。' -ForegroundColor White
            Write-Host ''
            Write-Host '3. 在浏览器中完成 Nintendo 授权。' -ForegroundColor White
            Write-Host ''
            Write-Host '4. 授权完成后，浏览器会跳转到类似下面的地址：' -ForegroundColor White
            Write-Host '   npf71b963c1b7b6d119://auth#session_token_code=XXXXXXXX...' -ForegroundColor Green
            Write-Host ''
            Write-Host '   如果浏览器提示无法打开此链接，这是正常现象。' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '5. 请复制浏览器地址栏中的完整地址。' -ForegroundColor White
            Write-Host '   地址必须以以下内容开头：' -ForegroundColor White
            Write-Host '   npf71b963c1b7b6d119://auth#session_token_code=' -ForegroundColor Green
            Write-Host ''
            Write-Host '6. 当 nxapi 显示：' -ForegroundColor White
            Write-Host '   请粘贴完整回调链接：' -ForegroundColor Cyan
            Write-Host '   请粘贴完整的 npf... 地址，然后按 Enter。' -ForegroundColor White
            Write-Host ''
            Write-Host '注意：' -ForegroundColor Yellow
            Write-Host ' - 不要粘贴 Nintendo 登录页面的网址。' -ForegroundColor Yellow
            Write-Host ' - 不要只粘贴 session_token_code 后面的值。' -ForegroundColor Yellow
            Write-Host ' - 不要重复使用旧的 npf... 回调链接；每次认证都要重新生成。' -ForegroundColor Yellow
            Write-Host ' - 回调代码只能使用一次，并且有效期很短。' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '现在启动 nxapi。' -ForegroundColor Cyan
            Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
            Write-Host ''

            Invoke-NxapiInteractive -Arguments @('nso','auth')
            $nintendoAuthSucceeded = $true

            Write-Host ''
            Write-Host '[Switch] Nintendo 登录命令已完成。' -ForegroundColor Green
            Write-Host '[Switch] 正在验证登录并读取好友列表...' -ForegroundColor Gray
            $friends = @(Get-NxapiFriends)

            if ($friends.Count -eq 0) {
                throw 'Nintendo 登录已完成，但好友列表为空。'
            }
        }
        if ($friends.Count -eq 0) {
            Write-Host '[Switch] 未读取到任何好友，已跳过配置。' -ForegroundColor Yellow
            return $false
        }

        Write-Host ''
        for ($i = 0; $i -lt $friends.Count; $i++) {
            $f = $friends[$i]
            $presenceState = if ($f.presence) { [string]$f.presence.state } else { 'UNKNOWN' }
            Write-Host ('[{0}] {1}   NSAID={2}   {3}' -f ($i + 1), $f.name, $f.nsaId, $presenceState)
        }

        Write-Host ''
        $selectionText = Read-Host '输入要展示状态的账号编号，直接回车可跳过'
        if ([string]::IsNullOrWhiteSpace($selectionText)) {
            Write-Host '[Switch] 已跳过。' -ForegroundColor DarkGray
            return $false
        }

        $selection = 0
        if (-not [int]::TryParse($selectionText, [ref]$selection)) {
            Write-Host '[Switch] 选择无效，已跳过配置。' -ForegroundColor Yellow
            return $false
        }
        if ($selection -lt 1 -or $selection -gt $friends.Count) {
            Write-Host '[Switch] 选择无效，已跳过配置。' -ForegroundColor Yellow
            return $false
        }

        $target = $friends[$selection - 1]
        Save-SwitchConfig -Object ([ordered]@{
            friend_nsaid = [string]$target.nsaId
            friend_name = [string]$target.name
        })

        Write-Host ''
        Write-Host ('[Switch] 已选择：{0} ({1})' -f $target.name, $target.nsaId) -ForegroundColor Green
        return $true
    } catch {
        $switchError = $_.Exception.Message

        Write-Host ''
        Write-Host ('[Switch] 配置失败：{0}' -f $switchError) -ForegroundColor Red
        Write-Host ''

        $networkFailure = (
            $switchError -match 'ECONNRESET' -or
            $switchError -match 'ETIMEDOUT' -or
            $switchError -match 'fetch failed' -or
            $switchError -match 'TLS' -or
            $switchError -match 'socket disconnected' -or
            $switchError -match 'nxapi-znca-api'
        )

        if ($networkFailure) {
            Write-Host 'Nintendo 账号登录本身可能已经成功保存。' -ForegroundColor Yellow
            if ($nintendoAuthSucceeded) {
                Write-Host '本次运行在网络错误发生前已经成功完成 Nintendo 账号认证。' -ForegroundColor Green
            }
            Write-Host '错误发生在 nxapi 访问其后端或 Nintendo 服务时。' -ForegroundColor Yellow
            Write-Host '请重新启动本程序并再次配置 Switch；程序会优先尝试复用已保存的登录。' -ForegroundColor Yellow
            Write-Host '除非程序明确要求，否则不要重新进行 Nintendo 授权。' -ForegroundColor Yellow
        } else {
            Write-Host '如果错误发生在 Nintendo 授权过程中：' -ForegroundColor Yellow
            Write-Host ' - 下次请重新开始一套新的 Nintendo 授权流程。' -ForegroundColor Yellow
            Write-Host ' - 不要重复使用上一次的 npf... 回调地址。' -ForegroundColor Yellow
            Write-Host ' - 请复制完整浏览器地址，包括 npf...://auth#session_token_code=...' -ForegroundColor Yellow
        }

        Write-Host ''
        return $false
    }
}

function New-EmptyActivityState {
    return [ordered]@{
        winner = $null
        PSN = [ordered]@{
            playing = $false
            title_id = $null
            title_name = $null
            activation_seq = 0
        }
        Switch = [ordered]@{
            playing = $false
            title_id = $null
            title_name = $null
            activation_seq = 0
        }
        sequence = 0
    }
}

function Load-ActivityState {
    if (-not (Test-Path -LiteralPath $activityPath)) {
        return New-EmptyActivityState
    }

    try {
        $obj = ([System.IO.File]::ReadAllText($activityPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        $state = New-EmptyActivityState
        if ($obj.sequence) { $state.sequence = [int64]$obj.sequence }
        if ($obj.winner) { $state.winner = [string]$obj.winner }

        foreach ($name in @('PSN','Switch')) {
            $src = $obj.$name
            if ($src) {
                $state[$name].playing = [bool]$src.playing
                if ($src.title_id) { $state[$name].title_id = [string]$src.title_id }
                if ($src.title_name) { $state[$name].title_name = [string]$src.title_name }
                if ($src.activation_seq) { $state[$name].activation_seq = [int64]$src.activation_seq }
            }
        }
        return $state
    } catch {
        return New-EmptyActivityState
    }
}

function Save-ActivityState {
    param([Parameter(Mandatory=$true)]$Activity)
    Write-Utf8NoBom -Path $activityPath -Text ($Activity | ConvertTo-Json -Depth 8)
}

function Update-ActivitySource {
    param(
        [Parameter(Mandatory=$true)]$Activity,
        [ValidateSet('PSN','Switch')][string]$Name,
        $State
    )

    $old = $Activity[$Name]
    $newPlaying = ($null -ne $State -and $State.ok -and $State.playing)
    $newTitleId = if ($newPlaying -and $State.title_id) { [string]$State.title_id } else { $null }
    $newTitleName = if ($newPlaying -and $State.title_name) { [string]$State.title_name } else { $null }

    $becameActive = (-not $old.playing -and $newPlaying)
    $changedGame = (
        $old.playing -and
        $newPlaying -and
        (
            ($newTitleId -and ([string]$old.title_id -ne $newTitleId)) -or
            ((-not $newTitleId) -and ([string]$old.title_name -ne $newTitleName))
        )
    )

    if ($becameActive -or $changedGame) {
        $Activity.sequence = [int64]$Activity.sequence + 1
        $old.activation_seq = [int64]$Activity.sequence
        Write-BridgeLog ("活动变化：{0} -> {1}" -f $Name, $newTitleName)
    }

    $old.playing = [bool]$newPlaying
    $old.title_id = $newTitleId
    $old.title_name = $newTitleName
}

function Select-ActivityWinner {
    param(
        [Parameter(Mandatory=$true)]$Activity,
        $PsnState,
        $SwitchState
    )

    $psPlaying = ($null -ne $PsnState -and $PsnState.ok -and $PsnState.playing)
    $swPlaying = ($null -ne $SwitchState -and $SwitchState.ok -and $SwitchState.playing)

    if ($psPlaying -and -not $swPlaying) { return 'PSN' }
    if ($swPlaying -and -not $psPlaying) { return 'Switch' }
    if (-not $psPlaying -and -not $swPlaying) { return $null }

    $psSeq = [int64]$Activity.PSN.activation_seq
    $swSeq = [int64]$Activity.Switch.activation_seq

    if ($psSeq -gt $swSeq) { return 'PSN' }
    if ($swSeq -gt $psSeq) { return 'Switch' }

    # On the very first run both consoles may already be playing, so exact
    # "which one was opened later" is unknowable. Reuse the previous winner
    # if available; otherwise use the configured tie preference.
    if ($Activity.winner -eq 'PSN' -or $Activity.winner -eq 'Switch') {
        return [string]$Activity.winner
    }

    $tie = 'Switch'
    if ($config.arbitration.first_start_tie_preference) {
        $tie = [string]$config.arbitration.first_start_tie_preference
    }
    if ($tie -eq 'PSN') { return 'PSN' }
    return 'Switch'
}

function Write-NoGameState {
    param([int]$Interval)
    $state = [ordered]@{
        source = 'Auto'
        ok = $true
        online = $false
        playing = $false
        online_id = $null
        account_id = $null
        platform = $null
        title_name = $null
        title_id = $null
        icon_url = $null
        total_play_time_minutes = $null
        updated_at = Get-IsoUtcNow
        poll_interval_seconds = $Interval
        error = $null
    }
    Write-BridgeState -State $state -Config $config
}

function Save-BridgeConfig {
    param([Parameter(Mandatory=$true)]$ConfigObject)

    $json = $ConfigObject | ConvertTo-Json -Depth 12
    Write-Utf8NoBom -Path $script:ConfigPath -Text $json
}

function Configure-PollInterval {
    $current = 15
    try {
        $current = [int]$config.poll_interval_seconds
    } catch {
        $current = 15
    }

    if ($current -lt 5) {
        $current = 15
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' 轮询间隔设置' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host ('当前轮询间隔：{0} 秒' -f $current)
    Write-Host '默认值为 15 秒，允许范围：5～3600 秒。' -ForegroundColor DarkGray
    Write-Host '建议不要设置得过短，以免增加接口请求频率。' -ForegroundColor DarkGray
    Write-Host ''

    $inputText = Read-Host ('输入新的轮询间隔（5～3600 秒），直接回车保持 {0} 秒' -f $current)

    if ([string]::IsNullOrWhiteSpace($inputText)) {
        $config.poll_interval_seconds = $current
        return
    }

    $newValue = 0
    if (-not [int]::TryParse($inputText.Trim(), [ref]$newValue)) {
        Write-Host ('输入不是有效整数，将继续使用 {0} 秒。' -f $current) -ForegroundColor Yellow
        $config.poll_interval_seconds = $current
        return
    }

    if ($newValue -lt 5) {
        Write-Host '轮询间隔最低为 5 秒，将使用 5 秒。' -ForegroundColor Yellow
        $newValue = 5
    }

    if ($newValue -gt 3600) {
        Write-Host '轮询间隔最高为 3600 秒，将使用 3600 秒。' -ForegroundColor Yellow
        $newValue = 3600
    }

    $config.poll_interval_seconds = $newValue

    try {
        Save-BridgeConfig -ConfigObject $config
        Write-Host ('轮询间隔已保存为 {0} 秒。' -f $newValue) -ForegroundColor Green
    } catch {
        Write-Host ('轮询间隔本次将使用 {0} 秒，但写入 config.json 失败：{1}' -f $newValue, $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Start-AutoBridge {
    $hasPsn = Test-PsnConfigured
    $hasSwitch = Test-SwitchConfigured

    if (-not $hasPsn -and -not $hasSwitch) {
        Write-Host '尚未配置任何平台，程序无法开始监控。' -ForegroundColor Yellow
        return
    }

    $interval = [int]$config.poll_interval_seconds
    if ($interval -lt 5) { $interval = 5 }

    $activity = Load-ActivityState
    Acquire-BridgeLock

    try {
        Write-Host ''
        Write-Host '已启用自动平台切换。' -ForegroundColor Cyan

        $summaryPsnState = $null
        $summarySwitchConfig = $null

        if ($hasPsn) {
            try {
                $summaryPsnState = Get-PsnPresence -Interval $interval -Config $config
            } catch {
                Write-BridgeLog ("初始 PSN 身份信息读取失败：{0}" -f $_.Exception.Message) 'WARN'
            }
        }

        if ($hasSwitch) {
            try { $summarySwitchConfig = Get-SwitchConfig } catch {}
        }

        if ($hasPsn) {
            $psnLabel = if ($summaryPsnState -and $summaryPsnState.online_id) {
                '监控中 — ' + [string]$summaryPsnState.online_id
            } else {
                '监控中'
            }
            Write-Host ('PSN    : {0}' -f $psnLabel)
        } else {
            Write-Host 'PSN    : 未配置'
        }

        if ($hasSwitch) {
            $switchLabel = if ($summarySwitchConfig -and $summarySwitchConfig.friend_name) {
                '监控中 — ' + [string]$summarySwitchConfig.friend_name
            } else {
                '监控中'
            }
            Write-Host ('Switch : {0}' -f $switchLabel)
        } else {
            Write-Host 'Switch : 未配置'
        }

        Write-Host ("轮询间隔：{0} 秒" -f $interval)
        Write-Host '最近发生“开始游戏/切换游戏”的平台将作为当前展示来源。'
        Write-Host '按 Ctrl+C 停止。'
        Write-Host ''

        Write-BridgeLog "GamePresenceBridge v0.5.4 已启动自动监控。轮询间隔=${interval}秒"

        while ($true) {
            $psState = $null
            $swState = $null

            if ($hasPsn) {
                try {
                    $psState = Get-PsnPresence -Interval $interval -Config $config
                } catch {
                    Write-BridgeLog ("PSN 轮询失败：{0}" -f $_.Exception.Message) 'ERROR'
                }
            }

            if ($hasSwitch) {
                try {
                    $swState = Get-SwitchPresence -Interval $interval -Config $config
                } catch {
                    Write-BridgeLog ("Switch 轮询失败：{0}" -f $_.Exception.Message) 'ERROR'
                }
            }

            Update-ActivitySource -Activity $activity -Name 'PSN' -State $psState
            Update-ActivitySource -Activity $activity -Name 'Switch' -State $swState

            $winner = Select-ActivityWinner -Activity $activity -PsnState $psState -SwitchState $swState
            $activity.winner = $winner
            Save-ActivityState -Activity $activity

            if ($winner -eq 'PSN') {
                Write-BridgeState -State $psState -Config $config
                Write-Host ("[PSN/{0}] {1} | {2}" -f $psState.online_id, $psState.launch_platform, $psState.title_name) -ForegroundColor Green
            } elseif ($winner -eq 'Switch') {
                Write-BridgeState -State $swState -Config $config
                Write-Host ("[Switch/{0}] {1} | {2}" -f $swState.online_id, $swState.launch_platform, $swState.title_name) -ForegroundColor Green
            } else {
                Write-NoGameState -Interval $interval
                Write-Host '[自动] 当前没有正在运行的游戏。' -ForegroundColor DarkGray
            }

            Start-Sleep -Seconds $interval
        }
    } finally {
        Remove-PresenceOutput
        Release-BridgeLock
        Write-BridgeLog 'GamePresenceBridge 已停止，presence.txt 已清理。'
    }
}

Clear-Host
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ' Game Presence Bridge - PowerShell v0.5.4' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host '按提示完成需要的配置；可选步骤直接回车即可跳过。' -ForegroundColor DarkGray
Write-Host ''

$null = Setup-PsnInteractive
$null = Setup-SwitchInteractive
Configure-PollInterval

Start-AutoBridge
