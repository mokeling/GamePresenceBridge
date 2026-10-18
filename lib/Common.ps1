Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:BridgeRoot = Split-Path -Parent $PSScriptRoot
if ((Split-Path -Leaf $PSScriptRoot) -ne 'lib') {
    $script:BridgeRoot = $PSScriptRoot
}

$script:DataDir = Join-Path $script:BridgeRoot 'data'
$script:LogsDir = Join-Path $script:BridgeRoot 'logs'
$script:StatePath = Join-Path $script:BridgeRoot 'state.json'
$script:PresencePath = Join-Path $script:BridgeRoot 'presence.txt'
$script:ConfigPath = Join-Path $script:BridgeRoot 'config.json'
$script:LockPath = Join-Path $script:DataDir 'bridge.lock'

function Initialize-BridgeDirectories {
    foreach ($p in @(
        $script:DataDir,
        $script:LogsDir,
        (Join-Path $script:DataDir 'nxapi'),
        (Join-Path $script:DataDir 'nxapi-localappdata'),
        (Join-Path $script:DataDir 'nxapi-appdata'),
        (Join-Path $script:DataDir 'npm-cache'),
        (Join-Path $script:BridgeRoot 'runtime')
    )) {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

function Get-BridgeConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "config.json not found: $script:ConfigPath"
    }
    $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
    return $raw | ConvertFrom-Json
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowEmptyString()][string]$Text
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Write-BridgeLog {
    param([string]$Message, [string]$Level = 'INFO')
    Initialize-BridgeDirectories
    $levelText = switch ($Level.ToUpperInvariant()) {
        'INFO'  { '信息' }
        'WARN'  { '警告' }
        'ERROR' { '错误' }
        default { $Level }
    }
    $line = '{0} [{1}] {2}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $levelText, $Message
    Add-Content -LiteralPath (Join-Path $script:LogsDir 'bridge.log') -Value $line -Encoding UTF8
    Write-Host $line
}

function Remove-PresenceOutput {
    try {
        if (Test-Path -LiteralPath $script:PresencePath) {
            Remove-Item -LiteralPath $script:PresencePath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Start-PresenceCleanupWatchdog {
    try {
        $watchPid = $PID
        $presencePath = $script:PresencePath

        # Escape single quotes for embedding in the child PowerShell command.
        $escapedPath = $presencePath.Replace("'", "''")

        $watchScript = @"
try {
    Wait-Process -Id $watchPid -ErrorAction SilentlyContinue
} catch {}
Start-Sleep -Milliseconds 300
try {
    Remove-Item -LiteralPath '$escapedPath' -Force -ErrorAction SilentlyContinue
} catch {}
"@

        Start-Process `
            -FilePath 'powershell.exe' `
            -WindowStyle Hidden `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-Command', $watchScript
            ) | Out-Null
    } catch {
        # Watchdog failure must never stop the bridge.
        Write-BridgeLog ('启动状态清理看门进程失败：{0}' -f $_.Exception.Message) 'WARN'
    }
}

function Get-IsoUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}


if (-not ('GamePresenceBridge.ChineseConverter' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace GamePresenceBridge {
    public static class ChineseConverter {
        private const uint LCMAP_SIMPLIFIED_CHINESE = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int LCMapStringEx(
            string lpLocaleName,
            uint dwMapFlags,
            string lpSrcStr,
            int cchSrc,
            [Out] char[] lpDestStr,
            int cchDest,
            IntPtr lpVersionInformation,
            IntPtr lpReserved,
            IntPtr sortHandle
        );

        public static string ToSimplified(string input) {
            if (String.IsNullOrEmpty(input)) return input;

            // Use -1 so Windows includes the terminating NUL in the required
            // buffer size. We then create the managed string using only the
            // exact number of characters written, excluding that NUL.
            int needed = LCMapStringEx(
                "zh-CN",
                LCMAP_SIMPLIFIED_CHINESE,
                input,
                -1,
                null,
                0,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero
            );

            if (needed <= 0) return input;

            char[] buffer = new char[needed];
            int written = LCMapStringEx(
                "zh-CN",
                LCMAP_SIMPLIFIED_CHINESE,
                input,
                -1,
                buffer,
                buffer.Length,
                IntPtr.Zero,
                IntPtr.Zero,
                IntPtr.Zero
            );

            if (written <= 0) return input;

            int length = written;
            if (length > 0 && buffer[length - 1] == '\0') length--;

            return new string(buffer, 0, length);
        }
    }
}
"@
}

function Convert-ToSimplifiedChinese {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [bool]$Enabled = $true
    )

    if (-not $Enabled -or [string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    try {
        return [GamePresenceBridge.ChineseConverter]::ToSimplified($Text)
    } catch {
        # Localization must never break Presence polling.
        return $Text
    }
}

function Write-BridgeState {
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)]$Config
    )

    $convert = $true
    if ($null -ne $Config.output -and $null -ne $Config.output.simplified_chinese) {
        $convert = [bool]$Config.output.simplified_chinese
    }

    if ($State.title_name) {
        $originalTitle = [string]$State.title_name
        $simpleTitle = Convert-ToSimplifiedChinese -Text $originalTitle -Enabled $convert

        # Preserve the source title while making title_name the normalized title
        # consumed by downstream programs.
        if ($State -is [System.Collections.IDictionary]) {
            if (-not $State.Contains('title_name_original')) {
                $State['title_name_original'] = $originalTitle
            }
            $State['title_name'] = $simpleTitle
        } else {
            if (-not ($State.PSObject.Properties.Name -contains 'title_name_original')) {
                Add-Member -InputObject $State -NotePropertyName 'title_name_original' -NotePropertyValue $originalTitle
            }
            $State.title_name = $simpleTitle
        }
    }

    $json = $State | ConvertTo-Json -Depth 12
    Write-Utf8NoBom -Path $script:StatePath -Text $json

    $text = ''
    if ($State.ok -and $State.playing -and $State.title_name) {
        $fmt = [string]$Config.output_format
        if ([string]::IsNullOrWhiteSpace($fmt)) {
            $fmt = '🎮 正在 {platform} 游玩 | {game}'
        }
        $platform = if ($State.launch_platform) { [string]$State.launch_platform } elseif ($State.platform) { [string]$State.platform } else { [string]$State.source }
        $text = $fmt.Replace('{platform}', $platform).Replace('{game}', [string]$State.title_name)
    }

    Write-Utf8NoBom -Path $script:PresencePath -Text $text
}

function Write-BridgeErrorState {
    param(
        [string]$Source,
        [string]$ErrorMessage,
        [int]$Interval,
        [Parameter(Mandatory=$true)]$Config
    )

    $state = [ordered]@{
        source = $Source
        ok = $false
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
        error = $ErrorMessage
    }

    # Keep the last presence.txt on transient errors if configured.
    $json = $state | ConvertTo-Json -Depth 8
    Write-Utf8NoBom -Path $script:StatePath -Text $json
}

function Acquire-BridgeLock {
    Initialize-BridgeDirectories

    if (Test-Path -LiteralPath $script:LockPath) {
        $oldPidText = ''
        try { $oldPidText = [System.IO.File]::ReadAllText($script:LockPath).Trim() } catch {}
        $oldPid = 0
        if ([int]::TryParse($oldPidText, [ref]$oldPid)) {
            $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProcess) {
                throw "另一个 GamePresenceBridge 实例正在运行（PID $oldPid）。"
            }
        }
        # Otherwise the lock is stale/corrupt and will be overwritten.
    }

    Write-Utf8NoBom -Path $script:LockPath -Text ([string]$PID)
}

function Release-BridgeLock {
    if (Test-Path -LiteralPath $script:LockPath) {
        try {
            $pidText = [System.IO.File]::ReadAllText($script:LockPath).Trim()
            if ($pidText -eq [string]$PID) {
                Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Protect-PortableCredential {
    param([Parameter(Mandatory=$true)][string]$PlainText)
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protected)
}

function Unprotect-PortableCredential {
    param([Parameter(Mandatory=$true)][string]$CipherText)
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String($CipherText)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Save-EncryptedJson {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    Write-Utf8NoBom -Path $Path -Text (Protect-PortableCredential -PlainText $json)
}

function Load-EncryptedJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cipher = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($cipher)) { return $null }
    $json = Unprotect-PortableCredential -CipherText $cipher
    return $json | ConvertFrom-Json
}
