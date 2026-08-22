# ======================================================================================= #
# UNBOUND BUNKER - DASHBOARD LIVE (sola lettura in RAM - BOOT ISTANTANEO ASINCRONO)    #
# ======================================================================================= #

# === CONFIGURAZIONE PERCORSI E PORTA ===
$UbDir  = "C:\Program Files\Unbound"
$Port   = 8954
$Prefix = "http://127.0.0.1:$Port/"

$UcExe      = Join-Path $UbDir "unbound-control.exe"
$HwConf     = Join-Path $UbDir "hardware.conf"
$SvcConf    = Join-Path $UbDir "service.conf"
$RpzLog     = "R:\unbound.log"
$SessionDat = "R:\session_totale.dat"
$HealthJson = "R:\bunker_health.json"
$LogFile    = "R:\dashboard_error.log"

function Write-DashLog {
    param($msg)
    try { "[$((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))] $msg" | Out-File -LiteralPath $LogFile -Append -Encoding utf8 } catch {}
}

trap {
    Write-DashLog "ERRORE NON GESTITO: $($_.Exception.Message) | Riga: $($_.InvocationInfo.ScriptLineNumber)"
    continue
}

$RpzListe = @(
    @{ Tag = "hagezi-pro-plus";   Nome = "HaGeZi Pro Plus";        Emoji = [char]::ConvertFromUtf32(0x1F947) }
    @{ Tag = "hagezi-tif";        Nome = "HaGeZi TIF";             Emoji = [char]::ConvertFromUtf32(0x1F948) }
    @{ Tag = "hagezi-tif-ips";    Nome = "HaGeZi TIF-IPS";         Emoji = [char]::ConvertFromUtf32(0x1F949) }
    @{ Tag = "spamhaus-drop-v4";  Nome = "Spamhaus DROP v4";       Emoji = [char]::ConvertFromUtf32(0x1F6E1) }
    @{ Tag = "spamhaus-drop-v6";  Nome = "Spamhaus DROP v6";       Emoji = [char]::ConvertFromUtf32(0x1F6E1) }
    @{ Tag = "hagezi-dyndns";     Nome = "HaGeZi DynDNS";          Emoji = [char]::ConvertFromUtf32(0x1F310) }
    @{ Tag = "hagezi-hoster";     Nome = "HaGeZi Badware Hoster";  Emoji = [char]::ConvertFromUtf32(0x1F4E6) }
    @{ Tag = "hagezi-spamtlds";   Nome = "HaGeZi Most Abused TLDs";Emoji = [char]::ConvertFromUtf32(0x1F6AB) }
    @{ Tag = "urlhaus";           Nome = "abuse.ch URLhaus";       Emoji = [char]::ConvertFromUtf32(0x1F9A0) }
    @{ Tag = "threatfox";         Nome = "abuse.ch ThreatFox";     Emoji = [char]::ConvertFromUtf32(0x1F578) }
)

# === ANAGRAFICA ROOT SERVERS MONDIALI (ICMP IPv4 & IPv6) ===
$script:RootServersList = @(
    @{ Tag = "A.ROOT"; Host = "a.root-servers.net"; IP = "198.41.0.4";         Operator = "Verisign, Inc." },
    @{ Tag = "A.ROOT"; Host = "a.root-servers.net"; IP = "2001:503:ba3e::2:30"; Operator = "Verisign, Inc." },
    @{ Tag = "B.ROOT"; Host = "b.root-servers.net"; IP = "199.9.14.201";       Operator = "USC-ISI" },
    @{ Tag = "B.ROOT"; Host = "b.root-servers.net"; IP = "2001:500:200::b";     Operator = "USC-ISI" },
    @{ Tag = "C.ROOT"; Host = "c.root-servers.net"; IP = "192.33.4.12";        Operator = "Cogent Communications" },
    @{ Tag = "C.ROOT"; Host = "c.root-servers.net"; IP = "2001:500:2::c";       Operator = "Cogent Communications" },
    @{ Tag = "D.ROOT"; Host = "d.root-servers.net"; IP = "199.7.91.13";        Operator = "University of Maryland" },
    @{ Tag = "D.ROOT"; Host = "d.root-servers.net"; IP = "2001:500:2d::d";      Operator = "University of Maryland" },
    @{ Tag = "E.ROOT"; Host = "e.root-servers.net"; IP = "192.203.230.10";     Operator = "NASA Ames Research Center" },
    @{ Tag = "E.ROOT"; Host = "e.root-servers.net"; IP = "2001:500:a8::e";      Operator = "NASA Ames Research Center" },
    @{ Tag = "F.ROOT"; Host = "f.root-servers.net"; IP = "192.5.5.241";        Operator = "Internet Systems Consortium (ISC)" },
    @{ Tag = "F.ROOT"; Host = "f.root-servers.net"; IP = "2001:500:2f::f";      Operator = "Internet Systems Consortium (ISC)" },
    @{ Tag = "G.ROOT"; Host = "g.root-servers.net"; IP = "192.112.36.4";       Operator = "US DoD DTIC" },
    @{ Tag = "G.ROOT"; Host = "g.root-servers.net"; IP = "2001:500:12::d0d";    Operator = "US DoD DTIC" },
    @{ Tag = "H.ROOT"; Host = "h.root-servers.net"; IP = "198.97.190.53";      Operator = "US Army Research Lab" },
    @{ Tag = "H.ROOT"; Host = "h.root-servers.net"; IP = "2001:500:1::53";      Operator = "US Army Research Lab" },
    @{ Tag = "I.ROOT"; Host = "i.root-servers.net"; IP = "192.36.148.17";      Operator = "Netnod (Autonomica)" },
    @{ Tag = "I.ROOT"; Host = "i.root-servers.net"; IP = "2001:7fe::53";        Operator = "Netnod (Autonomica)" },
    @{ Tag = "J.ROOT"; Host = "j.root-servers.net"; IP = "192.58.128.30";      Operator = "Verisign, Inc." },
    @{ Tag = "J.ROOT"; Host = "j.root-servers.net"; IP = "2001:503:c27::2:30"; Operator = "Verisign, Inc." },
    @{ Tag = "K.ROOT"; Host = "k.root-servers.net"; IP = "193.0.14.129";       Operator = "RIPE NCC" },
    @{ Tag = "K.ROOT"; Host = "k.root-servers.net"; IP = "2001:7fd::1";         Operator = "RIPE NCC" },
    @{ Tag = "L.ROOT"; Host = "l.root-servers.net"; IP = "199.7.83.42";        Operator = "ICANN" },
    @{ Tag = "L.ROOT"; Host = "l.root-servers.net"; IP = "2001:500:9f::42";     Operator = "ICANN" },
    @{ Tag = "M.ROOT"; Host = "m.root-servers.net"; IP = "202.12.27.33";       Operator = "WIDE Project" },
    @{ Tag = "M.ROOT"; Host = "m.root-servers.net"; IP = "2001:dc3::35";        Operator = "WIDE Project" }
)

# === RACCOLTA DATI BANDA E HARDWARE ===

function Get-NetworkSpeed {
    try {
        $nics = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue |
                Where-Object { $_.BytesTotalPersec -ge 0 -and $_.Name -notmatch 'Loopback|vEthernet|Virtual|VPN|ISATAP|Teredo' } |
                Select-Object -First 1
        if ($nics) {
            $downMbps = [math]::Round(($nics.BytesReceivedPersec * 8) / 1MB, 1)
            $upMbps   = [math]::Round(($nics.BytesSentPersec * 8) / 1MB, 1)
            return @{ down_mbps = $downMbps; up_mbps = $upMbps; ok = $true }
        }
    } catch {}
    return @{ down_mbps = 0; up_mbps = 0; ok = $false }
}

function Get-HardwareTier {
    $result = [ordered]@{ ram_gb = $null; profilo = "N/D" }
    if (Test-Path $HwConf) {
        try {
            $line = Get-Content -LiteralPath $HwConf | Where-Object { $_ -match 'Rilevati:\s*(\d+)\s*GB RAM.*Profilo:\s*(\S+)' } | Select-Object -First 1
            if ($line -match 'Rilevati:\s*(\d+)\s*GB RAM.*Profilo:\s*(\S+)') {
                $result.ram_gb = [int]$matches[1]
                $result.profilo = $matches[2]
            }
        } catch {}
    }
    return $result
}

function Get-RamDiskGauge {
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='R:'" -ErrorAction SilentlyContinue
        if ($disk -and $disk.Size -gt 0) {
            $tot = [math]::Round($disk.Size / 1MB, 1)
            $used = [math]::Round(($disk.Size - $disk.FreeSpace) / 1MB, 1)
            $pct = [math]::Round(($used / $tot) * 100, 1)
            return @{ tot_mb = $tot; used_mb = $used; pct = $pct; attivo = $true }
        }
    } catch {}
    return @{ tot_mb = 50; used_mb = 0; pct = 0; attivo = $false }
}

function Get-UnboundWorkingSet {
    try {
        $p = Get-Process -Name "unbound" -ErrorAction SilentlyContinue | Select-Object -First 1
        $sysRamMb = 0
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os -and $os.TotalVisibleMemorySize) {
                $sysRamMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            }
        } catch {}
        if ($sysRamMb -eq 0) {
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
                if ($cs -and $cs.TotalPhysicalMemory) {
                    $sysRamMb = [math]::Round($cs.TotalPhysicalMemory / 1MB, 0)
                }
            } catch {}
        }

        if ($p) {
            $wsMb = [math]::Round($p.WorkingSet64 / 1MB, 1)
            $pct = if ($sysRamMb -gt 0) { [math]::Round(($wsMb / $sysRamMb) * 100, 2) } else { 0 }
            return @{ ws_mb = $wsMb; pid = $p.Id; sys_ram_mb = $sysRamMb; pct_sys = $pct }
        } else {
            return @{ ws_mb = 0; pid = "N/A"; sys_ram_mb = $sysRamMb; pct_sys = 0 }
        }
    } catch {}
    return @{ ws_mb = 0; pid = "N/A"; sys_ram_mb = 0; pct_sys = 0 }
}

$script:TotalRpzRulesCache = $null
$script:TotalRpzRulesCacheTime = [DateTime]::MinValue

function Get-TotalRpzRulesCount {
    if (((Get-Date) - $script:TotalRpzRulesCacheTime).TotalSeconds -ge 600 -or -not $script:TotalRpzRulesCache) {
        $tot = 0
        $dettaglio = @()
        $confFiles = Get-ChildItem -Path $UbDir -Filter "*.conf" -ErrorAction SilentlyContinue
        foreach ($lista in $RpzListe) {
            $cnt = 0
            $matchingFiles = $confFiles | Where-Object { $_.Name -match [regex]::Escape($lista.Tag) }
            foreach ($f in $matchingFiles) {
                try {
                    $cnt += [System.Linq.Enumerable]::Count([System.IO.File]::ReadLines($f.FullName))
                } catch {}
            }
            $tot += $cnt
            $dettaglio += @{ nome = $lista.Nome; emoji = $lista.Emoji; regole = $cnt }
        }
        $script:TotalRpzRulesCache = @{ totale = $tot; dettaglio = $dettaglio }
        $script:TotalRpzRulesCacheTime = Get-Date
    }
    return $script:TotalRpzRulesCache
}

function Get-ConfiguredCacheSizeMb {
    $totalMb = 0
    if (Test-Path $HwConf) {
        try {
            $lines = Get-Content -LiteralPath $HwConf -ErrorAction SilentlyContinue
            foreach ($ln in $lines) {
                if ($ln -match 'msg-cache-size:\s*(\d+)([mGkM]?)') {
                    $val = [double]$matches[1]
                    $unit = $matches[2].ToUpper()
                    if ($unit -eq 'G') { $totalMb += ($val * 1024) }
                    elseif ($unit -eq 'K') { $totalMb += ($val / 1024) }
                    else { $totalMb += $val }
                }
                if ($ln -match 'rrset-cache-size:\s*(\d+)([mGkM]?)') {
                    $val = [double]$matches[1]
                    $unit = $matches[2].ToUpper()
                    if ($unit -eq 'G') { $totalMb += ($val * 1024) }
                    elseif ($unit -eq 'K') { $totalMb += ($val / 1024) }
                    else { $totalMb += $val }
                }
            }
        } catch {}
    }
    if ($totalMb -eq 0) { $totalMb = 384 }
    return $totalMb
}

function Get-HardeningStatus {
    $score = 100
    $dettaglio = @()

    try {
        $chromeDoh = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "DnsOverHttpsMode" -ErrorAction SilentlyContinue).DnsOverHttpsMode
        $okChromeDoh = ($chromeDoh -eq "off")
        if (-not $okChromeDoh) { $score -= 20 }
    } catch { $okChromeDoh = $false; $score -= 20 }
    $dettaglio += @{ nome = "DoH disattivato (Chrome)"; ok = $okChromeDoh }

    try {
        $edgeDoh = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "DnsOverHttpsMode" -ErrorAction SilentlyContinue).DnsOverHttpsMode
        $okEdgeDoh = ($edgeDoh -eq "off")
        if (-not $okEdgeDoh) { $score -= 20 }
    } catch { $okEdgeDoh = $false; $score -= 20 }
    $dettaglio += @{ nome = "DoH disattivato (Edge)"; ok = $okEdgeDoh }

    try {
        $idnChrome = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Google\Chrome" -Name "IDNPolicy" -ErrorAction SilentlyContinue).IDNPolicy
        $okIdnChrome = ($idnChrome -eq 1)
        if (-not $okIdnChrome) { $score -= 20 }
    } catch { $okIdnChrome = $false; $score -= 20 }
    $dettaglio += @{ nome = "IDN Policy (Chrome)"; ok = $okIdnChrome }

    try {
        $smartDns = (Get-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient" -Name "DisableSmartNameResolution" -ErrorAction SilentlyContinue).DisableSmartNameResolution
        $okSmartDns = ($smartDns -eq 1)
        if (-not $okSmartDns) { $score -= 20 }
    } catch { $okSmartDns = $false; $score -= 20 }
    $dettaglio += @{ nome = "Smart Multi-Homed Name Resolution disattivata"; ok = $okSmartDns }

    if ($score -lt 0) { $score = 0 }
    return @{ score = $score; dettaglio = $dettaglio }
}

$script:NtpCacheTime = [DateTime]::MinValue
$script:NtpCacheData = @{ ok = $false; dettaglio = @(); okCount = 0; totCount = 0; desc = "In attesa del primo test" }

function Get-NtpStatus {
    if (((Get-Date) - $script:NtpCacheTime).TotalSeconds -lt 1800) {
        return $script:NtpCacheData
    }

    $serversToTest = @(
        @{ nome = "INRIM primario (ntp.inrim.it)";    host = "ntp.inrim.it" },
        @{ nome = "INRIM secondario (ntp1.inrim.it)"; host = "ntp1.inrim.it" },
        @{ nome = "Cloudflare (time.cloudflare.com)"; host = "time.cloudflare.com" },
        @{ nome = "Pool IT (it.pool.ntp.org)";        host = "it.pool.ntp.org" }
    )

    $dettaglio = @()
    $okCount = 0
    foreach ($s in $serversToTest) {
        $ok = $false
        try {
            $res = w32tm /stripchart /computer:$($s.host) /samples:1 /dataonly 2>$null
            $ok = ($LASTEXITCODE -eq 0) -and ($res -match '\d')
        } catch { $ok = $false }
        if ($ok) { $okCount++ }
        $dettaglio += @{ nome = $s.nome; ok = $ok }
    }

    $script:NtpCacheData = @{
        ok        = ($okCount -gt 0)
        dettaglio = $dettaglio
        okCount   = $okCount
        totCount  = $serversToTest.Count
        desc      = "$okCount / $($serversToTest.Count) peer raggiunti"
    }
    $script:NtpCacheTime = Get-Date
    return $script:NtpCacheData
}

function Get-HyperlocalStatus {
    if (Test-Path $SvcConf) {
        try {
            $raw = Get-Content -LiteralPath $SvcConf -ErrorAction SilentlyContinue
            if ($raw -match 'auth-zone:' -and $raw -match 'name:\s*"\."') {
                return @{
                    attivo    = $true
                    desc      = "Attivo (RFC 8806 - RAM Local)"
                    dettaglio = @(
                        @{ nome = "Zona di Autenticazione Root (.)"; ok = $true },
                        @{ nome = "Servizio Root Server Locale RAM"; ok = $true },
                        @{ nome = "Fallback Automatico Upstream"; ok = $true }
                    )
                }
            }
        } catch {}
    }
    return @{
        attivo    = $false
        desc      = "Disattivato"
        dettaglio = @(
            @{ nome = "Zona di Autenticazione Root (.)"; ok = $false },
            @{ nome = "Servizio Root Server Locale RAM"; ok = $false }
        )
    }
}

# === CACHE PER IP WAN E GEOLOCALIZZAZIONE ===
$script:WanCacheTime = [DateTime]::MinValue
$script:WanCacheData = @{
    ipv4_wan    = "N/D"
    ipv4_wan_ok = $false
    ipv4_loc    = ""
    ipv6_wan    = "N/D"
    ipv6_wan_ok = $false
    ipv6_loc    = ""
}

function Get-IpConnectivityStatus {
    $ip4Lan = $null
    try {
        $ip4Lan = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress
    } catch {}

    $ip6Lan = $null
    try {
        $ip6Lan = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^fe80:|^::1$' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.AddressState -eq 'Preferred' } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -First 1 -ExpandProperty IPAddress
    } catch {}

    if (((Get-Date) - $script:WanCacheTime).TotalSeconds -ge 30) {
        $ip4Wan = "N/D"
        $loc4   = ""
        
        try {
            $r4 = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,city,country,isp,query' -TimeoutSec 1 -ErrorAction Stop
            if ($r4.status -eq 'success') {
                $ip4Wan = $r4.query
                $city4  = if ($r4.city) { $r4.city } else { $r4.isp }
                $loc4   = @($city4, $r4.country) -join ', '
            }
        } catch {
            try {
                $r4 = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 1 -ErrorAction Stop
                if ($r4.ip) {
                    $ip4Wan = $r4.ip
                    $loc4   = @($r4.city, $r4.country) -join ', '
                }
            } catch {}
        }

        $ip6Wan = "N/D"
        $loc6   = ""
        
        try {
            $r6 = Invoke-RestMethod -Uri 'https://ipapi.co/json/' -TimeoutSec 1 -ErrorAction Stop
            if ($r6.ip -match ':') {
                $ip6Wan = $r6.ip
                $city6  = if ($r6.city) { $r6.city } else { $r6.org }
                $loc6   = @($city6, $r6.country_code) -join ', '
            }
        } catch {
            try {
                $raw6 = (Invoke-WebRequest -Uri 'https://ipv6.icanhazip.com' -TimeoutSec 1 -UseBasicParsing).Content.Trim()
                if ($raw6 -match ':') { 
                    $ip6Wan = $raw6 
                    $loc6   = "Cloudflare WARP"
                }
            } catch {}
        }

        if ($ip4Wan -ne "N/D" -or $ip6Wan -ne "N/D") {
            $script:WanCacheData = @{
                ipv4_wan    = $ip4Wan
                ipv4_wan_ok = ($ip4Wan -ne "N/D")
                ipv4_loc    = $loc4
                ipv6_wan    = $ip6Wan
                ipv6_wan_ok = ($ip6Wan -ne "N/D")
                ipv6_loc    = $loc6
            }
            $script:WanCacheTime = Get-Date
        }
    }

    return [ordered]@{
        ipv4_lan    = if ($ip4Lan) { $ip4Lan } else { "N/D" }
        ipv4_lan_ok = [bool]$ip4Lan
        ipv6_lan    = if ($ip6Lan) { $ip6Lan } else { "N/D" }
        ipv6_lan_ok = [bool]$ip6Lan
        ipv4_wan    = $script:WanCacheData.ipv4_wan
        ipv4_wan_ok = $script:WanCacheData.ipv4_wan_ok
        ipv4_loc    = $script:WanCacheData.ipv4_loc
        ipv6_wan    = $script:WanCacheData.ipv6_wan
        ipv6_wan_ok = $script:WanCacheData.ipv6_wan_ok
        ipv6_loc    = $script:WanCacheData.ipv6_loc
    }
}

# === CACHE VERSIONI CLOUD ===
$script:CloudVersionsCache       = $null
$script:CloudVersionsCacheTime   = [DateTime]::MinValue
$script:CloudVersionsCacheTtlSec = 1800

function Get-BunkerVersions {
    param([switch]$Force)
    $result = [ordered]@{ unbound_local = "N/D"; unbound_cloud = "N/D"; conf_local = "N/D"; conf_cloud = "N/D"; bat_local = "N/D"; bat_cloud = "N/D" }

    $ubExe = Join-Path $UbDir "unbound.exe"
    if (Test-Path $ubExe) {
        try {
            $raw = & $ubExe -h 2>&1 | Out-String
            if ($raw -match 'Version\s+([0-9\.]+)') { $result.unbound_local = $matches[1] }
        } catch {}
    }

    $svcVerFile = Join-Path $UbDir "versione_service_conf.txt"
    if (Test-Path $svcVerFile) {
        try { $result.conf_local = (Get-Content -LiteralPath $svcVerFile -Raw).Trim() } catch {}
    }

    $batFile = Join-Path $UbDir "UnboundBunkerManager.BAT"
    if (Test-Path $batFile) {
        try {
            $line = Get-Content -LiteralPath $batFile | Where-Object { $_ -match 'set .LOCAL_VER=([0-9]+\.[0-9]+)' } | Select-Object -First 1
            if ($line -match '([0-9]+\.[0-9]+)') { $result.bat_local = $matches[1] }
        } catch {}
    }

    $cloudStale = $Force -or (-not $script:CloudVersionsCache) -or ((Get-Date) - $script:CloudVersionsCacheTime).TotalSeconds -ge $script:CloudVersionsCacheTtlSec
    if ($cloudStale) {
        if (-not $script:CloudVersionsCache) { $script:CloudVersionsCache = [ordered]@{ unbound_cloud = "N/D"; conf_cloud = "N/D"; bat_cloud = "N/D" } }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $json = (Invoke-WebRequest -Uri 'https://api.github.com/repos/NLnetLabs/unbound/releases/latest' -UseBasicParsing -TimeoutSec 1).Content | ConvertFrom-Json
            if ($json.tag_name -match 'release-(.*)') { $script:CloudVersionsCache.unbound_cloud = $matches[1] } else { $script:CloudVersionsCache.unbound_cloud = $json.tag_name }
        } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_service.txt' -UseBasicParsing -TimeoutSec 1).Content.Trim(); if($v){$script:CloudVersionsCache.conf_cloud = $v} } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_bat.txt' -UseBasicParsing -TimeoutSec 1).Content.Trim(); if($v){$script:CloudVersionsCache.bat_cloud = $v} } catch {}
        $script:CloudVersionsCacheTime = Get-Date
    }

    $result.unbound_cloud = $script:CloudVersionsCache.unbound_cloud
    $result.conf_cloud    = $script:CloudVersionsCache.conf_cloud
    $result.bat_cloud     = $script:CloudVersionsCache.bat_cloud
    return $result
}

function Get-EngineStatus {
    $svc = Get-Service -Name "unbound" -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq "Running")
}

# === CACHE CONDIVISA TAIL LOG ===
$script:LogTailCacheTime   = [DateTime]::MinValue
$script:LogTailCacheLines  = @()
$script:LogTailCacheTtlSec = 2

function Get-RpzLogTailCached {
    if (((Get-Date) - $script:LogTailCacheTime).TotalSeconds -ge $script:LogTailCacheTtlSec -or $script:LogTailCacheLines.Count -eq 0) {
        $lines = @()
        if ([System.IO.File]::Exists($RpzLog)) {
            try { $lines = Get-Content -LiteralPath $RpzLog -Tail 1000 -ErrorAction SilentlyContinue } catch {}
        }
        $script:LogTailCacheLines = $lines
        $script:LogTailCacheTime  = Get-Date
    }
    return $script:LogTailCacheLines
}

# === LIVE FEED RCODE ===
function Get-LiveRcodeFeed {
    $feed = @()
    $zap    = "$([char]0x26A1) Cache RAM"
    $globe  = [char]::ConvertFromUtf32(0x1F310)
    $shield = [char]::ConvertFromUtf32(0x1F6E1)

    $lines = Get-RpzLogTailCached
    if ($lines -and $lines.Count -gt 0) {
        try {
            $currentUpstream = $zap
            
            foreach ($ln in $lines) {
                if ($ln -match 'info:\s+sending query to\s+([0-9a-fA-F.:]+)(?:@\d+)?') {
                    $ip = $matches[1]
                    $currentUpstream = switch -Wildcard ($ip) {
                        "*194.242.2.2*"      { "$globe Mullvad ($ip)" }
                        "*9.9.9.10*"        { "$globe Quad9 ($ip)" }
                        "*149.112.112.10*"  { "$globe Quad9 ($ip)" }
                        "*1.1.1.1*"         { "$globe Cloudflare ($ip)" }
                        "*1.0.0.1*"         { "$globe Cloudflare ($ip)" }
                        "*8.8.8.8*"         { "$globe Google ($ip)" }
                        "*8.8.4.4*"         { "$globe Google ($ip)" }
                        "*76.76.2.11*"      { "$globe Control D ($ip)" }
                        "*76.76.10.11*"     { "$globe Control D ($ip)" }
                        "*208.67.222.222*"  { "$globe OpenDNS ($ip)" }
                        "*208.67.220.220*"  { "$globe OpenDNS ($ip)" }
                        default             { "$globe Upstream ($ip)" }
                    }
                }
                elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\s+info:\s+\S+\s+(\S+)\s+\S+\s+IN\s+(NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR)') {
                    $feed += @{
                        orario   = $matches[1]
                        dominio  = $matches[2].TrimEnd('.')
                        rcode    = $matches[3].ToUpper()
                        resolver = $currentUpstream
                    }
                    $currentUpstream = $zap
                }
                elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\[([a-zA-Z0-9_\-]+)\]\s+(\S+)\s+rpz-(nxdomain|nodata|passthru)') {
                    $rcodeMap = if ($matches[4] -eq 'nxdomain') { "NXDOMAIN" } else { "NOERROR" }
                    $feed += @{
                        orario    = $matches[1]
                        dominio   = $matches[3].TrimEnd('.')
                        rcode     = $rcodeMap
                        resolver  = "$shield Scudo RPZ"
                        rpz_lista = $matches[2]
                    }
                }
            }
        } catch {}
    }
    if ($feed.Count -gt 0) {
        $lastFeed = $feed | Select-Object -Last 300
        $reversed = @()
        for ($i = $lastFeed.Count - 1; $i -ge 0; $i--) {
            $reversed += $lastFeed[$i]
        }
        return $reversed
    }
    return @()
}

# === UPSTREAM RADAR (DOT PORTA 853) ===
$script:RadarCacheTime = [DateTime]::MinValue
$script:RadarCacheData = @()

function Get-UpstreamRadar {
    if (((Get-Date) - $script:RadarCacheTime).TotalSeconds -ge 8 -or $script:RadarCacheData.Count -eq 0) {
        $radar = New-Object System.Collections.Generic.List[psobject]
        if (Test-Path $SvcConf) {
            try {
                $lines = Get-Content -LiteralPath $SvcConf -ErrorAction SilentlyContinue
                $lastResolverName = ""

                foreach ($ln in $lines) {
                    $trimmed = $ln.Trim()

                    if ($trimmed -match 'NOME RESOLVER:\s*(.*)') {
                        $lastResolverName = $matches[1].Trim()
                    }
                    elseif ($trimmed.StartsWith('#') -and $trimmed -notmatch 'NOME RESOLVER:') {
                        $lastResolverName = ""
                    }
                    elseif ($trimmed -match 'forward-addr:\s*(\S+?)@(\d+)(?:#(\S+))?') {
                        $ip   = $matches[1]
                        $port = [int]$matches[2]
                        $sni  = $matches[3]

                        $tagName = if ($lastResolverName) { $lastResolverName } elseif ($sni) { $sni } else { "Upstream" }

                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        $ok = $false
                        try {
                            $ipObj = [System.Net.IPAddress]::Parse($ip)
                            $tcp   = New-Object System.Net.Sockets.TcpClient($ipObj.AddressFamily)
                            $ar    = $tcp.BeginConnect($ipObj, $port, $null, $null)
                            if ($ar.AsyncWaitHandle.WaitOne(400, $false)) {
                                $tcp.EndConnect($ar)
                                $ok = $tcp.Connected
                            }
                            $tcp.Close()
                        } catch {}
                        $sw.Stop()
                        $ms = if ($ok) { $sw.ElapsedMilliseconds } else { 999 }

                        $radar.Add([pscustomobject]@{
                            ip   = $ip
                            tag  = $tagName
                            port = $port
                            ok   = $ok
                            ms   = $ms
                        })
                    }
                }
            } catch {}
        }
        
        $sortedRadar = $radar | Sort-Object @{Expression={$_.ok}; Descending=$true}, @{Expression={$_.ms}; Ascending=$true}
        $script:RadarCacheData = @($sortedRadar)
        $script:RadarCacheTime = Get-Date
    }
    return $script:RadarCacheData
}

# === ROOT SERVERS RADAR ===
$script:RootRadarCacheTime = [DateTime]::MinValue
$script:RootRadarCacheData = @()

function Get-RootServersRadar {
    if (((Get-Date) - $script:RootRadarCacheTime).TotalSeconds -ge 12 -or $script:RootRadarCacheData.Count -eq 0) {
        $results = New-Object System.Collections.Generic.List[psobject]

        $pings = foreach ($rs in $script:RootServersList) {
            [pscustomobject]@{
                tag      = $rs.Tag
                ip       = $rs.IP
                operator = $rs.Operator
                task     = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($rs.IP, 400)
            }
        }

        foreach ($p in $pings) {
            $ms = 999
            $ok = $false
            try {
                if ($p.task.Wait(400)) {
                    $res = $p.task.Result
                    if ($res -and $res.Status -eq "Success") {
                        $ok = $true
                        $ms = $res.RoundtripTime
                    }
                }
            } catch {}

            $results.Add([pscustomobject]@{
                tag      = $p.tag
                ip       = $p.ip
                operator = $p.operator
                ok       = $ok
                ms       = $ms
            })
        }

        $sortedRoot = $results | Sort-Object @{Expression={$_.ok}; Descending=$true}, @{Expression={$_.ms}; Ascending=$true}
        $script:RootRadarCacheData = @($sortedRoot)
        $script:RootRadarCacheTime = Get-Date
    }
    return $script:RootRadarCacheData
}

# === LIVE STATS ESTESE ===
function Get-LiveStats {
    $base   = [ordered]@{ query_totali = 0; cache_hits = 0; cache_efficienza_pct = 0; uptime_secondi = 0; latenza_ms = 0; blocchi_pct = 0; qps_medio = 0; cache_mem_bytes = 0; ratelimited_queries = 0; tcp_queries = 0; udp_queries = 0; unwanted_queries = 0; unwanted_replies = 0 }
    $rcode  = [ordered]@{ noerror = 0; nxdomain = 0; servfail = 0 }
    $types  = [ordered]@{ type_a = 0; type_aaaa = 0; type_https = 0; type_altro = 0 }
    $dnssec = [ordered]@{ secure = 0; bogus = 0 }
    $prefetch = 0
    $recMs = 0
    $memCacheRrset = 0
    $memCacheMsg   = 0
    $rateLimitedDomain = 0
    $rateLimitedIp     = 0

    if (Test-Path $UcExe) {
        try {
            $raw = & $UcExe stats_noreset 2>$null
            foreach ($ln in $raw) {
                if ($ln -match '^([a-zA-Z0-9_.\-]+)=(.+)$') {
                    $k = $matches[1]
                    $v = [double]$matches[2].Trim()
                    if ($k -eq "total.num.queries")         { $base.query_totali = $v }
                    if ($k -eq "total.num.cachehits")        { $base.cache_hits   = $v }
                    if ($k -eq "time.up")                    { $base.uptime_secondi = $v }
                    if ($k -eq "total.recursion.time.avg")   { $recMs = $v * 1000 }
                    if ($k -eq "num.answer.rcode.NOERROR")   { $rcode.noerror   = $v }
                    if ($k -eq "num.answer.rcode.NXDOMAIN")  { $rcode.nxdomain  = $v }
                    if ($k -eq "num.answer.rcode.SERVFAIL")  { $rcode.servfail  = $v }
                    if ($k -eq "num.query.type.A")           { $types.type_a    = $v }
                    if ($k -eq "num.query.type.AAAA")        { $types.type_aaaa = $v }
                    if ($k -eq "num.query.type.HTTPS")       { $types.type_https= $v }
                    if ($k -eq "num.answer.secure")          { $dnssec.secure   = $v }
                    if ($k -eq "num.answer.bogus")           { $dnssec.bogus    = $v }
                    if ($k -eq "num.prefetch" -or $k -eq "num.query.prefetch") { $prefetch = $v }
                    if ($k -eq "mem.cache.rrset")            { $memCacheRrset = $v }
                    if ($k -eq "mem.cache.message")          { $memCacheMsg   = $v }
                    if ($k -eq "num.query.ratelimited")      { $rateLimitedDomain += $v }
                    if ($k -eq "num.query.ip_ratelimited")   { $rateLimitedIp += $v }
                    if ($k -eq "num.query.tcp")              { $base.tcp_queries = $v }
                    if ($k -eq "unwanted.queries")           { $base.unwanted_queries = $v }
                    if ($k -eq "unwanted.replies")           { $base.unwanted_replies = $v }
                }
            }
            $base.cache_mem_bytes = $memCacheRrset + $memCacheMsg
            $base.ratelimited_queries = $rateLimitedDomain + $rateLimitedIp
            $base.udp_queries = [math]::Max(0, $base.query_totali - $base.tcp_queries)
            $types.type_altro = [math]::Max(0, $base.query_totali - ($types.type_a + $types.type_aaaa + $types.type_https))

            if ($base.uptime_secondi -gt 0) {
                $base.qps_medio = [math]::Round($base.query_totali / $base.uptime_secondi, 2)
            }
            if ($base.query_totali -gt 0) {
                $base.cache_efficienza_pct = [math]::Round(($base.cache_hits / $base.query_totali) * 100, 1)
                $base.latenza_ms = [math]::Round($recMs, 1)
            }
        } catch {}
    }
    return @{
        base               = $base
        rcode              = $rcode
        types              = $types
        dnssec             = $dnssec
        prefetch           = $prefetch
        mem_cache_rrset    = $memCacheRrset
        mem_cache_msg      = $memCacheMsg
        ratelimit_domain   = $rateLimitedDomain
        ratelimit_ip       = $rateLimitedIp
    }
}

$script:RpzBreakdownCache       = $null
$script:RpzBreakdownCacheTime   = [DateTime]::MinValue
$script:RpzBreakdownCacheTtlSec = 15

function Get-RpzBreakdown {
    if ($script:RpzBreakdownCache -and ((Get-Date) - $script:RpzBreakdownCacheTime).TotalSeconds -lt $script:RpzBreakdownCacheTtlSec) {
        return $script:RpzBreakdownCache
    }

    $liste = @()
    $blkTotale = 0
    $rpzLines = $null
    if ([System.IO.File]::Exists($RpzLog)) {
        try { $rpzLines = Get-Content -LiteralPath $RpzLog -ErrorAction SilentlyContinue } catch {}
    }
    foreach ($lista in $RpzListe) {
        $domini = @()
        $conteggioLista = 0
        if ($rpzLines) {
            $rx = [regex]("\[" + [regex]::Escape($lista.Tag) + "\]\s+(\S+)\s+rpz-nxdomain")
            $matchDomini = foreach ($ln in $rpzLines) {
                $mm = $rx.Match($ln)
                if ($mm.Success) { $mm.Groups[1].Value.TrimEnd('.') }
            }
            if ($matchDomini) {
                $grp = $matchDomini | Group-Object | Sort-Object Count -Descending
                foreach ($g in $grp) {
                    $dn = $g.Name
                    $wildcard = $false
                    if ($dn.StartsWith("*.")) { $dn = $dn.Substring(2); $wildcard = $true }
                    $dn = $dn -replace '[*_\[\]`]', ''
                    $domini += @{ dominio = $dn; wildcard = $wildcard; conteggio = $g.Count }
                    $conteggioLista += $g.Count
                }
            }
        }
        $liste += @{ tag = $lista.Tag; nome = $lista.Nome; emoji = $lista.Emoji; conteggio = $conteggioLista; domini = $domini }
        $blkTotale += $conteggioLista
    }
    $result = @{ totale = $blkTotale; liste = $liste }
    $script:RpzBreakdownCache     = $result
    $script:RpzBreakdownCacheTime = Get-Date
    return $result
}

function Get-SessionTotal {
    if ([System.IO.File]::Exists($SessionDat)) {
        try { return (Get-Content -LiteralPath $SessionDat -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Get-HealthSnapshot {
    if ([System.IO.File]::Exists($HealthJson)) {
        try { return (Get-Content -LiteralPath $HealthJson -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

function Get-BunkerStatusJson {
    param([switch]$ForceVersions)
    $hw          = Get-HardwareTier
    $ramDisk     = Get-RamDiskGauge
    $versioni    = Get-BunkerVersions -Force:$ForceVersions
    $engineOn    = Get-EngineStatus
    $stats       = Get-LiveStats
    $liveRcode   = Get-LiveRcodeFeed
    $radar       = Get-UpstreamRadar
    $rootRadar   = Get-RootServersRadar
    $rpz         = Get-RpzBreakdown
    $sessione    = Get-SessionTotal
    $salute      = Get-HealthSnapshot
    $netSpeed    = Get-NetworkSpeed
    $ipConn      = Get-IpConnectivityStatus

    $unboundRamData  = Get-UnboundWorkingSet
    $rpzRulesObj     = Get-TotalRpzRulesCount
    $hardeningStatus = Get-HardeningStatus
    $ntpStatus       = Get-NtpStatus
    $hyperlocalStatus= Get-HyperlocalStatus
    
    $configuredCacheMb = Get-ConfiguredCacheSizeMb
    $cacheUsedMb = [math]::Round(($stats.base.cache_mem_bytes / 1MB), 2)
    $cacheFreeMb = [math]::Max(0, $configuredCacheMb - $cacheUsedMb)
    $cacheSatPct = if ($configuredCacheMb -gt 0) { [math]::Round(($cacheFreeMb / $configuredCacheMb) * 100, 1) } else { 100 }

    $cacheRrsetMb = [math]::Round(($stats.mem_cache_rrset / 1MB), 2)
    $cacheMsgMb   = [math]::Round(($stats.mem_cache_msg / 1MB), 2)

    $engineStartTime = if ($stats.base.uptime_secondi -gt 0) {
        (Get-Date).AddSeconds(-$stats.base.uptime_secondi).ToString("dd.MM.yyyy HH:mm:ss")
    } else { "N/D" }

    $rpzAgeMinutes = 0
    if ([System.IO.File]::Exists($RpzLog)) {
        try {
            $lastWrite = (Get-Item -LiteralPath $RpzLog).LastWriteTime
            $rpzAgeMinutes = [math]::Round(((Get-Date) - $lastWrite).TotalMinutes, 0)
        } catch {}
    }

    $pctBlocchi = 0
    if ($stats.base.query_totali -gt 0) {
        $pctBlocchi = [math]::Round(($rpz.totale / $stats.base.query_totali) * 100, 1)
    }
    $stats.base.blocchi_pct = $pctBlocchi

    $saluteScore = 100
    $anomalie = $false
    if ($salute -and $salute.fasi) {
        foreach ($f in $salute.fasi) {
            if ($f.esito -match 'ERR|ERRORE|FALLITO') { $saluteScore -= 50; $anomalie = $true }
            elseif ($f.esito -match 'WARN|ALLARME') { $saluteScore -= 20; $anomalie = $true }
        }
    }
    if ($saluteScore -lt 0) { $saluteScore = 0 }

    $obj = [ordered]@{
        generato_il      = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
        host             = $env:COMPUTERNAME
        hardware         = $hw
        ram_disk         = $ramDisk
        connettivita_ip  = $ipConn
        versioni         = $versioni
        engine_attivo    = $engineOn
        net_speed        = $netSpeed
        rpz_log_age_min  = $rpzAgeMinutes
        live_rcode_feed  = $liveRcode
        upstream_radar   = $radar
        root_radar       = $rootRadar
        bunker_features  = [ordered]@{
            unbound_ram_mb      = $unboundRamData.ws_mb
            unbound_ram_data    = $unboundRamData
            total_rpz_rules     = $rpzRulesObj.totale
            rpz_dettaglio       = $rpzRulesObj.dettaglio
            hardening_score     = $hardeningStatus.score
            hardening_dettaglio = $hardeningStatus.dettaglio
            ntp_status          = $ntpStatus
            hyperlocal          = $hyperlocalStatus
            cache_used_mb       = $cacheUsedMb
            cache_rrset_mb      = $cacheRrsetMb
            cache_msg_mb        = $cacheMsgMb
            cache_total_mb      = $configuredCacheMb
            cache_sat_pct       = $cacheSatPct
            ratelimited_cnt     = $stats.base.ratelimited_queries
            ratelimit_domain    = $stats.ratelimit_domain
            ratelimit_ip        = $stats.ratelimit_ip
            engine_start_time   = $engineStartTime
        }
        statistiche_live = $stats
        dall_ultimo_report = [ordered]@{
            query_totali         = $stats.base.query_totali
            cache_hits           = $stats.base.cache_hits
            cache_efficienza_pct = $stats.base.cache_efficienza_pct
            uptime_secondi       = $stats.base.uptime_secondi
            blocchi_totali       = $rpz.totale
            blocchi_pct          = $pctBlocchi
            liste                = $rpz.liste
        }
        totale_sessione = $sessione
        salute_sistema  = [ordered]@{ anomalie_rilevate = $anomalie; score = $saluteScore; dettaglio = $salute }
    }
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

# === INTERFACCIA WEB HTML5 / JS ===

$HtmlPage = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Unbound Bunker - DASHBOARD LIVE</title>
<style>
  :root {
    --bg:#0b0f14; --panel:#121820; --border:#1f2b38; --text:#d7e2ec; --dim:#7f93a6;
    --green:#208b4c; --green-bright:#3ddc84; --red:#c0392b; --red-bright:#ff5c5c;
    --amber:#d35400; --accent:#4fb3ff; --purple:#b388ff; --amber-bright:#ffb300;
  }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: "Consolas","Cascadia Mono",monospace; margin: 0; padding: 20px; }
  
  .header-container { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 12px; }
  .clock-box { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 8px 16px; text-align: right; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
  .clock-time { font-size: 2em; font-weight: bold; color: var(--accent); line-height: 1.1; }
  .clock-date { font-size: 0.9em; color: var(--dim); margin-top: 2px; text-transform: capitalize; }

  h1 { 
    font-size: 2em; margin: 0 0 6px 0; font-weight: bold;
    background: linear-gradient(90deg, #d7e2ec 0%, #0099ff 25%, #ffffff 50%, #0099ff 75%, #d7e2ec 100%);
    background-size: 200% auto; -webkit-background-clip: text; -webkit-text-fill-color: transparent;
    animation: intenseShimmer 2.5s ease-in-out infinite; display: inline-block;
  }

  @keyframes intenseShimmer {
    0% { background-position: 0% center; filter: drop-shadow(0 0 2px rgba(79, 179, 255, 0.2)); }
    50% { background-position: 100% center; filter: drop-shadow(0 0 14px rgba(79, 179, 255, 0.85)); }
    100% { background-position: 200% center; filter: drop-shadow(0 0 2px rgba(79, 179, 255, 0.2)); }
  }

  .sub { color: var(--dim); font-size: 0.85em; margin-bottom: 12px; }
  
  .badges {
    display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; width: 100%;
    align-items: center; padding-bottom: 6px;
  }
  .badge {
    padding: 8px 12px; border-radius: 6px; font-size: 0.88em; font-weight: bold;
    display: inline-flex; align-items: center; box-shadow: 0 4px 10px rgba(0,0,0,0.4);
    white-space: nowrap; flex-shrink: 0;
  }

  .ok { background-color: rgba(32, 139, 76, 0.25); color: var(--green-bright); border: 2px solid var(--green-bright); }
  .bad { background-color: rgba(192, 57, 43, 0.3); color: #ffffff; border: 2px solid var(--red-bright); }
  .ram { background-color: rgba(179, 136, 255, 0.15); color: var(--purple); border: 2px solid var(--purple); }
  .net { background-color: rgba(255, 179, 0, 0.15); color: var(--amber-bright); border: 2px solid var(--amber-bright); }
  .blocchi { background-color: rgba(255, 92, 92, 0.15); color: var(--red-bright); border: 2px solid var(--red-bright); }
  .latenza { background-color: rgba(79, 179, 255, 0.15); color: var(--accent); border: 2px solid var(--accent); }

  .cache-highlight {
    background: linear-gradient(135deg, rgba(79,179,255,0.2) 0%, rgba(61,220,132,0.2) 100%);
    color: #ffffff; border: 2px solid var(--green-bright);
    box-shadow: 0 0 18px rgba(61, 220, 132, 0.4); text-shadow: 0 1px 3px rgba(0,0,0,0.8);
  }
  .cache-highlight b { color: var(--green-bright); font-size: 1.15em; margin-left: 6px; }

  .gain-highlight {
    margin-left: auto; font-size: 1em; padding: 10px 18px; border-radius: 8px;
    border: 2px solid var(--amber-bright); box-shadow: 0 0 24px rgba(255, 179, 0, 0.5);
    text-shadow: 0 1px 4px rgba(0,0,0,0.9); transition: all 0.4s ease-in-out;
  }
  .gain-highlight b { font-size: 1.32em; margin-left: 6px; }

  .status-dot-container { display: inline-flex; align-items: center; justify-content: center; width: 16px; height: 16px; vertical-align: middle; }
  .status-dot {
    width: 8px; height: 8px; border-radius: 50%; display: inline-block; position: relative;
  }
  .status-dot.ok {
    background-color: var(--green-bright);
    box-shadow: 0 0 6px var(--green-bright);
  }
  .status-dot.ok::after {
    content: ''; position: absolute; top: -3px; left: -3px; right: -3px; bottom: -3px;
    border-radius: 50%; border: 2px solid var(--green-bright);
    animation: radar-pulse-green 1.8s ease-out infinite; opacity: 0;
  }
  .status-dot.bad {
    background-color: var(--red-bright);
    box-shadow: 0 0 6px var(--red-bright);
  }
  .status-dot.bad::after {
    content: ''; position: absolute; top: -3px; left: -3px; right: -3px; bottom: -3px;
    border-radius: 50%; border: 2px solid var(--red-bright);
    animation: radar-pulse-red 1.8s ease-out infinite; opacity: 0;
  }

  @keyframes radar-pulse-green {
    0% { transform: scale(0.5); opacity: 0.9; }
    70% { transform: scale(2.2); opacity: 0; }
    100% { transform: scale(2.5); opacity: 0; }
  }
  @keyframes radar-pulse-red {
    0% { transform: scale(0.5); opacity: 0.9; }
    70% { transform: scale(2.2); opacity: 0; }
    100% { transform: scale(2.5); opacity: 0; }
  }

  .boost-subrow {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 10px; margin-bottom: 12px; background: #0e141b; border: 1px solid var(--border);
    border-radius: 8px; padding: 10px;
  }

  .bunker-subrow {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 10px; margin-bottom: 22px; background: #0b1219; border: 1px solid rgba(79, 179, 255, 0.3);
    border-radius: 8px; padding: 10px; box-shadow: inset 0 0 10px rgba(0,0,0,0.5);
  }

  .boost-item { background: var(--panel); border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px; }
  .boost-item-header { display: flex; justify-content: space-between; font-size: 0.78em; color: var(--dim); margin-bottom: 5px; font-weight: bold; }
  .boost-item-val { color: var(--text); }

  .boost-item-wide {
    grid-column: span 2;
  }
  @media (max-width: 650px) {
    .boost-item-wide { grid-column: span 1; }
  }

  .g-bar-bg { background: #080c10; border-radius: 4px; height: 10px; overflow: hidden; display: flex; }
  .g-bar-fill { height: 100%; transition: width 0.4s ease, background 0.4s ease; }

  .panel { background: var(--panel); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:18px; }
  .panel h2 { margin:0 0 12px 0; font-size:1.05em; color: var(--accent); border-bottom:1px solid var(--border); padding-bottom:8px; }

  .panel-versioni {
    background: linear-gradient(180deg, #131d2a 0%, var(--panel) 100%);
    border: 1px solid var(--accent) !important; box-shadow: 0 0 12px rgba(79, 179, 255, 0.2);
    padding: 6px 14px !important; margin-bottom: 12px !important;
    display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
  }
  .panel-versioni h2 { color: #ffffff !important; border: none !important; margin: 0 !important; padding: 0 !important; font-size: 0.92em !important; white-space: nowrap; }
  
  .stat-ver {
    background: #090e16; border: 1px solid #1a2a3a; border-radius: 6px; padding: 4px 10px;
    display: flex; align-items: center; gap: 8px; font-size: 0.82em; transition: all 0.2s ease;
  }
  .stat-ver:hover { border-color: var(--accent); box-shadow: 0 2px 10px rgba(0,0,0,0.5); }
  .ver-status-ok { color: var(--green-bright); font-size: 0.75em; font-weight: bold; }
  .ver-status-warn { color: var(--amber-bright); font-size: 0.75em; font-weight: bold; }
  
  .stats-grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(160px,1fr)); gap:12px; margin-bottom:14px; }
  .stat { background:#0e141b; border:1px solid var(--border); border-radius:6px; padding:10px; }
  .stat .val { font-size:1.4em; font-weight:bold; }
  .stat .lbl { color: var(--dim); font-size:0.75em; }

  .stat-breakdown-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-top: 8px; margin-bottom: 10px; }
  #gridTypes { grid-template-columns: repeat(4, 1fr); }
  .stat-card { border-radius: 6px; padding: 10px 8px; text-align: center; border: 1px solid var(--border); box-shadow: 0 4px 10px rgba(0,0,0,0.3); transition: transform 0.2s ease; }
  .stat-card:hover { transform: translateY(-2px); }
  .stat-card .sc-lbl { font-size: 0.76em; font-weight: bold; margin-bottom: 4px; letter-spacing: 0.5px; }
  .stat-card .sc-val { font-size: 1.45em; font-weight: bold; line-height: 1.1; margin-bottom: 2px; }
  .stat-card .sc-pct { font-size: 0.9em; font-weight: bold; opacity: 0.9; }

  .table-scroll { border: 1px solid var(--border); border-radius: 6px; background: #0e141b; }
  .table-scroll table { width: 100%; border-collapse: collapse; font-size: 0.85em; border: none; }
  .table-scroll th, .table-scroll td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--border); }
  .table-scroll th { position: sticky; top: 0; background: var(--panel); z-index: 2; color: var(--dim); font-weight: normal; box-shadow: 0 1px 0 var(--border); }

  table { width:100%; border-collapse: collapse; font-size:0.85em; }
  th, td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--border); }
  th { color: var(--dim); font-weight:normal; }

  #tabellaRadar th, #tabellaRadar td,
  #tabellaRootRadar th, #tabellaRootRadar td {
    padding: 3px 8px !important;
    font-size: 0.82em !important;
    line-height: 1.25 !important;
  }
  
  details { margin-top:6px; }
  summary { cursor:pointer; color: var(--accent); font-weight: bold; }
  
  .esito-warn { color: var(--red-bright); font-weight: bold; }
  .esito-ok { color: var(--green-bright); }
  .latency { color: var(--accent); font-weight: bold; }
  .muted { color: var(--dim); }

  .bar-bg { background: #0e141b; border: 1px solid var(--border); border-radius: 4px; height: 26px; overflow: hidden; display: flex; }
  .bar-fill { height: 100%; transition: width 0.3s ease; }
  .legend-box { font-size: 0.88em; color: var(--dim); margin-top: 10px; line-height: 1.6; }

  .grid-three-columns { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 18px; }
  .grid-three-columns > div { flex: 1; min-width: 310px; margin-bottom: 0; }

  #inputRicercaRcode:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 8px rgba(79, 179, 255, 0.4); }
</style>
</head>
<body>

<div class="header-container">
  <div>
    <h1>&#128737; UNBOUND BUNKER - DASHBOARD LIVE - by Mauro Bigoni</h1>
    <div class="sub" id="subheader">Connessione al Bunker in corso...</div>
  </div>
  <div class="clock-box">
    <div class="clock-time" id="clockTime">--:--:--</div>
    <div class="clock-date" id="clockDate">-----------------</div>
  </div>
</div>

<div class="panel panel-versioni">
  <h2>&#127760; Connettivit&agrave; IP</h2>
  <div id="statsIpConn" style="display: flex; gap: 10px; flex-wrap: wrap; align-items: center;"></div>
</div>

<div class="panel panel-versioni">
  <h2>&#128230; Versioni Componenti (Locale vs Cloud)</h2>
  <div id="statsVersioni" style="display: flex; gap: 10px; flex-wrap: wrap; align-items: center;"></div>
</div>

<div class="badges" id="badges"></div>

<div class="boost-subrow">
  <div class="boost-item">
    <div class="boost-item-header"><span>CACHE REALE (NO RPZ) &middot; peso 30%</span><span class="boost-item-val" id="valRealCache">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barRealCache" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>EFFICIENZA LATENZA &middot; peso 25%</span><span class="boost-item-val" id="valLatScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barLatScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>UPSTREAM DoT ONLINE &middot; peso 15%</span><span class="boost-item-val" id="valUpstreamScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barUpstreamScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>INTEGRIT&Agrave; DNSSEC &middot; peso 15%</span><span class="boost-item-val" id="valDnssecScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barDnssecScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>RISERVA CAPACIT&Agrave; (QPS) &middot; peso 5%</span><span class="boost-item-val" id="valQpsScore">100% (Riposo)</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barQpsScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>SALUTE SISTEMA &middot; peso 10%</span><span class="boost-item-val" id="valHealthScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barHealthScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>PRONTEZZA PREFETCH &middot; info (100% = non serve)</span><span class="boost-item-val" id="valPrefetchScore">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barPrefetchScore" style="width:100%"></div></div>
  </div>
</div>
<div class="sub" style="margin: -8px 0 14px 2px;">&#128640; Le 6 metriche sopra con "peso" compongono il BUNKER BOOST SCORE (somma pesata). "Prontezza Prefetch" &egrave; informativo e non entra nel calcolo: scala invertita, 100% significa che la cache &egrave; gi&agrave; efficiente e non necessita di rinnovi anticipati.</div>

<div class="boost-subrow" id="gainSubrow">
  <div class="boost-item">
    <div class="boost-item-header"><span>&#9889; GUADAGNO LATENZA</span><span class="boost-item-val" id="valGainLat">-- / 40 pt</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barGainLat" style="width:0%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128737; GUADAGNO BLOCCHI RPZ</span><span class="boost-item-val" id="valGainRpz">-- / 20 pt</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barGainRpz" style="width:0%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128190; GUADAGNO RAM DISK</span><span class="boost-item-val" id="valGainRam">-- / 10 pt</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barGainRam" style="width:0%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#127760; GUADAGNO DoT/PREFETCH</span><span class="boost-item-val" id="valGainDot">-- / 10 pt</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barGainDot" style="width:0%"></div></div>
  </div>
</div>
<div class="sub" style="margin: -8px 0 14px 2px;">&#9889; Le 4 metriche sopra compongono il BUNKER GAIN (somma dei punti, poi limitata tra 25% e 80%).</div>

<div class="bunker-subrow">
  <div class="boost-item boost-item-wide">
    <div class="boost-item-header"><span>&#128737; VOLUME SCUDO RPZ</span><span class="boost-item-val" id="valRpzRules">-- regole</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barRpzRules" style="width:100%"></div></div>
    <div id="rpzDettaglio" style="margin-top:8px; font-size:0.75em; line-height:1.6; display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap:4px 18px;"></div>
  </div>

  <div class="boost-item">
    <div class="boost-item-header"><span>&#129504; RAM WORKING SET</span><span class="boost-item-val" id="valUnboundRam">-- MB</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barUnboundRam" style="width:100%"></div></div>
    <div id="ramDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128190; DISPONIBILIT&Agrave; CACHE</span><span class="boost-item-val" id="valCacheMem">-- MB (--%)</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barCacheMem" style="width:0%"></div></div>
    <div id="cacheDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128274; HARDENING &amp; POLICY</span><span class="boost-item-val" id="valHardening">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barHardening" style="width:100%"></div></div>
    <div id="hardeningDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#9201;&#65039; OROLOGIO &amp; SYNC NTP</span><span class="boost-item-val" id="valNtpStatus">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barNtpStatus" style="width:100%"></div></div>
    <div id="ntpDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#127760; HYPERLOCAL ROOT</span><span class="boost-item-val" id="valHyperlocal">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barHyperlocal" style="width:100%"></div></div>
    <div id="hyperlocalDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#9889; ANTI-FLOOD &amp; RATELIMIT</span><span class="boost-item-val" id="valRateLimit">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barRateLimit" style="width:100%"></div></div>
    <div id="rateLimitDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#9203; TEMPO DI ATTIVIT&Agrave; MOTORE</span><span class="boost-item-val" id="valUptime">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barUptime" style="width:100%"></div></div>
    <div id="uptimeDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128200; CACHE HIT RATE GREZZO</span><span class="boost-item-val" id="valCacheEff">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barCacheEff" style="width:0%"></div></div>
    <div id="cacheEffDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#9888;&#65039; TRAFFICO ANOMALO (UNWANTED)</span><span class="boost-item-val" id="valUnwanted">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barUnwanted" style="width:100%"></div></div>
    <div id="unwantedDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>&#128225; PROTOCOLLO TCP / UDP</span><span class="boost-item-val" id="valTcpUdp">--</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barTcpUdp" style="width:0%"></div></div>
    <div id="tcpUdpDettaglio" style="margin-top:6px; font-size:0.74em; line-height:1.7;"></div>
  </div>
</div>

<div class="grid-three-columns">
  <div class="panel" style="margin-bottom: 0; display: flex; flex-direction: column;">
    <h2>&#128202; Statistiche Avanzate Traffico (In-Memory Breakdown)</h2>
    <div style="display: flex; flex-direction: column; gap: 20px;">
      <div>
        <div style="font-size: 1.05em; font-weight: bold; color: var(--accent); margin-bottom: 6px;">Codici Risposta (RCODE)</div>
        <div class="stat-breakdown-grid" id="gridRcode"></div>
        <div class="bar-bg" id="barRcode"></div>
        <div class="legend-box">
          &bull; <b style="color:var(--green-bright)">NOERROR</b>: Query lecite e risolte con successo<br>
          &bull; <b style="color:var(--red-bright)">NXDOMAIN</b>: Domini inesistenti o <b>bloccati da RPZ</b><br>
          &bull; <b style="color:var(--amber-bright)">SERVFAIL</b>: Errori di risoluzione / DNSSEC
        </div>
      </div>
      <div>
        <div style="font-size: 1.05em; font-weight: bold; color: var(--accent); margin-bottom: 6px;">Tipologia Query (RR Type)</div>
        <div class="stat-breakdown-grid" id="gridTypes"></div>
        <div class="bar-bg" id="barTypes"></div>
        <div class="legend-box">
          &bull; <b style="color:var(--accent)">A (IPv4)</b>: Risoluzioni IPv4 standard<br>
          &bull; <b style="color:var(--purple)">AAAA (IPv6)</b>: Risoluzioni IPv6<br>
          &bull; <b style="color:#ffffff">HTTPS (Type 65)</b>: ECH, HTTP/3 e DoH nei browser
        </div>
      </div>
    </div>
  </div>

  <div class="panel" style="margin-bottom: 0;">
    <h2>&#128257; Upstream Radar (DoT Porta 853 &amp; Latenza Live)</h2>
    <div>
      <table id="tabellaRadar">
        <thead>
          <tr>
            <th>Status</th>
            <th>Provider Resolver DoT</th>
            <th>Indirizzo IP</th>
            <th>Latenza TCP</th>
            <th>Stato Porta 853</th>
          </tr>
        </thead>
        <tbody>
          <tr><td colspan="5" class="muted">Verifica resolver DoT in corso...</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="panel" style="margin-bottom: 0;">
    <h2>&#127757; Root Server Mondiali (Latenza ICMP Live)</h2>
    <div>
      <table id="tabellaRootRadar">
        <thead>
          <tr>
            <th>Status</th>
            <th>Root</th>
            <th>Gestore / Organizzazione</th>
            <th>Indirizzo IP (v4/v6)</th>
            <th>Latenza ICMP</th>
          </tr>
        </thead>
        <tbody>
          <tr><td colspan="5" class="muted">Misurazione ICMP Root Server in corso...</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<div class="panel">
  <h2>&#128202; Dall'ultimo report Telegram (Dettaglio Block List)</h2>
  <div class="stats-grid" id="statsUltimoReport"></div>
  <div id="listeRpz" style="padding-right: 4px;"></div>
</div>

<div class="panel">
  <h2>&#9854; Totale sessione (dall'ultimo avvio)</h2>
  <div class="stats-grid" id="statsSessione"></div>
</div>

<div class="panel">
  <h2>&#9877; Stato di salute del sistema (Log Fasi di Avvio)</h2>
  <table id="tabellaSalute"><thead><tr><th>Fase</th><th>Azione</th><th>Esito</th></tr></thead><tbody></tbody></table>
</div>

<div class="panel">
  <h2>&#128678; Live Feed Risposte DNS (Ultimi 500 Eventi RCODE in Tempo Reale)</h2>
  <input type="text" id="inputRicercaRcode" onkeyup="filtraLiveRcode()" 
         placeholder="&#128269; Cerca domini, risolutori o codici RCODE (NOERROR, NXDOMAIN, SERVFAIL)..." 
         style="width:100%; padding:10px 12px; margin-bottom:12px; background:#0e141b; color:#d7e2ec; border:1px solid var(--border); border-radius:6px; font-family:inherit; font-size:0.95em; transition: border-color 0.2s;">
  <div class="table-scroll">
    <table id="tabellaLiveRcode">
      <thead>
        <tr>
          <th style="width: 10%;">Orario</th>
          <th style="width: 38%;">Dominio / Host FQDN Completo</th>
          <th style="width: 20%;">Risolutore / Upstream</th>
          <th style="width: 20%;">Lista RPZ Intervenuta</th>
          <th style="width: 12%;">Stato RCODE</th>
        </tr>
      </thead>
      <tbody>
        <tr><td colspan="5" class="muted">In attesa di eventi RCODE in tempo reale...</td></tr>
      </tbody>
    </table>
  </div>
</div>

<script>
let prevQueries = 0;
let prevTime = Date.now();
let liveQPS = 0;
let maxQPS = 0;
let maxLatSeen = 0;
let isRefreshing = false;

function fmt(n) {
  if (n === undefined || n === null) return "-";
  return Number(n).toLocaleString('it-IT');
}

function updateClock() {
  const now = new Date();
  document.getElementById('clockTime').textContent = now.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
  document.getElementById('clockDate').textContent = now.toLocaleDateString('it-IT', { weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric' });
}
setInterval(updateClock, 1000);
updateClock();

function getVerBadge(loc, cld) {
  if (!cld || cld === 'N/D') return '<span class="ver-status-ok">&#9679; Off</span>';
  if (loc === cld || loc === ('v' + cld) || ('v' + loc) === cld) return '<span class="ver-status-ok">&#10004; OK</span>';
  return '<span class="ver-status-warn">&#9888; v' + cld + '</span>';
}

function updateGradientBar(id, pct) {
  const el = document.getElementById(id);
  if (!el) return;
  const p = Math.min(100, Math.max(0, pct || 0));
  el.style.width = p + '%';

  if (p <= 25) {
    el.style.background = 'linear-gradient(90deg, #78281f 0%, #c0392b 100%)';
  } else if (p <= 60) {
    el.style.background = 'linear-gradient(90deg, #c0392b 0%, #d35400 100%)';
  } else if (p <= 85) {
    el.style.background = 'linear-gradient(90deg, #c0392b 0%, #d35400 40%, #196f3d 100%)';
  } else {
    el.style.background = 'linear-gradient(90deg, #c0392b 0%, #d35400 35%, #196f3d 70%, #145a32 100%)';
  }
}

function filtraLiveRcode() {
  const input = document.getElementById('inputRicercaRcode');
  if (!input) return;
  const query = input.value.toLowerCase();
  const righe = document.querySelectorAll('#tabellaLiveRcode tbody tr');
  righe.forEach(riga => {
    const testo = riga.textContent.toLowerCase();
    riga.style.display = testo.includes(query) ? '' : 'none';
  });
}

async function refresh(forceVersions) {
  if (isRefreshing) return;
  isRefreshing = true;

  try {
    const res = await fetch(forceVersions ? '/api/status?force=1' : '/api/status', { cache: 'no-store' });
    if (!res.ok) { isRefreshing = false; return; }
    
    const textData = await res.text();
    if (!textData || textData.trim().length === 0) { isRefreshing = false; return; }

    const d = JSON.parse(textData);

    document.getElementById('subheader').textContent =
      'Host: ' + d.host + ' | Profilo RAM: ' + (d.hardware.profilo || 'N/D') +
      (d.hardware.ram_gb ? ' (' + d.hardware.ram_gb + ' GB)' : '') +
      ' | Storage: RAM Disk (R:\) | Log RPZ: ' + (d.rpz_log_age_min || 0) + 'm fa | Aggiornato: ' + d.generato_il;

    const ipc = d.connettivita_ip || {};
    const locV4Str = ipc.ipv4_loc ? ' <span class="muted" style="font-size:0.8em; font-weight:normal;">(' + ipc.ipv4_loc + ')</span>' : '';
    const locV6Str = ipc.ipv6_loc ? ' <span class="muted" style="font-size:0.8em; font-weight:normal;">(' + ipc.ipv6_loc + ')</span>' : '';

    document.getElementById('statsIpConn').innerHTML = `
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv4_lan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold;">Ipv4 Lan:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv4_lan || 'N/D'}</span>
        <span class="${ipc.ipv4_lan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv4_lan_ok ? 'ONLINE' : 'OFFLINE'}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv6_lan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold;">Ipv6 Lan:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv6_lan || 'N/D'}</span>
        <span class="${ipc.ipv6_lan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv6_lan_ok ? 'ONLINE' : 'OFFLINE'}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv4_wan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold;">Ipv4 WAN:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv4_wan || 'N/D'}</span>${locV4Str}
        <span class="${ipc.ipv4_wan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv4_wan_ok ? 'ONLINE' : 'OFFLINE'}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv6_wan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold;">Ipv6 WAN:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv6_wan || 'N/D'}</span>${locV6Str}
        <span class="${ipc.ipv6_wan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv6_wan_ok ? 'ONLINE' : 'OFFLINE'}</span>
      </div>
    `;

    const v = d.versioni || {};
    document.getElementById('statsVersioni').innerHTML = `
      <div class="stat-ver">
        <span style="color:var(--dim); font-weight:bold;">&#9881; Engine:</span>
        <span style="color:#ffffff; font-weight:bold;">${v.unbound_local || 'N/D'}</span>
        <span class="muted" style="font-size:0.8em;">(Cloud: ${v.unbound_cloud || 'N/D'})</span>
        ${getVerBadge(v.unbound_local, v.unbound_cloud)}
      </div>
      <div class="stat-ver">
        <span style="color:var(--dim); font-weight:bold;">&#128220; BAT Mgr:</span>
        <span style="color:#ffffff; font-weight:bold;">v${v.bat_local || 'N/D'}</span>
        <span class="muted" style="font-size:0.8em;">(Cloud: v${v.bat_cloud || 'N/D'})</span>
        ${getVerBadge(v.bat_local, v.bat_cloud)}
      </div>
      <div class="stat-ver">
        <span style="color:var(--dim); font-weight:bold;">&#128736; Service:</span>
        <span style="color:#ffffff; font-weight:bold;">${v.conf_local || 'N/D'}</span>
        <span class="muted" style="font-size:0.8em;">(Cloud: v${v.conf_cloud || 'N/D'})</span>
        ${getVerBadge(v.conf_local, v.conf_cloud)}
      </div>
    `;

    const qTot = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.query_totali : 0;
    const cHits = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.cache_hits : 0;
    const qBlocchi = (d.dall_ultimo_report && d.dall_ultimo_report.blocchi_totali) ? d.dall_ultimo_report.blocchi_totali : 0;
    const latMs = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.latenza_ms : 0;
    const qpsAvg = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.qps_medio : 0;
    
    const nowMs = Date.now();
    if (prevQueries > 0 && nowMs > prevTime) {
      const qDiff = Math.max(0, qTot - prevQueries);
      const tDiffSec = (nowMs - prevTime) / 1000;
      liveQPS = (qDiff / tDiffSec).toFixed(1);
    } else {
      liveQPS = qpsAvg.toFixed(1);
    }
    prevQueries = qTot;
    prevTime = nowMs;

    const liveQpsNum = parseFloat(liveQPS);
    if (!isNaN(liveQpsNum) && liveQpsNum > maxQPS) {
      maxQPS = liveQpsNum;
    }

    let radarList = d.upstream_radar || [];
    if (!Array.isArray(radarList)) radarList = [radarList];
    const upOk = radarList.filter(r => r.ok).length;

    let realCachePct = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.cache_efficienza_pct : 0;
    if (isNaN(realCachePct)) realCachePct = 0;

    let effectiveLat = latMs;
    // CORREZIONE LOGICA: 0 ms significa efficienza massima (Cache Hit 100%).
    // Facciamo il fallback alla latenza del radar SOLO se il server non riceve query.
    if (qTot === 0 && (!effectiveLat || effectiveLat <= 0) && radarList.length > 0) {
      const okRadars = radarList.filter(r => r.ok);
      if (okRadars.length > 0) {
        effectiveLat = Math.round(okRadars.reduce((acc, r) => acc + r.ms, 0) / okRadars.length);
      }
    }
    // Evitiamo valori negativi. 0 è perfetto.
    if (effectiveLat < 0) effectiveLat = 0;

    let latScore = 100;
    if (effectiveLat > 5 && effectiveLat <= 50) {
      latScore = Math.round(100 - ((effectiveLat - 5) * 0.18));
    } else if (effectiveLat > 50 && effectiveLat <= 150) {
      latScore = Math.round(92 - ((effectiveLat - 50) * 0.10));
    } else if (effectiveLat > 150 && effectiveLat <= 300) {
      latScore = Math.round(82 - ((effectiveLat - 150) * 0.08));
    } else if (effectiveLat > 300) {
      latScore = Math.max(15, Math.round(70 - ((effectiveLat - 300) * 0.10)));
    }

    let upstreamScore = radarList.length > 0 ? Math.round((upOk / radarList.length) * 100) : 100;

    const ds = (d.statistiche_live && d.statistiche_live.dnssec) ? d.statistiche_live.dnssec : { secure: 0, bogus: 0 };
    let dnssecPct = 100;

    const prefetchVal = (d.statistiche_live && d.statistiche_live.prefetch) ? d.statistiche_live.prefetch : 0;
    const PREFETCH_SENSITIVITY = 10;
    const prefetchRatioPct = (qTot > 0) ? (prefetchVal / qTot) * 100 : 0;
    const prefetchScore = Math.max(0, Math.min(100, Math.round(100 - (prefetchRatioPct * PREFETCH_SENSITIVITY))));

    let qpsHeadroom = Math.max(0, Math.min(100, Math.round(100 - (liveQPS / 5))));
    let healthScore = (d.salute_sistema && d.salute_sistema.score !== undefined) ? d.salute_sistema.score : 100;

    let boostScore = Math.round(
      (realCachePct * 0.30) + 
      (latScore * 0.25) + 
      (upstreamScore * 0.15) + 
      (dnssecPct * 0.15) + 
      (qpsHeadroom * 0.05) +
      (healthScore * 0.10)
    );

    const ispBaselineMs = 120;
    if (effectiveLat > maxLatSeen) maxLatSeen = effectiveLat;
    const effectiveBaselineMs = Math.max(ispBaselineMs, maxLatSeen);

    // CORREZIONE LOGICA: mostriamo 0 se è veramente 0.
    const displayLat = effectiveLat;
    const msSaved = Math.max(0, Math.round(effectiveBaselineMs - displayLat));

    // Il guadagno latenza sarà pieno (40/40 pt) in caso di latenza prossima allo 0.
    const latGainReal = Math.min(40, Math.round((msSaved / effectiveBaselineMs) * 40));
    const blkPct = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.blocchi_pct : 0;
    const rpzGainReal = Math.min(20, Math.round(blkPct * 0.8));
    const ramGainReal = (d.ram_disk && d.ram_disk.attivo) ? 10 : 2;
    const dotPrefetchGain = (upOk > 0 ? 5 : 0) + (prefetchVal > 0 ? 5 : 2);

    let totalBunkerGain = Math.round(latGainReal + rpzGainReal + ramGainReal + dotPrefetchGain);
    if (totalBunkerGain < 25) totalBunkerGain = 25;
    if (totalBunkerGain > 80) totalBunkerGain = 80;

    document.getElementById('valGainLat').textContent = latGainReal + ' / 40 pt';
    updateGradientBar('barGainLat', Math.round((latGainReal / 40) * 100));

    document.getElementById('valGainRpz').textContent = rpzGainReal + ' / 20 pt';
    updateGradientBar('barGainRpz', Math.round((rpzGainReal / 20) * 100));

    document.getElementById('valGainRam').textContent = ramGainReal + ' / 10 pt';
    updateGradientBar('barGainRam', Math.round((ramGainReal / 10) * 100));

    document.getElementById('valGainDot').textContent = dotPrefetchGain + ' / 10 pt';
    updateGradientBar('barGainDot', Math.round((dotPrefetchGain / 10) * 100));

    document.getElementById('valRealCache').textContent = realCachePct + '%';
    updateGradientBar('barRealCache', realCachePct);

    document.getElementById('valLatScore').textContent = latScore + '% (' + displayLat + ' ms)';
    updateGradientBar('barLatScore', latScore);

    document.getElementById('valUpstreamScore').textContent = upstreamScore + '% (' + upOk + '/' + radarList.length + ')';
    updateGradientBar('barUpstreamScore', upstreamScore);

    document.getElementById('valDnssecScore').innerHTML = '100% <span class="esito-ok">[SEC: ' + fmt(ds.secure) + ' | BOG: ' + fmt(ds.bogus) + ']</span>';
    updateGradientBar('barDnssecScore', dnssecPct);

    document.getElementById('valPrefetchScore').innerHTML = prefetchVal > 0 ? '<span class="esito-ok">' + prefetchScore + '% (' + fmt(prefetchVal) + ' rinnovi, ' + prefetchRatioPct.toFixed(2) + '% delle query)</span>' : '<span class="esito-ok">100% (Cache gi&agrave; ottimale, prefetch non necessario)</span>';
    updateGradientBar('barPrefetchScore', prefetchScore);

    document.getElementById('valQpsScore').textContent = qpsHeadroom + '% (Live: ' + liveQPS + ' | Max: ' + maxQPS.toFixed(1) + ' req/s)';
    updateGradientBar('barQpsScore', qpsHeadroom);

    document.getElementById('valHealthScore').textContent = healthScore + '%';
    updateGradientBar('barHealthScore', healthScore);

    const bf = d.bunker_features || {};

    // 1. VOLUME SCUDO RPZ DETTAGLIO INTABELLATO CON VALORI ALLINEATI A DESTRA
    document.getElementById('valRpzRules').textContent = fmt(bf.total_rpz_rules || 0) + ' regole';
    updateGradientBar('barRpzRules', bf.total_rpz_rules > 0 ? 100 : 0);
    let rpzDettaglio = bf.rpz_dettaglio || [];
    if (!Array.isArray(rpzDettaglio)) { rpzDettaglio = [rpzDettaglio]; }
    document.getElementById('rpzDettaglio').innerHTML = rpzDettaglio.map(r =>
      `<div style="display:flex; justify-content:space-between; border-bottom:1px solid rgba(255,255,255,0.05); padding:1px 0;">
        <span>${r.emoji || '&#128737;'} ${r.nome || '-'}</span>
        <b style="color:var(--accent); text-align:right; margin-left:8px;">${fmt(r.regole || 0)}</b>
      </div>`
    ).join('');

    // 2. RAM WORKING SET DETTAGLIO
    const ramData = bf.unbound_ram_data || {};
    document.getElementById('valUnboundRam').textContent = (ramData.ws_mb || 0) + ' MB';
    // CORREZIONE LOGICA: La barra cala all'aumentare dell'occupazione RAM (100% = RAM scarica).
    let ramSysPct = ramData.pct_sys || 0;
    let ramEfficiency = Math.max(0, Math.min(100, 100 - ramSysPct));
    updateGradientBar('barUnboundRam', ramData.ws_mb > 0 ? ramEfficiency : 0);
    
    document.getElementById('ramDettaglio').innerHTML = `
      <div>&#129504; Processo PID: <b style="color:var(--accent);">${ramData.pid || '-'}</b></div>
      <div>&#128187; Incidenza RAM Sistema: <b style="color:var(--accent);">${ramData.pct_sys || 0}%</b> (su ${fmt(ramData.sys_ram_mb || 0)} MB)</div>
      <div>&#9881;&#65039; Profilo Hardware: <b style="color:var(--accent);">${d.hardware.profilo || 'N/D'}</b></div>
    `;

    // 3. DISPONIBILITÀ CACHE DETTAGLIO
    const cUsed = bf.cache_used_mb || 0;
    const cTot = bf.cache_total_mb || 1;
    const cFreeMb = Math.max(0, cTot - cUsed).toFixed(1);
    const cFreePct = Math.max(0, Math.min(100, Math.round((cFreeMb / cTot) * 100)));
    document.getElementById('valCacheMem').textContent = cFreeMb + ' / ' + cTot + ' MB Liberi (' + cFreePct + '%)';
    updateGradientBar('barCacheMem', cFreePct);
    document.getElementById('cacheDettaglio').innerHTML = `
      <div>&#128230; RRset Cache: <b style="color:var(--accent);">${bf.cache_rrset_mb || 0} MB</b></div>
      <div>&#9993;&#65039; Message Cache: <b style="color:var(--accent);">${bf.cache_msg_mb || 0} MB</b></div>
      <div>&#127387; Riserva RAM Libera: <b style="color:var(--green-bright);">${cFreeMb} MB</b> (${cFreePct}%)</div>
    `;

    // 4. HARDENING & POLICY DETTAGLIO
    const hardScore = bf.hardening_score || 0;
    document.getElementById('valHardening').innerHTML = hardScore + '% ' + (hardScore === 100 ? '<span class="esito-ok">[BLINDATO]</span>' : '<span class="esito-warn">[PARZIALE]</span>');
    updateGradientBar('barHardening', hardScore);
    let hardDettaglio = bf.hardening_dettaglio || [];
    if (!Array.isArray(hardDettaglio)) { hardDettaglio = [hardDettaglio]; }
    document.getElementById('hardeningDettaglio').innerHTML = hardDettaglio.map(h =>
      `<div>${h.ok ? '<span class="esito-ok">&#10004;</span>' : '<span class="esito-warn">&#10008;</span>'} ${h.nome || '-'}</div>`
    ).join('');

    // 5. OROLOGIO & SYNC NTP DETTAGLIO
    const ntpOk = (bf.ntp_status && (bf.ntp_status.ok || bf.ntp_status.okCount > 0));
    const ntpDesc = (bf.ntp_status && bf.ntp_status.desc) || (ntpOk ? 'Sincronizzato' : 'Non Sincronizzato');
    document.getElementById('valNtpStatus').innerHTML = ntpOk ? `<span class="esito-ok">${ntpDesc}</span>` : `<span class="esito-warn">${ntpDesc}</span>`;
    const ntpOkCount = (bf.ntp_status && bf.ntp_status.okCount) || 0;
    const ntpTotCount = (bf.ntp_status && bf.ntp_status.totCount) || 0;
    updateGradientBar('barNtpStatus', ntpTotCount > 0 ? Math.round((ntpOkCount / ntpTotCount) * 100) : (ntpOk ? 100 : 20));
    let ntpDettaglio = bf.ntp_status && bf.ntp_status.dettaglio ? bf.ntp_status.dettaglio : [];
    if (!Array.isArray(ntpDettaglio)) { ntpDettaglio = [ntpDettaglio]; }
    document.getElementById('ntpDettaglio').innerHTML = ntpDettaglio.map(n =>
      `<div>${n.ok ? '<span class="esito-ok">&#10004;</span>' : '<span class="esito-warn">&#10008;</span>'} ${n.nome || '-'}</div>`
    ).join('');

    // 6. HYPERLOCAL ROOT DETTAGLIO
    const hlOk = (bf.hyperlocal && bf.hyperlocal.attivo);
    const hlDesc = (bf.hyperlocal && bf.hyperlocal.desc) || (hlOk ? 'Attivo' : 'Disattivato');
    document.getElementById('valHyperlocal').innerHTML = hlOk ? `<span class="esito-ok">${hlDesc}</span>` : `<span class="muted">${hlDesc}</span>`;
    updateGradientBar('barHyperlocal', hlOk ? 100 : 10);
    let hlDettaglio = (bf.hyperlocal && bf.hyperlocal.dettaglio) || [];
    if (!Array.isArray(hlDettaglio)) { hlDettaglio = [hlDettaglio]; }
    document.getElementById('hyperlocalDettaglio').innerHTML = hlDettaglio.map(h =>
      `<div>${h.ok ? '<span class="esito-ok">&#10004;</span>' : '<span class="esito-warn">&#10008;</span>'} ${h.nome || '-'}</div>`
    ).join('');

    // 7. ANTI-FLOOD & RATELIMIT DETTAGLIO
    const rlCnt = bf.ratelimited_cnt || 0;
    if (rlCnt > 0) {
      document.getElementById('valRateLimit').innerHTML = '<span class="esito-warn">' + fmt(rlCnt) + ' intercettati</span>';
      updateGradientBar('barRateLimit', 30);
    } else {
      document.getElementById('valRateLimit').innerHTML = '<span class="esito-ok">0 (Sistema nominale)</span>';
      updateGradientBar('barRateLimit', 100);
    }
    document.getElementById('rateLimitDettaglio').innerHTML = `
      <div>&#128100; Limite per IP Client: <b style="color:${bf.ratelimit_ip > 0 ? 'var(--red-bright)' : 'var(--green-bright)'}">${fmt(bf.ratelimit_ip || 0)}</b></div>
      <div>&#127760; Limite per Dominio Global: <b style="color:${bf.ratelimit_domain > 0 ? 'var(--red-bright)' : 'var(--green-bright)'}">${fmt(bf.ratelimit_domain || 0)}</b></div>
    `;

    // 8. TEMPO DI ATTIVITÀ MOTORE DETTAGLIO
    const uptimeSec = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.uptime_secondi || 0) : 0;
    const upG = Math.floor(uptimeSec / 86400);
    const upH = Math.floor((uptimeSec % 86400) / 3600);
    const upM = Math.floor((uptimeSec % 3600) / 60);
    const uptimeStr = upG > 0 ? `${upG}g ${upH}h ${upM}m` : (upH > 0 ? `${upH}h ${upM}m` : `${upM}m`);
    document.getElementById('valUptime').textContent = uptimeSec > 0 ? uptimeStr : 'N/D';
    updateGradientBar('barUptime', uptimeSec > 3600 ? 100 : (uptimeSec > 0 ? 40 : 0));
    document.getElementById('uptimeDettaglio').innerHTML = `
      <div>&#128640; Data Ultimo Avvio: <b style="color:var(--accent);">${bf.engine_start_time || 'N/D'}</b></div>
      <div>&#9201;&#65039; Uptime Assoluto: <b style="color:var(--accent);">${fmt(uptimeSec)} sec</b></div>
    `;

    // 9. CACHE HIT RATE GREZZO DETTAGLIO
    const cacheEffPct = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.cache_efficienza_pct || 0) : 0;
    document.getElementById('valCacheEff').textContent = cacheEffPct + '%';
    updateGradientBar('barCacheEff', cacheEffPct);
    const totalHits = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.cache_hits || 0) : 0;
    const totalMisses = Math.max(0, qTot - totalHits);
    document.getElementById('cacheEffDettaglio').innerHTML = `
      <div>&#127919; Cache Hits: <b style="color:var(--green-bright);">${fmt(totalHits)}</b></div>
      <div>&#127760; Recursive Misses: <b style="color:var(--amber-bright);">${fmt(totalMisses)}</b></div>
      <div>&#128202; Query Servite: <b style="color:var(--accent);">${fmt(qTot)}</b></div>
    `;

    // 10. TRAFFICO ANOMALO (UNWANTED) DETTAGLIO
    const unwantedQ = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.unwanted_queries || 0) : 0;
    const unwantedR = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.unwanted_replies || 0) : 0;
    const unwantedTot = unwantedQ + unwantedR;
    if (unwantedTot > 0) {
      document.getElementById('valUnwanted').innerHTML = '<span class="esito-warn">' + fmt(unwantedTot) + '</span>';
      updateGradientBar('barUnwanted', 25);
    } else {
      document.getElementById('valUnwanted').innerHTML = '<span class="esito-ok">0</span>';
      updateGradientBar('barUnwanted', 100);
    }
    document.getElementById('unwantedDettaglio').innerHTML = `
      <div>&#128229; Query Anomale Client: <b style="color:${unwantedQ > 0 ? 'var(--red-bright)' : 'var(--green-bright)'}">${fmt(unwantedQ)}</b></div>
      <div>&#128228; Risposte Anomale Upstream: <b style="color:${unwantedR > 0 ? 'var(--red-bright)' : 'var(--green-bright)'}">${fmt(unwantedR)}</b></div>
    `;

    // 11. PROTOCOLLO TCP / UDP DETTAGLIO
    const tcpQ = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.tcp_queries || 0) : 0;
    const udpQ = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.udp_queries || 0) : 0;
    const totProto = (tcpQ + udpQ) || 1;
    const pctTcp = Math.round((tcpQ / totProto) * 100);
    document.getElementById('valTcpUdp').textContent = pctTcp + '% TCP / ' + (100 - pctTcp) + '% UDP';
    updateGradientBar('barTcpUdp', 100);
    document.getElementById('tcpUdpDettaglio').innerHTML = `
      <div>&#9889; Risoluzioni UDP: <b style="color:var(--accent);">${fmt(udpQ)}</b> (${100 - pctTcp}%)</div>
      <div>&#128274; Risoluzioni TCP: <b style="color:var(--purple);">${fmt(tcpQ)}</b> (${pctTcp}%)</div>
    `;

    const badges = document.getElementById('badges');
    badges.innerHTML = '';
    
    const bEngine = document.createElement('span');
    bEngine.className = 'badge ' + (d.engine_attivo ? 'ok' : 'bad');
    bEngine.innerHTML = d.engine_attivo ? '&#128994; UNBOUND ATTIVO' : '&#128308; UNBOUND FERMO';
    badges.appendChild(bEngine);
    
    const bSalute = document.createElement('span');
    bSalute.className = 'badge ' + (d.salute_sistema.anomalie_rilevate ? 'bad' : 'ok');
    bSalute.innerHTML = d.salute_sistema.anomalie_rilevate ? '&#9888; ANOMALIE' : '&#9989; SALUTE OK';
    badges.appendChild(bSalute);

    if (d.ram_disk && d.ram_disk.attivo) {
      const bRam = document.createElement('span');
      bRam.className = 'badge ram';
      bRam.innerHTML = '&#128190; RAM R:\ ' + d.ram_disk.used_mb + '/' + d.ram_disk.tot_mb + ' MB (' + d.ram_disk.pct + '%)';
      badges.appendChild(bRam);
    }

    const bBlocchi = document.createElement('span');
    bBlocchi.className = 'badge blocchi';
    bBlocchi.innerHTML = '&#128737; BLOCCHI: <b>' + blkPct + '%</b>';
    badges.appendChild(bBlocchi);

    const bLat = document.createElement('span');
    bLat.className = 'badge latenza';
    bLat.innerHTML = '&#9889; LATENZA: <b>' + displayLat + ' ms</b>';
    badges.appendChild(bLat);

    if (d.net_speed && d.net_speed.ok) {
      const bNet = document.createElement('span');
      bNet.className = 'badge net';
      bNet.innerHTML = '&#127760; BANDA: <b>' + d.net_speed.down_mbps + ' &#129095;</b> | <b>' + d.net_speed.up_mbps + ' &#129093; Mbps</b>';
      badges.appendChild(bNet);
    }

    const bCache = document.createElement('span');
    bCache.className = 'badge cache-highlight';
    bCache.title = 'Cache reale (peso 30%): ' + realCachePct + '%\nEfficienza latenza (peso 25%): ' + latScore + '%\nUpstream DoT online (peso 15%): ' + upstreamScore + '%\nIntegrità DNSSEC (peso 15%): ' + dnssecPct + '%\nRiserva capacità QPS (peso 5%): ' + qpsHeadroom + '%\nSalute sistema (peso 10%): ' + healthScore + '%';
    bCache.innerHTML = '&#128640; BUNKER BOOST SCORE: <b>' + boostScore + '%</b>';
    badges.appendChild(bCache);

    const bGain = document.createElement('span');
    bGain.className = 'badge gain-highlight';
    bGain.title = 'Guadagno latenza: ' + latGainReal + ' / 40 pt\nGuadagno blocchi RPZ: ' + rpzGainReal + ' / 20 pt\nGuadagno RAM disk: ' + ramGainReal + ' / 10 pt\nGuadagno DoT/Prefetch: ' + dotPrefetchGain + ' / 10 pt\nTotale (limitato 25-80%): ' + totalBunkerGain + '%';

    let gainRatio = Math.min(1, Math.max(0, (totalBunkerGain - 25) / 55));
    let hueStart  = Math.round(38 + gainRatio * 92);
    let hueEnd    = Math.round(58 + gainRatio * 80);

    bGain.style.background = `linear-gradient(135deg, hsla(${hueStart}, 85%, 45%, 0.28) 0%, hsla(${hueEnd}, 90%, 48%, 0.38) 100%)`;
    bGain.style.borderColor = `hsl(${hueEnd}, 90%, 50%)`;
    bGain.style.boxShadow = `0 0 24px hsla(${hueEnd}, 90%, 50%, 0.6)`;

    bGain.innerHTML = '&#9889; BUNKER GAIN: <b style="color:hsl(' + hueEnd + ', 95%, 58%); font-size:1.32em;">+' + totalBunkerGain + '%</b> <span style="font-size:0.88em; opacity:0.95; margin-left:6px;">(~' + msSaved + 'ms/req saved)</span>';
    badges.appendChild(bGain);

    const st = d.statistiche_live || {};
    const rc = st.rcode || { noerror:0, nxdomain:0, servfail:0 };
    const totRc = (rc.noerror + rc.nxdomain + rc.servfail) || 1;
    const pNoerr = Math.round((rc.noerror / totRc) * 100);
    const pNx = Math.round((rc.nxdomain / totRc) * 100);
    const pFail = Math.round((rc.servfail / totRc) * 100);

    document.getElementById('gridRcode').innerHTML = `
      <div class="stat-card" style="border-color: rgba(61, 220, 132, 0.4); background: rgba(32, 139, 76, 0.15);">
        <div class="sc-lbl" style="color: var(--green-bright);">NOERROR</div>
        <div class="sc-val" style="color: var(--green-bright);">${fmt(rc.noerror)}</div>
        <div class="sc-pct" style="color: var(--green-bright);">${pNoerr}%</div>
      </div>
      <div class="stat-card" style="border-color: rgba(255, 92, 92, 0.4); background: rgba(192, 57, 43, 0.15);">
        <div class="sc-lbl" style="color: var(--red-bright);">NXDOMAIN</div>
        <div class="sc-val" style="color: var(--red-bright);">${fmt(rc.nxdomain)}</div>
        <div class="sc-pct" style="color: var(--red-bright);">${pNx}%</div>
      </div>
      <div class="stat-card" style="border-color: rgba(255, 179, 0, 0.4); background: rgba(211, 84, 0, 0.15);">
        <div class="sc-lbl" style="color: var(--amber-bright);">SERVFAIL</div>
        <div class="sc-val" style="color: var(--amber-bright);">${fmt(rc.servfail)}</div>
        <div class="sc-pct" style="color: var(--amber-bright);">${pFail}%</div>
      </div>
    `;

    document.getElementById('barRcode').innerHTML = `
      <div class="bar-fill" style="width:${pNoerr}%; background:var(--green-bright);" title="NOERROR: ${pNoerr}%"></div>
      <div class="bar-fill" style="width:${pNx}%; background:var(--red-bright);" title="NXDOMAIN: ${pNx}%"></div>
      <div class="bar-fill" style="width:${pFail}%; background:var(--amber);" title="SERVFAIL: ${pFail}%"></div>
    `;

    const tp = st.types || { type_a:0, type_aaaa:0, type_https:0, type_altro:0 };
    const totTp = (tp.type_a + tp.type_aaaa + tp.type_https + tp.type_altro) || 1;
    const pA = Math.round((tp.type_a / totTp) * 100);
    const pAaaa = Math.round((tp.type_aaaa / totTp) * 100);
    const pHttps = Math.round((tp.type_https / totTp) * 100);
    const pAltro = Math.round((tp.type_altro / totTp) * 100);

    document.getElementById('gridTypes').innerHTML = `
      <div class="stat-card" style="border-color: rgba(79, 179, 255, 0.4); background: rgba(79, 179, 255, 0.15);">
        <div class="sc-lbl" style="color: var(--accent);">A (IPv4)</div>
        <div class="sc-val" style="color: var(--accent);">${fmt(tp.type_a)}</div>
        <div class="sc-pct" style="color: var(--accent);">${pA}%</div>
      </div>
      <div class="stat-card" style="border-color: rgba(179, 136, 255, 0.4); background: rgba(179, 136, 255, 0.15);">
        <div class="sc-lbl" style="color: var(--purple);">AAAA (IPv6)</div>
        <div class="sc-val" style="color: var(--purple);">${fmt(tp.type_aaaa)}</div>
        <div class="sc-pct" style="color: var(--purple);">${pAaaa}%</div>
      </div>
      <div class="stat-card" style="border-color: rgba(255, 255, 255, 0.3); background: rgba(255, 255, 255, 0.08);">
        <div class="sc-lbl" style="color: #ffffff;">HTTPS (Type 65)</div>
        <div class="sc-val" style="color: #ffffff;">${fmt(tp.type_https)}</div>
        <div class="sc-pct" style="color: #ffffff;">${pHttps}%</div>
      </div>
      <div class="stat-card" style="border-color: rgba(127, 147, 166, 0.4); background: rgba(127, 147, 166, 0.12);">
        <div class="sc-lbl" style="color: var(--dim);">ALTRO (TXT/NS/CNAME/...)</div>
        <div class="sc-val" style="color: var(--dim);">${fmt(tp.type_altro)}</div>
        <div class="sc-pct" style="color: var(--dim);">${pAltro}%</div>
      </div>
    `;

    document.getElementById('barTypes').innerHTML = `
      <div class="bar-fill" style="width:${pA}%; background:var(--accent);" title="A: ${pA}%"></div>
      <div class="bar-fill" style="width:${pAaaa}%; background:var(--purple);" title="AAAA: ${pAaaa}%"></div>
      <div class="bar-fill" style="width:${pHttps}%; background:#ffffff;" title="HTTPS: ${pHttps}%"></div>
      <div class="bar-fill" style="width:${pAltro}%; background:var(--dim);" title="ALTRO: ${pAltro}%"></div>
    `;

    const tbodyRadar = document.querySelector('#tabellaRadar tbody');
    tbodyRadar.innerHTML = '';
    let radar = d.upstream_radar || [];
    if (!Array.isArray(radar)) { radar = [radar]; }

    if (radar.length === 0) {
      tbodyRadar.innerHTML = '<tr><td colspan="5" class="muted">Nessun resolver configurato nel file service.conf</td></tr>';
    } else {
      radar.forEach((r, index) => {
        const tr = document.createElement('tr');
        let tagHtml = r.tag || '-';
        if (r.ok && index < 3) {
          tr.style.background = 'rgba(61, 220, 132, 0.20)';
          tr.style.borderLeft = '4px solid var(--green-bright)';
          tagHtml += ` <span style="background:var(--green-bright); color:#0b0f14; font-size:0.75em; font-weight:bold; padding:2px 6px; border-radius:4px; margin-left:6px;">TOP ${index + 1}</span>`;
        }

        const stIcon = `<div class="status-dot-container"><span class="status-dot ${r.ok ? 'ok' : 'bad'}"></span></div>`;
        const stText = r.ok ? '<span class="esito-ok">PORTA 853 OK</span>' : '<span class="esito-warn">IRRAGGIUNGIBILE</span>';
        const msText = r.ok ? r.ms + ' ms' : 'TIMEOUT';

        tr.innerHTML = `<td>${stIcon}</td><td style="font-weight:bold;">${tagHtml}</td><td>${r.ip || '-'}:${r.port || '853'}</td><td class="latency" style="${r.ok && index < 3 ? 'color:var(--green-bright); font-weight:bold;' : ''}">${msText}</td><td>${stText}</td>`;
        tbodyRadar.appendChild(tr);
      });
    }

    const tbodyRoot = document.querySelector('#tabellaRootRadar tbody');
    if (tbodyRoot) {
      tbodyRoot.innerHTML = '';
      let rootRadar = d.root_radar || [];
      if (!Array.isArray(rootRadar)) { rootRadar = [rootRadar]; }

      if (rootRadar.length === 0) {
        tbodyRoot.innerHTML = '<tr><td colspan="5" class="muted">Nessun dato Root Server disponibile</td></tr>';
      } else {
        rootRadar.forEach(r => {
          const tr = document.createElement('tr');
          const stIcon = `<div class="status-dot-container"><span class="status-dot ${r.ok ? 'ok' : 'bad'}"></span></div>`;
          let latClass = r.ms < 40 ? 'color: var(--green-bright);' : (r.ms < 100 ? 'color: var(--amber-bright);' : 'color: var(--red-bright);');
          const msText = r.ok ? `<span style="font-weight:bold; ${latClass}">${r.ms} ms</span>` : '<span class="esito-warn">TIMEOUT</span>';
          
          tr.innerHTML = `
            <td>${stIcon}</td>
            <td style="font-weight:bold; color: var(--accent);">${r.tag || '-'}</td>
            <td style="font-size:0.85em;">${r.operator || '-'}</td>
            <td style="font-size:0.85em;">${r.ip || '-'}</td>
            <td>${msText}</td>
          `;
          tbodyRoot.appendChild(tr);
        });
      }
    }

    const r = d.dall_ultimo_report;
    document.getElementById('statsUltimoReport').innerHTML = `
      <div class="stat"><div class="val">${fmt(r.query_totali)}</div><div class="lbl">Query totali</div></div>
      <div class="stat"><div class="val">${fmt(r.blocchi_totali)}</div><div class="lbl">Blocchi totali (${fmt(r.blocchi_pct)}%)</div></div>
    `;

    const listeDiv = document.getElementById('listeRpz');
    listeDiv.innerHTML = '';
    let liste = (r && r.liste) || [];
    if (!Array.isArray(liste)) { liste = [liste]; }

    liste.forEach(l => {
      const det = document.createElement('details');
      det.open = true;
      const sum = document.createElement('summary');
      sum.textContent = `${l.emoji || ''} ${l.nome || 'Lista'}: ${fmt(l.conteggio)} blocchi`;
      det.appendChild(sum);
      
      let domini = l.domini || [];
      if (!Array.isArray(domini)) { domini = [domini]; }

      if (domini.length > 0) {
        const tbl = document.createElement('table');
        tbl.innerHTML = '<thead><tr><th>Dominio / Host</th><th>Conteggio</th></tr></thead>';
        const tbody = document.createElement('tbody');
        domini.forEach(dm => {
          const tr = document.createElement('tr');
          tr.innerHTML = `<td>${dm.dominio || '-'}${dm.wildcard ? ' <span class="muted">(wildcard)</span>' : ''}</td><td>${fmt(dm.conteggio)}</td>`;
          tbody.appendChild(tr);
        });
        tbl.appendChild(tbody);
        det.appendChild(tbl);
      } else {
        const p = document.createElement('div');
        p.className = 'muted';
        p.style.padding = '4px 0';
        p.textContent = 'Nessun blocco in questa finestra temporale';
        det.appendChild(p);
      }
      listeDiv.appendChild(det);
    });

    const s = d.totale_sessione;
    const sessDiv = document.getElementById('statsSessione');
    if (s) {
      sessDiv.innerHTML = `
        <div class="stat"><div class="val">${fmt(s.query)}</div><div class="lbl">Query totali</div></div>
        <div class="stat"><div class="val">${fmt(s.blocchi)}</div><div class="lbl">Blocchi totali</div></div>
        <div class="stat"><div class="val muted" style="font-size:0.9em">${s.dal || '-'}</div><div class="lbl">Inizio Sessione</div></div>
      `;
    } else {
      sessDiv.innerHTML = '<div class="muted">Nessun dato di sessione ancora disponibile</div>';
    }

    const tbodySalute = document.querySelector('#tabellaSalute tbody');
    tbodySalute.innerHTML = '';
    let fasi = (d.salute_sistema && d.salute_sistema.dettaglio && d.salute_sistema.dettaglio.fasi) || [];
    if (!Array.isArray(fasi)) { fasi = [fasi]; }

    if (fasi.length === 0) {
      tbodySalute.innerHTML = '<tr><td colspan="3" class="muted">Nessun dato di salute ancora disponibile</td></tr>';
    } else {
      fasi.forEach(f => {
        const isWarn = /WARN|ERR|ERRORE|ALLARME|FALLITO/.test(f.esito || '');
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${f.fase || '-'}</td><td>${f.azione || ''}</td><td class="${isWarn ? 'esito-warn' : 'esito-ok'}">${f.esito || ''}</td>`;
        tbodySalute.appendChild(tr);
      });
    }

    const tbodyRcode = document.querySelector('#tabellaLiveRcode tbody');
    if (tbodyRcode) {
      tbodyRcode.innerHTML = '';
      let feedRcode = d.live_rcode_feed || [];
      if (!Array.isArray(feedRcode)) { feedRcode = [feedRcode]; }

      if (feedRcode.length === 0) {
        tbodyRcode.innerHTML = '<tr><td colspan="5" class="muted">Nessun evento RCODE registrato di recente nel log</td></tr>';
      } else {
        feedRcode.forEach(f => {
          const tr = document.createElement('tr');
          let badgeStyle = 'background: rgba(127, 147, 166, 0.2); color: var(--dim); border: 1px solid var(--dim);';
          const code = (f.rcode || 'UNKNOWN').toUpperCase();

          if (code === 'NOERROR') {
            badgeStyle = 'background-color: rgba(32, 139, 76, 0.25); color: var(--green-bright); border: 1px solid var(--green-bright);';
          } else if (code === 'NXDOMAIN') {
            badgeStyle = 'background-color: rgba(192, 57, 43, 0.3); color: var(--red-bright); border: 1px solid var(--red-bright);';
          } else if (code === 'SERVFAIL') {
            badgeStyle = 'background-color: rgba(211, 84, 0, 0.3); color: var(--amber-bright); border: 1px solid var(--amber-bright);';
          }

          const badgeHtml = `<span class="badge" style="${badgeStyle} padding: 4px 10px; font-size: 0.85em;">${code}</span>`;

          const resText = f.resolver || '&#9889; Cache RAM';
          let resStyle = 'color: var(--green-bright);';
          if (resText.includes('RPZ')) {
            resStyle = 'color: var(--red-bright);';
          } else if (!resText.includes('Cache RAM')) {
            resStyle = 'color: var(--accent); font-weight: bold;';
          }

          const listaRpz = f.rpz_lista
            ? `<span style="color: var(--red-bright);">${f.rpz_lista}</span>`
            : `<span class="muted">-</span>`;

          tr.innerHTML = `
            <td>${f.orario || '-'}</td>
            <td style="font-weight:bold; font-size:1.05em; color: var(--text);">${f.dominio || '-'}</td>
            <td style="${resStyle}">${resText}</td>
            <td>${listaRpz}</td>
            <td>${badgeHtml}</td>
          `;
          tbodyRcode.appendChild(tr);
        });
      }
      filtraLiveRcode();
    }
  } catch (e) {
    console.warn('Errore di connessione temporaneo:', e);
  } finally {
    isRefreshing = false;
  }
}

refresh(true);
setInterval(refresh, 1000);
</script>
</body>
</html>
'@

# === SERVER HTTP LOCALE (LOOPBACK ONLY) ===
$listener = New-Object System.Net.HttpListener
$startedOk = $false
$triedPrefixes = @($Prefix, "http://localhost:$Port/")

foreach ($tryPrefix in $triedPrefixes) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($tryPrefix)
        $listener.Start()
        $Prefix = $tryPrefix
        $startedOk = $true
        Write-DashLog "Listener avviato su $Prefix"
        break
    } catch {
        Write-DashLog "Tentativo fallito su $tryPrefix : $($_.Exception.Message)"
        $listener.Prefixes.Clear()
    }
}

if (-not $startedOk) {
    Write-Host "[ERRORE] Impossibile avviare il listener HTTP su porta $Port."
    exit 1
}

Write-Host "[OK] Unbound Bunker DASHBOARD LIVE in ascolto su $Prefix (Ctrl+C per arrestare)"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        try {
            if ($request.Url.AbsolutePath -eq "/api/status") {
                $forceVersions = $request.Url.Query -match '(\?|&)force=1(&|$)'
                $json = Get-BunkerStatusJson -ForceVersions:$forceVersions
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } elseif ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html") {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPage)
                $response.ContentType = "text/html; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $response.StatusCode = 404
                $notFound = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                $response.OutputStream.Write($notFound, 0, $notFound.Length)
            }
        } catch {
            try {
                Write-DashLog "Errore durante la risposta HTTP: $($_.Exception.Message)"
                $errJson = [System.Text.Encoding]::UTF8.GetBytes('{"error":"internal_server_error"}')
                $response.StatusCode = 500
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $errJson.Length
                $response.OutputStream.Write($errJson, 0, $errJson.Length)
            } catch {}
        } finally {
            try { $response.OutputStream.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
