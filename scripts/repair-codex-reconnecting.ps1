[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [int]$TimeoutSeconds = 8,
    [double]$MaxRouteSeconds = 6,
    [switch]$CheckOnly,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-LoopbackProxyUri {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    foreach ($entry in ($Value -split ';')) {
        $candidate = $entry.Trim()
        if ($candidate -match '^(?i)(?:http|https)=(.+)$') { $candidate = $Matches[1].Trim() }
        if ($candidate -notmatch '^[a-z][a-z0-9+.-]*://') { $candidate = "http://$candidate" }

        try { $uri = [uri]$candidate } catch { continue }
        if ($uri.Scheme -notin @('http', 'https')) { continue }
        if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1')) { continue }
        if ($uri.Port -lt 1 -or $uri.Port -gt 65535) { continue }
        return [uri]$uri.GetLeftPart([System.UriPartial]::Authority)
    }

    return $null
}

function Get-ProxyCandidates {
    $values = [System.Collections.Generic.List[string]]::new()
    $internetSettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($internetSettings.ProxyEnable -eq 1 -and $internetSettings.ProxyServer) {
        $values.Add([string]$internetSettings.ProxyServer)
    }

    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) { $values.Add($value) }
    }

    $seen = @{}
    foreach ($value in $values) {
        $uri = ConvertTo-LoopbackProxyUri $value
        if ($uri -and -not $seen.ContainsKey($uri.AbsoluteUri)) {
            $seen[$uri.AbsoluteUri] = $true
            $uri
        }
    }
}

function Test-TcpListener {
    param([uri]$ProxyUri)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($ProxyUri.Host, $ProxyUri.Port)
        return $task.Wait(1500) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Invoke-CurlProbe {
    param(
        [uri]$ProxyUri,
        [string]$Url
    )

    $output = & curl.exe --proxy $ProxyUri.AbsoluteUri --http1.1 -4 -sS -o NUL -w '%{http_code},%{time_total}' --connect-timeout $TimeoutSeconds --max-time ($TimeoutSeconds + 4) $Url 2>$null
    $exitCode = $LASTEXITCODE
    $parts = ([string]$output).Trim() -split ','
    $seconds = if ($parts.Count -eq 2) {
        [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    } else {
        [double]::PositiveInfinity
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Status = if ($parts.Count) { $parts[0] } else { '000' }
        Seconds = $seconds
    }
}

function Test-ProxyRoute {
    param([uri]$ProxyUri)

    if (-not (Test-TcpListener $ProxyUri)) {
        return [pscustomobject]@{ Passed = $false; Score = [double]::PositiveInfinity; ChatGPT = 'listener-down'; WebSocket = 'listener-down' }
    }

    $chat = Invoke-CurlProbe $ProxyUri 'https://chatgpt.com/cdn-cgi/trace'
    $ws = Invoke-CurlProbe $ProxyUri 'https://ws.chatgpt.com/'
    $score = $chat.Seconds + $ws.Seconds
    $passed = $chat.ExitCode -eq 0 -and $chat.Status -eq '200' -and $ws.ExitCode -eq 0 -and $ws.Status -ne '000' -and $score -le $MaxRouteSeconds

    [pscustomobject]@{
        Passed = $passed
        Score = if ($passed) { $score } else { [double]::PositiveInfinity }
        ChatGPT = "$($chat.Status) in $([math]::Round($chat.Seconds, 2))s"
        WebSocket = "$($ws.Status) in $([math]::Round($ws.Seconds, 2))s"
    }
}

function Get-ControllerHints {
    $hints = [System.Collections.Generic.List[object]]::new()
    $pattern = '(?i)(?:-ext-ctl|--external-controller(?:=|\s+))\s*["'']?(127\.0\.0\.1|localhost):(?<port>\d{2,5})'

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)clash|mihomo|vortex|proxy' } |
        ForEach-Object {
            if ($_.CommandLine -match $pattern) {
                $hints.Add([pscustomobject]@{ Base = "http://127.0.0.1:$($Matches.port)"; Directory = if ($_.ExecutablePath) { Split-Path $_.ExecutablePath } else { $null } })
            }
        }

    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)clash|mihomo|vortex|proxy' -or $_.PathName -match '(?i)clash|mihomo|vortex|proxy' } |
        ForEach-Object {
            $pathMatch = [regex]::Match($_.PathName, '^\s*"([^"]+)"|^\s*([^\s]+)')
            $path = if ($pathMatch.Groups[1].Success) { $pathMatch.Groups[1].Value } else { $pathMatch.Groups[2].Value }
            if (-not $path) { return }
            $directory = Split-Path $path
            Get-ChildItem -LiteralPath $directory -Filter '*.xml' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
                if ($text -match $pattern) {
                    $hints.Add([pscustomobject]@{ Base = "http://127.0.0.1:$($Matches.port)"; Directory = $directory })
                }
            }
        }

    foreach ($port in @(9090, 9097, 39798)) {
        $hints.Add([pscustomobject]@{ Base = "http://127.0.0.1:$port"; Directory = $null })
    }

    $hints | Sort-Object Base -Unique
}

function Get-ControllerTokens {
    param([string]$Directory)

    $tokens = [System.Collections.Generic.List[string]]::new()
    $tokens.Add('')
    if (-not $Directory) { return $tokens }

    $storePath = Join-Path $Directory '.store.json'
    if (Test-Path -LiteralPath $storePath) {
        try {
            $store = Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json
            foreach ($property in @('Token', 'AppToken')) {
                if ($store.PSObject.Properties.Name -contains $property -and $store.$property) { $tokens.Add([string]$store.$property) }
            }
        } catch {}
    }

    $tokens | Select-Object -Unique
}

function Get-Utf8Json {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 4
    )

    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    foreach ($name in $Headers.Keys) { $request.Headers[$name] = [string]$Headers[$name] }

    $response = $request.GetResponse()
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $response.GetResponseStream().CopyTo($memory)
            ([Text.Encoding]::UTF8.GetString($memory.ToArray())) | ConvertFrom-Json
        } finally {
            $memory.Dispose()
        }
    } finally {
        $response.Dispose()
    }
}

function Connect-ClashController {
    foreach ($hint in Get-ControllerHints) {
        foreach ($token in Get-ControllerTokens $hint.Directory) {
            $headers = @{}
            if ($token) { $headers.Authorization = "Bearer $token" }
            try {
                $null = Get-Utf8Json "$($hint.Base)/version" $headers 2
                $proxies = Get-Utf8Json "$($hint.Base)/proxies" $headers 4
                return [pscustomobject]@{ Base = $hint.Base; Token = $token; Headers = $headers; Proxies = $proxies }
            } catch {}
        }
    }

    return $null
}

function Set-SelectorNode {
    param(
        [object]$Controller,
        [string]$Selector,
        [string]$Node
    )

    $selectorPath = [uri]::EscapeDataString($Selector)
    $body = @{ name = $Node } | ConvertTo-Json -Compress
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
    $request = [Net.HttpWebRequest]::Create("$($Controller.Base)/proxies/$selectorPath")
    $request.Method = 'PUT'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.ContentLength = $bodyBytes.Length
    $request.Timeout = 5000
    foreach ($name in $Controller.Headers.Keys) { $request.Headers[$name] = [string]$Controller.Headers[$name] }
    $stream = $request.GetRequestStream()
    try { $stream.Write($bodyBytes, 0, $bodyBytes.Length) } finally { $stream.Dispose() }
    $response = $request.GetResponse()
    $response.Dispose()
}

function Find-WorkingNode {
    param(
        [object]$Controller,
        [uri]$ProxyUri
    )

    $properties = @($Controller.Proxies.proxies.PSObject.Properties)
    $selectors = @($properties | Where-Object { $_.Value.type -eq 'Selector' -and $_.Value.all.Count -gt 0 })
    $preferredSelector = [regex]::Unescape('\u8282\u70b9\u9009\u62e9')
    $selector = $selectors | Sort-Object @{ Expression = { if ($_.Name -match "$preferredSelector|proxy") { 0 } elseif ($_.Name -eq 'GLOBAL') { 2 } else { 1 } } } | Select-Object -First 1
    if (-not $selector) { throw 'A Clash-compatible controller was found, but it exposes no selectable proxy group.' }
    Write-Verbose "Testing selector '$($selector.Name)' with $($selector.Value.all.Count) choices."

    $previous = [string]$selector.Value.now
    $blockedWords = @('\u5269\u4f59', '\u6d41\u91cf', '\u5957\u9910', '\u5230\u671f', '\u5b98\u7f51', '\u500d\u7387', '\u500d\u6d88\u8017') | ForEach-Object { [regex]::Unescape($_) }
    $blocked = '(?i)DIRECT|REJECT|traffic|expire|' + (($blockedWords | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $regions = @(
        ([regex]::Unescape('\u97e9\u56fd') + '|Korea'),
        ([regex]::Unescape('\u65e5\u672c') + '|Japan'),
        ([regex]::Unescape('\u65b0\u52a0\u5761') + '|Singapore'),
        ([regex]::Unescape('\u53f0\u6e7e') + '|Taiwan'),
        ([regex]::Unescape('\u7f8e\u56fd') + '|United States|USA'),
        ([regex]::Unescape('\u52a0\u62ff\u5927') + '|Canada'),
        ([regex]::Unescape('\u82f1\u56fd') + '|United Kingdom|UK'),
        ([regex]::Unescape('\u5fb7\u56fd') + '|Germany')
    )
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($region in $regions) {
        $matches = @($selector.Value.all | Where-Object { $_ -match $region -and $_ -notmatch $blocked } | Select-Object -First 2)
        Write-Verbose "Region '$region' matched $($matches.Count) choices."
        foreach ($name in $matches) {
            $entry = $Controller.Proxies.proxies.PSObject.Properties | Where-Object Name -EQ $name | Select-Object -First 1
            if ($entry -and $entry.Value.type -notin @('Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Direct', 'Reject')) { $candidates.Add($name) }
        }
    }
    Write-Verbose "Prepared $($candidates.Count) concrete node candidates."

    if ($candidates.Count -eq 0) { throw 'No ordinary supported-region nodes were available for automatic testing.' }

    $jobs = foreach ($name in ($candidates | Select-Object -Unique)) {
        Start-Job -ScriptBlock {
            param($Base, $Token, $Name, $Timeout)
            $headers = @{}
            if ($Token) { $headers.Authorization = "Bearer $Token" }
            $encodedName = [uri]::EscapeDataString($Name)
            function Measure-Delay([string]$Target) {
                try {
                    $encodedTarget = [uri]::EscapeDataString($Target)
                    return (Invoke-RestMethod -Uri "$Base/proxies/$encodedName/delay?timeout=$($Timeout * 1000)&url=$encodedTarget" -Headers $headers -TimeoutSec ($Timeout + 2)).delay
                } catch { return $null }
            }
            $chat = Measure-Delay 'https://chatgpt.com/cdn-cgi/trace'
            $ws = Measure-Delay 'https://ws.chatgpt.com/'
            [pscustomobject]@{ Name = $Name; Chat = $chat; WebSocket = $ws; Score = if ($chat -and $ws) { $chat + $ws } else { 999999 } }
        } -ArgumentList $Controller.Base, $Controller.Token, $name, $TimeoutSeconds
    }

    $null = Wait-Job -Job $jobs -Timeout ($TimeoutSeconds * 3 + 5)
    $results = @($jobs | Receive-Job -ErrorAction SilentlyContinue | Sort-Object Score)
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    try {
        foreach ($result in ($results | Where-Object Score -lt 999999 | Select-Object -First 4)) {
            Set-SelectorNode $Controller $selector.Name $result.Name
            Start-Sleep -Milliseconds 700
            $route = Test-ProxyRoute $ProxyUri
            if ($route.Passed) {
                return [pscustomobject]@{ Selector = $selector.Name; Previous = $previous; Selected = $result.Name; Route = $route }
            }
        }
    } catch {
        Set-SelectorNode $Controller $selector.Name $previous
        throw
    }

    Set-SelectorNode $Controller $selector.Name $previous
    throw 'All tested proxy nodes failed the real ChatGPT or WebSocket check; the original selection was restored.'
}

function Update-CodexEnvironment {
    param(
        [string]$HomePath,
        [uri]$ProxyUri
    )

    New-Item -ItemType Directory -Path $HomePath -Force | Out-Null
    $envPath = Join-Path $HomePath '.env'
    $backupPath = $null
    $preserved = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $envPath) {
        $backupPath = "$envPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $envPath -Destination $backupPath
        foreach ($line in [IO.File]::ReadAllLines($envPath)) {
            if ($line -notmatch '^(?i)\s*(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|ALL_PROXY|http_proxy|https_proxy|no_proxy|all_proxy)\s*=') { $preserved.Add($line) }
        }
    }

    while ($preserved.Count -gt 0 -and [string]::IsNullOrWhiteSpace($preserved[$preserved.Count - 1])) { $preserved.RemoveAt($preserved.Count - 1) }
    if ($preserved.Count -gt 0) { $preserved.Add('') }
    $authority = $ProxyUri.GetLeftPart([System.UriPartial]::Authority)
    $preserved.Add("HTTP_PROXY=`"$authority`"")
    $preserved.Add("HTTPS_PROXY=`"$authority`"")
    $preserved.Add('NO_PROXY="localhost,127.0.0.1,::1"')
    [IO.File]::WriteAllLines($envPath, $preserved, [Text.UTF8Encoding]::new($false))

    $written = [IO.File]::ReadAllLines($envPath)
    if (($written | Where-Object { $_ -match '^(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)="[^"]+"$' }).Count -ne 3) {
        throw "The Codex environment file failed validation: $envPath"
    }

    [pscustomobject]@{ Path = $envPath; Backup = $backupPath }
}

function Schedule-CodexRestart {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    $activation = $null
    $executable = $null

    if ($package) {
        $application = (Get-AppxPackageManifest -Package $package).Package.Applications.Application | Where-Object { $_.Executable -match 'ChatGPT\.exe$' } | Select-Object -First 1
        if ($application) { $activation = "shell:AppsFolder\$($package.PackageFamilyName)!$($application.Id)" }
    }

    if (-not $activation) {
        $executable = Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1 -ExpandProperty Path
    }

    if (-not $activation -and -not $executable) { return $false }

    $launch = if ($activation) {
        "Start-Process explorer.exe -ArgumentList '$($activation.Replace("'", "''"))'"
    } else {
        "Start-Process '$($executable.Replace("'", "''"))'"
    }
    $restartScript = "Start-Sleep -Seconds 20; Stop-Process -Name ChatGPT,codex -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; $launch"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restartScript))
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded -WindowStyle Hidden | Out-Null
    return $true
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is required but was not found.' }

$proxyUri = $null
$route = $null
foreach ($candidate in Get-ProxyCandidates) {
    $candidateRoute = Test-ProxyRoute $candidate
    if ($candidateRoute.Passed) {
        $proxyUri = $candidate
        $route = $candidateRoute
        break
    }
    if (-not $proxyUri) { $proxyUri = $candidate; $route = $candidateRoute }
}

if (-not $proxyUri) { throw 'No enabled loopback HTTP or mixed proxy was found in Windows proxy settings or the current environment.' }

$nodeChange = $null
if (-not $route.Passed) {
    if ($CheckOnly) { throw "The detected proxy $($proxyUri.Authority) cannot reach ChatGPT and node switching is disabled in CheckOnly mode." }
    $controller = Connect-ClashController
    if (-not $controller) { throw "The detected proxy $($proxyUri.Authority) is reachable locally but fails ChatGPT/WebSocket checks, and no Clash-compatible controller was discoverable." }
    $nodeChange = Find-WorkingNode $controller $proxyUri
    $route = $nodeChange.Route
}

if ($CheckOnly) {
    [pscustomobject]@{
        Status = 'healthy'
        Proxy = $proxyUri.Authority
        ChatGPT = $route.ChatGPT
        WebSocket = $route.WebSocket
        Changed = $false
        RestartScheduled = $false
    } | ConvertTo-Json
    exit 0
}

$environment = Update-CodexEnvironment $CodexHome $proxyUri
$restartScheduled = if ($NoRestart) { $false } else { Schedule-CodexRestart }

[pscustomobject]@{
    Status = 'repaired'
    Proxy = $proxyUri.Authority
    ChatGPT = $route.ChatGPT
    WebSocket = $route.WebSocket
    SelectedNode = if ($nodeChange) { $nodeChange.Selected } else { $null }
    EnvironmentFile = $environment.Path
    BackupFile = $environment.Backup
    RestartScheduled = $restartScheduled
} | ConvertTo-Json
