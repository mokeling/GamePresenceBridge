Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

$script:PsnCredentialPath = Join-Path $script:DataDir 'psn.credentials'
$script:PsnClientId = '09515159-7237-4370-9b40-3806e67c0891'
$script:PsnRedirectUri = 'com.scee.psxandroid.scecompcall://redirect'
$script:PsnScope = 'psn:mobile.v2.core psn:clientapp'
$script:PsnAuthUrl = 'https://ca.account.sony.com/api/authz/v3/oauth/authorize'
$script:PsnTokenUrl = 'https://ca.account.sony.com/api/authz/v3/oauth/token'
$script:PsnTokenBasic = 'MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A='
$script:PsnApiBase = 'https://m.np.playstation.com'
$script:PsnUserAgent = 'PlayStation/21090100 CFNetwork/1126 Darwin/19.5.0'

function New-PsnHttpClient {
    param(
        [bool]$AllowRedirect = $true,
        [string]$RequestUrl = $null,
        [hashtable]$Cookies = @{}
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $AllowRedirect
    $handler.UseCookies = $true
    $handler.CookieContainer = New-Object System.Net.CookieContainer

    if (-not [string]::IsNullOrWhiteSpace($RequestUrl) -and $Cookies.Count -gt 0) {
        $uri = New-Object System.Uri($RequestUrl)
        foreach ($key in $Cookies.Keys) {
            $cookie = New-Object System.Net.Cookie
            $cookie.Name = [string]$key
            $cookie.Value = [string]$Cookies[$key]
            $cookie.Path = '/'
            $cookie.Domain = $uri.Host
            $handler.CookieContainer.Add($cookie)
        }
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(25)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $script:PsnUserAgent)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json')
    return $client
}

function Invoke-PsnRaw {
    param(
        [ValidateSet('GET','POST')][string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [hashtable]$Cookies = @{},
        [hashtable]$Form = $null,
        [bool]$AllowRedirect = $true
    )

    $client = New-PsnHttpClient -AllowRedirect $AllowRedirect -RequestUrl $Url -Cookies $Cookies
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = New-Object System.Net.Http.HttpMethod($Method)
        $request.RequestUri = New-Object System.Uri($Url)

        foreach ($key in $Headers.Keys) {
            $null = $request.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key])
        }

        if ($null -ne $Form) {
            $pairs = New-Object 'System.Collections.Generic.Dictionary[string,string]'
            foreach ($key in $Form.Keys) {
                $pairs.Add([string]$key, [string]$Form[$key])
            }
            $request.Content = New-Object System.Net.Http.FormUrlEncodedContent($pairs)
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $location = $null
        if ($response.Headers.Location) {
            $location = $response.Headers.Location.OriginalString
        }

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            IsSuccess = $response.IsSuccessStatusCode
            Body = $body
            Location = $location
        }
    } finally {
        $client.Dispose()
    }
}

function Invoke-PsnJson {
    param(
        [ValidateSet('GET','POST')][string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [hashtable]$Cookies = @{},
        [hashtable]$Form = $null
    )
    $resp = Invoke-PsnRaw -Method $Method -Url $Url -Headers $Headers -Cookies $Cookies -Form $Form
    if (-not $resp.IsSuccess) {
        throw "PSN HTTP $($resp.StatusCode): $($resp.Body)"
    }
    if ([string]::IsNullOrWhiteSpace($resp.Body)) { return [pscustomobject]@{} }
    return $resp.Body | ConvertFrom-Json
}


function Get-SafeProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }

    return $prop.Value
}

function Get-PsnCredentials {
    return Load-EncryptedJson -Path $script:PsnCredentialPath
}

function Save-PsnCredentials {
    param([Parameter(Mandatory=$true)]$Credential)
    Save-EncryptedJson -Path $script:PsnCredentialPath -Object $Credential
}

function Set-PsnNpsso {
    param([Parameter(Mandatory=$true)][string]$Npsso)
    $obj = [ordered]@{
        npsso = $Npsso.Trim().Trim('"')
        refresh_token = $null
        account_id = $null
    }
    Save-PsnCredentials -Credential $obj
}

function Get-PsnAuthorizationCode {
    param([Parameter(Mandatory=$true)][string]$Npsso)

    Add-Type -AssemblyName System.Web

    # Build the query using application/x-www-form-urlencoded semantics,
    # matching URLSearchParams used by the current psn-api implementation.
    $query = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)
    $query['access_type'] = 'offline'
    $query['client_id'] = $script:PsnClientId
    $query['redirect_uri'] = $script:PsnRedirectUri
    $query['response_type'] = 'code'
    $query['scope'] = $script:PsnScope

    $url = $script:PsnAuthUrl + '?' + $query.ToString()

    $resp = Invoke-PsnRaw `
        -Method GET `
        -Url $url `
        -Cookies @{ npsso = $Npsso } `
        -AllowRedirect $false

    if ([string]::IsNullOrWhiteSpace($resp.Location)) {
        $detail = ''
        if (-not [string]::IsNullOrWhiteSpace($resp.Body)) {
            $detail = ' Body=' + $resp.Body.Substring(0, [Math]::Min(300, $resp.Body.Length))
        }
        throw "Sony 未返回 OAuth 跳转。HTTP $($resp.StatusCode).$detail"
    }

    $uri = New-Object System.Uri($resp.Location)
    $redirectQuery = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    $code = $redirectQuery['code']
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "OAuth 跳转中未包含授权代码。Location=$($resp.Location)"
    }
    return $code
}

function Get-PsnTokenFromCode {
    param([Parameter(Mandatory=$true)][string]$Code)
    return Invoke-PsnJson -Method POST -Url $script:PsnTokenUrl -Headers @{
        Authorization = 'Basic ' + $script:PsnTokenBasic
    } -Form @{
        code = $Code
        redirect_uri = $script:PsnRedirectUri
        grant_type = 'authorization_code'
        token_format = 'jwt'
    }
}

function Get-PsnTokenFromRefresh {
    param([Parameter(Mandatory=$true)][string]$RefreshToken)
    return Invoke-PsnJson -Method POST -Url $script:PsnTokenUrl -Headers @{
        Authorization = 'Basic ' + $script:PsnTokenBasic
    } -Form @{
        refresh_token = $RefreshToken
        grant_type = 'refresh_token'
        token_format = 'jwt'
        scope = $script:PsnScope
    }
}

function Get-PsnAccessToken {
    $cred = Get-PsnCredentials
    if ($null -eq $cred) {
        throw '尚未配置 PSN，请先完成 PSN 认证。'
    }

    $token = $null
    if ($cred.refresh_token) {
        try {
            $token = Get-PsnTokenFromRefresh -RefreshToken ([string]$cred.refresh_token)
        } catch {
            Write-BridgeLog "PSN 刷新令牌失效，尝试改用 NPSSO。" 'WARN'
        }
    }

    if ($null -eq $token) {
        if (-not $cred.npsso) {
            throw '未保存 NPSSO，请重新进行 PSN 认证。'
        }
        $code = Get-PsnAuthorizationCode -Npsso ([string]$cred.npsso)
        $token = Get-PsnTokenFromCode -Code $code
    }

    if (-not $token.access_token) {
        throw 'Sony 令牌响应中未包含 access_token。'
    }

    if ($token.refresh_token) {
        $cred.refresh_token = [string]$token.refresh_token
        Save-PsnCredentials -Credential $cred
    }

    return [string]$token.access_token
}

function Invoke-PsnApiGet {
    param(
        [string]$AccessToken,
        [string]$Path,
        [Parameter(Mandatory=$true)]$Config
    )

    $country = if ($Config.psn.country) { [string]$Config.psn.country } else { 'CN' }
    $language = if ($Config.psn.language) { [string]$Config.psn.language } else { 'zh-CN,zh;q=0.9' }

    return Invoke-PsnJson -Method GET -Url ($script:PsnApiBase + $Path) -Headers @{
        Authorization = 'Bearer ' + $AccessToken
        'Accept-Language' = $language
        Country = $country
    }
}

function Get-PsnPresence {
    param(
        [int]$Interval,
        [Parameter(Mandatory=$true)]$Config
    )

    $access = Get-PsnAccessToken
    $cred = Get-PsnCredentials

    $accountId = [string](Get-SafeProperty -Object $cred -Name 'account_id')
    if ([string]::IsNullOrWhiteSpace($accountId)) {
        $summary = Invoke-PsnApiGet -AccessToken $access -Path '/api/trophy/v1/users/me/trophySummary' -Config $Config
        $summaryAccountId = Get-SafeProperty -Object $summary -Name 'accountId'
        if (-not $summaryAccountId) {
            throw '无法获取 PSN accountId。'
        }

        $accountId = [string]$summaryAccountId
        $cred.account_id = $accountId
        Save-PsnCredentials -Credential $cred
    }

    $onlineId = $null
    try {
        $profile = Invoke-PsnApiGet -AccessToken $access -Path ("/api/userProfile/v1/internal/users/{0}/profiles" -f $accountId) -Config $Config

        $directOnlineId = Get-SafeProperty -Object $profile -Name 'onlineId'
        if ($directOnlineId) {
            $onlineId = [string]$directOnlineId
        } else {
            $profileObject = Get-SafeProperty -Object $profile -Name 'profile'
            $nestedOnlineId = Get-SafeProperty -Object $profileObject -Name 'onlineId'
            if ($nestedOnlineId) {
                $onlineId = [string]$nestedOnlineId
            }
        }
    } catch {}

    $query = 'type=primary&platforms=PS4%2CPS5%2CMOBILE_APP%2CPSPC&withOwnGameTitleInfo=true'
    $raw = Invoke-PsnApiGet -AccessToken $access -Path ("/api/userProfile/v2/internal/users/{0}/basicPresences?{1}" -f $accountId, $query) -Config $Config

    $basic = $raw
    $basicPresence = Get-SafeProperty -Object $raw -Name 'basicPresence'
    $basicPresences = Get-SafeProperty -Object $raw -Name 'basicPresences'

    if ($basicPresence) {
        $basic = $basicPresence
    } elseif ($basicPresences -and @($basicPresences).Count -gt 0) {
        $item = @($basicPresences)[0]
        $nestedBasic = Get-SafeProperty -Object $item -Name 'basicPresence'
        if ($nestedBasic) {
            $basic = $nestedBasic
        } else {
            $basic = $item
        }
    }

    $pi = Get-SafeProperty -Object $basic -Name 'primaryPlatformInfo'

    $online = $false
    $onlineStatus = Get-SafeProperty -Object $pi -Name 'onlineStatus'
    if ($onlineStatus -and ([string]$onlineStatus).ToLowerInvariant() -eq 'online') {
        $online = $true
    }

    $game = $null
    $gameList = Get-SafeProperty -Object $basic -Name 'gameTitleInfoList'
    if ($gameList -and @($gameList).Count -gt 0) {
        $game = @($gameList)[0]
    }

    $title = $null
    $npTitleId = $null
    $titleFormat = $null
    $gameStatus = $null
    $iconUrl = $null
    $launchPlatform = $null

    if ($game) {
        $v = Get-SafeProperty -Object $game -Name 'titleName'
        if ($v) { $title = [string]$v }

        $v = Get-SafeProperty -Object $game -Name 'npTitleId'
        if ($v) { $npTitleId = [string]$v }

        $v = Get-SafeProperty -Object $game -Name 'format'
        if ($v) { $titleFormat = [string]$v }

        $v = Get-SafeProperty -Object $game -Name 'gameStatus'
        if ($v) { $gameStatus = [string]$v }

        foreach ($iconField in @('conceptIconUrl','npTitleIconUrl','iconUrl')) {
            $v = Get-SafeProperty -Object $game -Name $iconField
            if ($v) {
                $iconUrl = [string]$v
                break
            }
        }

        $v = Get-SafeProperty -Object $game -Name 'launchPlatform'
        if ($v) { $launchPlatform = [string]$v }
    }

    $platform = $null
    $v = Get-SafeProperty -Object $pi -Name 'platform'
    if ($v) { $platform = [string]$v }

    if ([string]::IsNullOrWhiteSpace($launchPlatform)) {
        $launchPlatform = $platform
    }

    return [ordered]@{
        source = 'PlayStation'
        ok = $true
        online = $online
        playing = -not [string]::IsNullOrWhiteSpace($title)
        online_id = $onlineId
        account_id = $accountId
        platform = $platform
        title_name = $title
        title_id = $npTitleId
        title_format = $titleFormat
        launch_platform = $launchPlatform
        game_status = $gameStatus
        icon_url = $iconUrl
        total_play_time_minutes = $null
        updated_at = Get-IsoUtcNow
        poll_interval_seconds = $Interval
        error = $null
    }
}
