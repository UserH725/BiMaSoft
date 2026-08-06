# ======================================================================================= #
# UNBOUND BUNKER - DASHBOARD LIVE V2 (sola lettura in RAM - ICONA VERSIONI RESTYLING)     #
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
            $json = (Invoke-WebRequest -Uri 'https://api.github.com/repos/NLnetLabs/unbound/releases/latest' -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json
            if ($json.tag_name -match 'release-(.*)') { $script:CloudVersionsCache.unbound_cloud = $matches[1] } else { $script:CloudVersionsCache.unbound_cloud = $json.tag_name }
        } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_service.txt' -UseBasicParsing -TimeoutSec 3).Content.Trim(); if($v){$script:CloudVersionsCache.conf_cloud = $v} } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_bat.txt' -UseBasicParsing -TimeoutSec 3).Content.Trim(); if($v){$script:CloudVersionsCache.bat_cloud = $v} } catch {}
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

# === LIVE FEED RPZ (COMPLETO SENZA LIMITI TROPPO RESTRITTIVI) ===
function Get-LiveBlockedFeed {
    $feed = @()
    if ([System.IO.File]::Exists($RpzLog)) {
        try {
            # Legge fino a 2000 righe per consentire un elenco ampio
            $lines = Get-Content -LiteralPath $RpzLog -Tail 2000 -ErrorAction SilentlyContinue
            foreach ($ln in $lines) {
                if ($ln -match '(\d{2}:\d{2}:\d{2}).*?\[([a-zA-Z0-9_\-]+)\]\s+(\S+)\s+(rpz-[a-z]+)') {
                    $feed += @{
                        orario  = $matches[1]
                        lista   = $matches[2]
                        dominio = $matches[3].TrimEnd('.')
                        azione  = $matches[4].ToUpper()
                    }
                }
            }
        } catch {}
    }
    if ($feed.Count -gt 0) {
        # Restituisce fino a 500 domini anziché 100 per un feed esteso
        $lastFeed = $feed | Select-Object -Last 500
        $reversed = @()
        for ($i = $lastFeed.Count - 1; $i -ge 0; $i--) {
            $reversed += $lastFeed[$i]
        }
        return $reversed
    }
    return @()
}

# === UPSTREAM RADAR ===
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
                            if ($ar.AsyncWaitHandle.WaitOne(300, $false)) {
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

# === LIVE STATS ESTESE ===
function Get-LiveStats {
    $base   = [ordered]@{ query_totali = 0; cache_hits = 0; cache_efficienza_pct = 0; uptime_secondi = 0; latenza_ms = 0; blocchi_pct = 0; qps_medio = 0 }
    $rcode  = [ordered]@{ noerror = 0; nxdomain = 0; servfail = 0 }
    $types  = [ordered]@{ type_a = 0; type_aaaa = 0; type_https = 0 }
    $dnssec = [ordered]@{ secure = 0; bogus = 0 }
    $prefetch = 0
    $recMs = 0

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
                }
            }
            if ($base.uptime_secondi -gt 0) {
                $base.qps_medio = [math]::Round($base.query_totali / $base.uptime_secondi, 2)
            }
            if ($base.query_totali -gt 0) {
                $base.cache_efficienza_pct = [math]::Round(($base.cache_hits / $base.query_totali) * 100, 1)
                $effFactor = (100 - $base.cache_efficienza_pct) / 100
                $base.latenza_ms = [math]::Round($recMs * $effFactor, 1)
            }
        } catch {}
    }
    return @{ base = $base; rcode = $rcode; types = $types; dnssec = $dnssec; prefetch = $prefetch }
}

function Get-RpzBreakdown {
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
    return @{ totale = $blkTotale; liste = $liste }
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
    $hw       = Get-HardwareTier
    $ramDisk  = Get-RamDiskGauge
    $versioni = Get-BunkerVersions -Force:$ForceVersions
    $engineOn = Get-EngineStatus
    $stats    = Get-LiveStats
    $liveFeed = Get-LiveBlockedFeed
    $radar    = Get-UpstreamRadar
    $rpz      = Get-RpzBreakdown
    $sessione = Get-SessionTotal
    $salute   = Get-HealthSnapshot
    $netSpeed = Get-NetworkSpeed

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

    $anomalie = $false
    if ($salute -and $salute.fasi) {
        foreach ($f in $salute.fasi) {
            if ($f.esito -match 'WARN|ERR|ERRORE|ALLARME|FALLITO') { $anomalie = $true; break }
        }
    }

    $obj = [ordered]@{
        generato_il      = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
        host             = $env:COMPUTERNAME
        hardware         = $hw
        ram_disk         = $ramDisk
        versioni         = $versioni
        engine_attivo    = $engineOn
        net_speed        = $netSpeed
        rpz_log_age_min  = $rpzAgeMinutes
        live_feed_rpz    = $liveFeed
        upstream_radar   = $radar
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
        salute_sistema  = [ordered]@{ anomalie_rilevate = $anomalie; dettaglio = $salute }
    }
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

# === INTERFACCIA WEB HTML5 / JS ===

$HtmlPage = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Unbound Bunker - Dashboard Live V2</title>
<style>
  :root {
    --bg:#0b0f14; --panel:#121820; --border:#1f2b38; --text:#d7e2ec; --dim:#7f93a6;
    --green:#208b4c; --green-bright:#3ddc84; --red:#c0392b; --red-bright:#ff5c5c;
    --amber:#d35400; --accent:#4fb3ff; --purple:#b388ff; --amber-bright:#ffb300;
  }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: "Consolas","Cascadia Mono",monospace; margin: 0; padding: 20px; }
  
  .header-container { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 16px; }
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

  .sub { color: var(--dim); font-size: 0.85em; margin-bottom: 18px; }
  
  /* BADGES PRINCIPALI */
  .badges {
    display: flex;
    gap: 10px;
    flex-wrap: nowrap;
    margin-bottom: 14px;
    width: 100%;
    align-items: center;
    overflow-x: auto;
    white-space: nowrap;
    padding-bottom: 6px;
  }
  .badge {
    padding: 8px 12px;
    border-radius: 6px;
    font-size: 0.88em;
    font-weight: bold;
    display: inline-flex;
    align-items: center;
    box-shadow: 0 4px 10px rgba(0,0,0,0.4);
    white-space: nowrap;
    flex-shrink: 0;
  }

  .ok { background-color: rgba(32, 139, 76, 0.25); color: var(--green-bright); border: 2px solid var(--green-bright); }
  .bad { background-color: rgba(192, 57, 43, 0.3); color: #ffffff; border: 2px solid var(--red-bright); }
  .ram { background-color: rgba(179, 136, 255, 0.15); color: var(--purple); border: 2px solid var(--purple); }
  .net { background-color: rgba(255, 179, 0, 0.15); color: var(--amber-bright); border: 2px solid var(--amber-bright); }
  .blocchi { background-color: rgba(255, 92, 92, 0.15); color: var(--red-bright); border: 2px solid var(--red-bright); }
  .latenza { background-color: rgba(79, 179, 255, 0.15); color: var(--accent); border: 2px solid var(--accent); }

  .cache-highlight {
    background: linear-gradient(135deg, rgba(79,179,255,0.2) 0%, rgba(61,220,132,0.2) 100%);
    color: #ffffff;
    border: 2px solid var(--green-bright);
    box-shadow: 0 0 18px rgba(61, 220, 132, 0.4);
    text-shadow: 0 1px 3px rgba(0,0,0,0.8);
  }
  .cache-highlight b { color: var(--green-bright); font-size: 1.15em; margin-left: 6px; }

  /* CSS EVIDENZIATORE INGRANDITO ED ELEGANTE PER IL BUNKER GAIN CON GRADIENTE REATTIVO VERDE */
  .gain-highlight {
    margin-left: auto;
    font-size: 1em;
    padding: 10px 18px;
    border-radius: 8px;
    border: 2px solid var(--amber-bright);
    box-shadow: 0 0 24px rgba(255, 179, 0, 0.5);
    text-shadow: 0 1px 4px rgba(0,0,0,0.9);
    transition: all 0.4s ease-in-out;
  }
  .gain-highlight b { font-size: 1.32em; margin-left: 6px; }

  /* SUB-ROW SOTTO-INDICATORI A GRADIENTE PER BOOST SCORE & HEADROOM */
  .boost-subrow {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 10px;
    margin-bottom: 22px;
    background: #0e141b;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 10px;
  }
  .boost-item {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 8px 10px;
  }
  .boost-item-header {
    display: flex;
    justify-content: space-between;
    font-size: 0.78em;
    color: var(--dim);
    margin-bottom: 5px;
    font-weight: bold;
  }
  .boost-item-val { color: var(--text); }

  .g-bar-bg { background: #080c10; border-radius: 4px; height: 10px; overflow: hidden; display: flex; }
  .g-bar-fill { height: 100%; transition: width 0.4s ease; }
  
  .fill-cache { background: linear-gradient(90deg, #0099ff 0%, #3ddc84 100%); }
  .fill-latency { background: linear-gradient(90deg, #ffb300 0%, #3ddc84 100%); }
  .fill-upstream { background: linear-gradient(90deg, #b388ff 0%, #3ddc84 100%); }
  .fill-dnssec { background: linear-gradient(90deg, #0099ff 0%, #3ddc84 100%); }
  .fill-prefetch { background: linear-gradient(90deg, #ffb300 0%, #3ddc84 100%); }
  .fill-qps { background: linear-gradient(90deg, #ffb300 0%, #3ddc84 100%); }
  .fill-health { background: linear-gradient(90deg, #ff5c5c 0%, #3ddc84 100%); }

  .panel { background: var(--panel); border:1px solid var(--border); border-radius:8px; padding:16px; margin-bottom:18px; }
  .panel h2 { margin:0 0 12px 0; font-size:1.05em; color: var(--accent); border-bottom:1px solid var(--border); padding-bottom:8px; }

  .panel-versioni {
    background: linear-gradient(180deg, #131d2a 0%, var(--panel) 100%);
    border: 1px solid var(--accent) !important;
    box-shadow: 0 0 16px rgba(79, 179, 255, 0.2);
  }
  .panel-versioni h2 { color: #ffffff !important; border-bottom: 1px solid rgba(79, 179, 255, 0.4) !important; }
  
  .stat-ver { background: #090e16; border: 1px solid #1a2a3a; border-radius: 6px; padding: 12px; position: relative; transition: all 0.2s ease; }
  .stat-ver:hover { border-color: var(--accent); box-shadow: 0 2px 10px rgba(0,0,0,0.5); }
  .ver-status-ok { color: var(--green-bright); font-size: 0.78em; font-weight: bold; float: right; }
  .ver-status-warn { color: var(--amber-bright); font-size: 0.78em; font-weight: bold; float: right; }
  
  .stats-grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(160px,1fr)); gap:12px; margin-bottom:14px; }
  .stat { background:#0e141b; border:1px solid var(--border); border-radius:6px; padding:10px; }
  .stat .val { font-size:1.4em; font-weight:bold; }
  .stat .lbl { color: var(--dim); font-size:0.75em; }

  /* CSS STATISTICHE AVANZATE RIGENERATO AD ALTA VISIBILITÀ */
  .stat-breakdown-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
    margin-top: 8px;
    margin-bottom: 10px;
  }
  .stat-card {
    border-radius: 6px;
    padding: 10px 8px;
    text-align: center;
    border: 1px solid var(--border);
    box-shadow: 0 4px 10px rgba(0,0,0,0.3);
    transition: transform 0.2s ease;
  }
  .stat-card:hover { transform: translateY(-2px); }
  .stat-card .sc-lbl { font-size: 0.76em; font-weight: bold; margin-bottom: 4px; letter-spacing: 0.5px; }
  .stat-card .sc-val { font-size: 1.45em; font-weight: bold; line-height: 1.1; margin-bottom: 2px; }
  .stat-card .sc-pct { font-size: 0.9em; font-weight: bold; opacity: 0.9; }

  .table-scroll { max-height: 520px; overflow-y: auto; border: 1px solid var(--border); border-radius: 6px; background: #0e141b; }
  .table-scroll table { width: 100%; border-collapse: collapse; font-size: 0.85em; border: none; }
  .table-scroll th, .table-scroll td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--border); }
  .table-scroll th { position: sticky; top: 0; background: var(--panel); z-index: 2; color: var(--dim); font-weight: normal; box-shadow: 0 1px 0 var(--border); }

  table { width:100%; border-collapse: collapse; font-size:0.85em; }
  th, td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--border); }
  th { color: var(--dim); font-weight:normal; }
  
  details { margin-top:6px; }
  summary { cursor:pointer; color: var(--accent); font-weight: bold; }
  
  .esito-warn { color: var(--red-bright); font-weight: bold; }
  .esito-ok { color: var(--green-bright); }
  .latency { color: var(--accent); font-weight: bold; }
  .muted { color: var(--dim); }

  .bar-bg { background: #0e141b; border: 1px solid var(--border); border-radius: 4px; height: 26px; overflow: hidden; display: flex; }
  .bar-fill { height: 100%; transition: width 0.3s ease; }
  .legend-box { font-size: 0.88em; color: var(--dim); margin-top: 10px; line-height: 1.6; }

  .grid-two-columns { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 18px; }
  .grid-two-columns > div { flex: 1; min-width: 320px; margin-bottom: 0; }
  
  #inputRicercaFeed:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 8px rgba(79, 179, 255, 0.4); }
</style>
</head>
<body>

<div class="header-container">
  <div>
    <h1>&#128737; UNBOUND BUNKER - Dashboard Live V2 - by Mauro Bigoni</h1>
    <div class="sub" id="subheader">Connessione al Bunker in corso...</div>
  </div>
  <div class="clock-box">
    <div class="clock-time" id="clockTime">--:--:--</div>
    <div class="clock-date" id="clockDate">-----------------</div>
  </div>
</div>

<!-- 🏷️ BARRA DEI BADGES DI STATO CON BUNKER BOOST SCORE E BUNKER GAIN INGRANDITO -->
<div class="badges" id="badges"></div>

<!-- 📊 SECONDA FILA: SOTTO-INDICATORI A RISERVA/EFFICIENZA (100% = STATO TOP) -->
<div class="boost-subrow">
  <div class="boost-item">
    <div class="boost-item-header"><span>CACHE REALE (NO RPZ)</span><span class="boost-item-val" id="valRealCache">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-cache" id="barRealCache" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>EFFICIENZA LATENZA</span><span class="boost-item-val" id="valLatScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-latency" id="barLatScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>UPSTREAM DoT ONLINE</span><span class="boost-item-val" id="valUpstreamScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-upstream" id="barUpstreamScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>INTEGRITÀ DNSSEC</span><span class="boost-item-val" id="valDnssecScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-dnssec" id="barDnssecScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>PRONTEZZA PREFETCH</span><span class="boost-item-val" id="valPrefetchScore">100%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-prefetch" id="barPrefetchScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>RISERVA CAPACITÀ (QPS)</span><span class="boost-item-val" id="valQpsScore">100% (Riposo)</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-qps" id="barQpsScore" style="width:100%"></div></div>
  </div>
  <div class="boost-item">
    <div class="boost-item-header"><span>SALUTE SISTEMA</span><span class="boost-item-val" id="valHealthScore">--%</span></div>
    <div class="g-bar-bg"><div class="g-bar-fill fill-health" id="barHealthScore" style="width:100%"></div></div>
  </div>
</div>

<!-- CONTENITORE AFFIANCATO 1: SINISTRA (Versioni + Statistiche) / DESTRA (Upstream Radar) -->
<div class="grid-two-columns">
  
  <div style="display: flex; flex-direction: column; gap: 18px;">
    
    <div class="panel panel-versioni" style="margin-bottom: 0;">
      <h2>&#128230; Versioni Componenti (Locale vs Cloud)</h2>
      <div class="stats-grid" id="statsVersioni" style="grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-bottom: 0;"></div>
    </div>

    <!-- MODULO STATISTICHE AVANZATE RISTRUTTURATO PER MASSIMA VISIBILITÀ -->
    <div class="panel" style="margin-bottom: 0; flex: 1;">
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

  </div>

  <div class="panel" style="margin-bottom: 0;">
    <h2>&#128257; Upstream Radar (DoT Porta 853 &amp; Latenza Live)</h2>
    <div style="overflow-x: auto;">
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

</div>

<!-- CONTENITORE AFFIANCATO 2: SINISTRA (Live Feed RPZ) / DESTRA (Dettaglio Block List Telegram) -->
<div class="grid-two-columns">
  
  <div class="panel" style="margin-bottom: 0;">
    <h2>&#9889; Live Feed - Ultimi Domini Bloccati in RAM (Real-Time RPZ)</h2>
    <input type="text" id="inputRicercaFeed" onkeyup="filtraLiveFeed()" 
           placeholder="&#128269; Cerca domini o liste nel feed in tempo reale..." 
           style="width:100%; padding:10px 12px; margin-bottom:12px; background:#0e141b; color:#d7e2ec; border:1px solid var(--border); border-radius:6px; font-family:inherit; font-size:0.95em; transition: border-color 0.2s;">
    <div class="table-scroll">
      <table id="tabellaLiveFeed">
        <thead><tr><th>Orario</th><th>Host / Dominio FQDN Completo</th><th>Lista RPZ Intervenuta</th><th>Azione</th></tr></thead>
        <tbody><tr><td colspan="4" class="muted">In attesa di eventi RPZ in tempo reale...</td></tr></tbody>
      </table>
    </div>
  </div>

  <div class="panel" style="margin-bottom: 0; display: flex; flex-direction: column;">
    <h2>&#128202; Dall'ultimo report Telegram (Dettaglio Block List)</h2>
    <div class="stats-grid" id="statsUltimoReport"></div>
    <div id="listeRpz" style="max-height: 440px; overflow-y: auto; padding-right: 4px;"></div>
  </div>

</div>

<!-- &#9854; MODULO TOTALE SESSIONE -->
<div class="panel">
  <h2>&#9854; Totale sessione (dall'ultimo avvio)</h2>
  <div class="stats-grid" id="statsSessione"></div>
</div>

<!-- &#9877; MODULO SALUTE SISTEMA -->
<div class="panel">
  <h2>&#9877; Stato di salute del sistema (Log Fasi di Avvio)</h2>
  <table id="tabellaSalute"><thead><tr><th>Fase</th><th>Azione</th><th>Esito</th></tr></thead><tbody></tbody></table>
</div>

<script>
let prevQueries = 0;
let prevTime = Date.now();
let liveQPS = 0;

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
  if (!cld || cld === 'N/D') return '<span class="ver-status-ok">&#9679; Offline</span>';
  if (loc === cld || loc === ('v' + cld) || ('v' + loc) === cld) return '<span class="ver-status-ok">&#10004; ALLINEATO</span>';
  return '<span class="ver-status-warn">&#9888; AGGIORNAMENTO v' + cld + '</span>';
}

function filtraLiveFeed() {
  const input = document.getElementById('inputRicercaFeed');
  if (!input) return;
  const query = input.value.toLowerCase();
  const righe = document.querySelectorAll('#tabellaLiveFeed tbody tr');
  righe.forEach(riga => {
    const testo = riga.textContent.toLowerCase();
    riga.style.display = testo.includes(query) ? '' : 'none';
  });
}

async function refresh(forceVersions) {
  try {
    const res = await fetch(forceVersions ? '/api/status?force=1' : '/api/status', { cache: 'no-store' });
    const d = await res.json();

    document.getElementById('subheader').textContent =
      'Host: ' + d.host + ' | Profilo RAM: ' + (d.hardware.profilo || 'N/D') +
      (d.hardware.ram_gb ? ' (' + d.hardware.ram_gb + ' GB)' : '') +
      ' | Storage: RAM Disk (R:\) | Log RPZ: ' + (d.rpz_log_age_min || 0) + 'm fa | Aggiornato: ' + d.generato_il;

    // 1. VERSIONI COMPONENTI
    const v = d.versioni || {};
    document.getElementById('statsVersioni').innerHTML = `
      <div class="stat-ver">
        <div class="lbl">&#9881; Engine Unbound ${getVerBadge(v.unbound_local, v.unbound_cloud)}</div>
        <div class="val" style="font-size:1.25em; color:#ffffff; margin: 4px 0;">${v.unbound_local || 'N/D'}</div>
        <div class="muted">Release Cloud: <b>${v.unbound_cloud || 'N/D'}</b></div>
      </div>
      <div class="stat-ver">
        <div class="lbl">&#128220; BAT Manager ${getVerBadge(v.bat_local, v.bat_cloud)}</div>
        <div class="val" style="font-size:1.25em; color:#ffffff; margin: 4px 0;">v${v.bat_local || 'N/D'}</div>
        <div class="muted">Release Cloud: <b>v${v.bat_cloud || 'N/D'}</b></div>
      </div>
      <div class="stat-ver">
        <div class="lbl">&#128736; Service CONF ${getVerBadge(v.conf_local, v.conf_cloud)}</div>
        <div class="val" style="font-size:1.25em; color:#ffffff; margin: 4px 0;">${v.conf_local || 'N/D'}</div>
        <div class="muted">Release Cloud: <b>${v.conf_cloud || 'N/D'}</b></div>
      </div>
    `;

    // METRICHE BASE E UPSTREAM
    const qTot = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.query_totali : 0;
    const cHits = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.cache_hits : 0;
    const qBlocchi = (d.dall_ultimo_report && d.dall_ultimo_report.blocchi_totali) ? d.dall_ultimo_report.blocchi_totali : 0;
    const latMs = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.latenza_ms : 0;
    const qpsAvg = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.qps_medio : 0;
    
    // CALCOLO QPS LIVE
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

    let radarList = d.upstream_radar || [];
    if (!Array.isArray(radarList)) radarList = [radarList];
    const upOk = radarList.filter(r => r.ok).length;

    // 1. CACHE HIT REALE
    const qLecite = Math.max(1, qTot - qBlocchi);
    let realCachePct = Math.min(100, Math.round((cHits / qLecite) * 100));
    if (isNaN(realCachePct)) realCachePct = 0;

    // 2. EFFICIENZA LATENZA
    let effectiveLat = latMs;
    if ((!effectiveLat || effectiveLat <= 0) && radarList.length > 0) {
      const okRadars = radarList.filter(r => r.ok);
      if (okRadars.length > 0) {
        effectiveLat = Math.round(okRadars.reduce((acc, r) => acc + r.ms, 0) / okRadars.length);
      }
    }
    if (!effectiveLat || effectiveLat < 0.5) effectiveLat = 0.5;

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

    // 3. UPSTREAM DOT SCORE
    let upstreamScore = radarList.length > 0 ? Math.round((upOk / radarList.length) * 100) : 100;

    // 4. INTEGRITÀ DNSSEC
    const ds = (d.statistiche_live && d.statistiche_live.dnssec) ? d.statistiche_live.dnssec : { secure: 0, bogus: 0 };
    const totDnssec = ds.secure + ds.bogus;
    let dnssecPct = totDnssec > 0 ? Math.round((ds.secure / totDnssec) * 100) : 100;
    if (ds.bogus > 0) dnssecPct = Math.max(0, dnssecPct - (ds.bogus * 10));

    // 5. PRONTEZZA PREFETCH
    const prefetchVal = (d.statistiche_live && d.statistiche_live.prefetch) ? d.statistiche_live.prefetch : 0;
    let prefetchReadiness = 100;

    // 6. RISERVA DI CAPACITÀ QPS
    let qpsHeadroom = Math.max(0, Math.min(100, Math.round(100 - (liveQPS * 2))));

    // 7. HEALTH SCORE
    let healthScore = d.salute_sistema.anomalie_rilevate ? 0 : 100;

    // BUNKER BOOST SCORE GLOBALE
    let boostScore = Math.round(
      (realCachePct * 0.30) + 
      (latScore * 0.25) + 
      (upstreamScore * 0.15) + 
      (dnssecPct * 0.15) + 
      (qpsHeadroom * 0.05) +
      (healthScore * 0.10)
    );

    // === CALCOLO RICALIBRATO REALISTICO BUNKER GAIN (%) CON TEMPO RISPARMIATO ===
    const ispBaselineMs = 45;
    const displayLat = Math.max(0.5, effectiveLat);
    const msSaved = Math.max(0, Math.round(ispBaselineMs - displayLat));

    const latGainReal = Math.min(40, Math.round((msSaved / ispBaselineMs) * 40));
    const blkPct = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.blocchi_pct : 0;
    const rpzGainReal = Math.min(20, Math.round(blkPct * 0.8));
    const ramGainReal = (d.ram_disk && d.ram_disk.attivo) ? 10 : 2;
    const dotPrefetchGain = (upOk > 0 ? 5 : 0) + (prefetchVal > 0 ? 5 : 2);

    let totalBunkerGain = Math.round(latGainReal + rpzGainReal + ramGainReal + dotPrefetchGain);
    if (totalBunkerGain < 25) totalBunkerGain = 25;
    if (totalBunkerGain > 80) totalBunkerGain = 80;

    // AGGIORNAMENTO SOTTO-INDICATORI A GRADIENTE
    document.getElementById('valRealCache').textContent = realCachePct + '%';
    document.getElementById('barRealCache').style.width = realCachePct + '%';

    document.getElementById('valLatScore').textContent = latScore + '% (' + displayLat + ' ms)';
    document.getElementById('barLatScore').style.width = latScore + '%';

    document.getElementById('valUpstreamScore').textContent = upstreamScore + '% (' + upOk + '/' + radarList.length + ')';
    document.getElementById('barUpstreamScore').style.width = upstreamScore + '%';

    document.getElementById('valDnssecScore').innerHTML = dnssecPct + '% ' + (ds.bogus > 0 ? '<span class="esito-warn">[BOGUS:' + ds.bogus + ']</span>' : '<span class="esito-ok">[OK]</span>');
    document.getElementById('barDnssecScore').style.width = dnssecPct + '%';

    document.getElementById('valPrefetchScore').textContent = prefetchReadiness + '% (' + fmt(prefetchVal) + ' hits)';
    document.getElementById('barPrefetchScore').style.width = prefetchReadiness + '%';

    document.getElementById('valQpsScore').textContent = qpsHeadroom + '% (' + liveQPS + ' req/s)';
    document.getElementById('barQpsScore').style.width = qpsHeadroom + '%';

    document.getElementById('valHealthScore').textContent = healthScore + '%';
    document.getElementById('barHealthScore').style.width = healthScore + '%';

    // 2. BADGES DI STATO INTEGRATI
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

    // BUNKER BOOST SCORE
    const bCache = document.createElement('span');
    bCache.className = 'badge cache-highlight';
    bCache.innerHTML = '&#128640; BUNKER BOOST SCORE: <b>' + boostScore + '%</b>';
    badges.appendChild(bCache);

    // === BUNKER GAIN INGRANDITO CON GRADIENTE DINAMICO REATTIVO DA AMBRA A VERDE SMERALDO ===
    const bGain = document.createElement('span');
    bGain.className = 'badge gain-highlight';

    let gainRatio = Math.min(1, Math.max(0, (totalBunkerGain - 25) / 55));
    let hueStart  = Math.round(38 + gainRatio * 92);
    let hueEnd    = Math.round(58 + gainRatio * 80);

    bGain.style.background = `linear-gradient(135deg, hsla(${hueStart}, 85%, 45%, 0.28) 0%, hsla(${hueEnd}, 90%, 48%, 0.38) 100%)`;
    bGain.style.borderColor = `hsl(${hueEnd}, 90%, 50%)`;
    bGain.style.boxShadow = `0 0 24px hsla(${hueEnd}, 90%, 50%, 0.6)`;

    bGain.innerHTML = '&#9889; BUNKER GAIN: <b style="color:hsl(' + hueEnd + ', 95%, 58%); font-size:1.32em;">+' + totalBunkerGain + '%</b> <span style="font-size:0.88em; opacity:0.95; margin-left:6px;">(~' + msSaved + 'ms/req saved)</span>';
    badges.appendChild(bGain);

    // 3. STATISTICHE LIVE TRAFFICO (RISTRUTTURATE AD ALTA VISIBILITÀ)
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

    const tp = st.types || { type_a:0, type_aaaa:0, type_https:0 };
    const totTp = (tp.type_a + tp.type_aaaa + tp.type_https) || 1;
    const pA = Math.round((tp.type_a / totTp) * 100);
    const pAaaa = Math.round((tp.type_aaaa / totTp) * 100);
    const pHttps = Math.round((tp.type_https / totTp) * 100);

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
    `;

    document.getElementById('barTypes').innerHTML = `
      <div class="bar-fill" style="width:${pA}%; background:var(--accent);" title="A: ${pA}%"></div>
      <div class="bar-fill" style="width:${pAaaa}%; background:var(--purple);" title="AAAA: ${pAaaa}%"></div>
      <div class="bar-fill" style="width:${pHttps}%; background:#ffffff;" title="HTTPS: ${pHttps}%"></div>
    `;

    // 4. LIVE FEED RPZ
    const tbodyFeed = document.querySelector('#tabellaLiveFeed tbody');
    tbodyFeed.innerHTML = '';
    let feed = d.live_feed_rpz || [];
    if (!Array.isArray(feed)) { feed = [feed]; }
    
    if (feed.length === 0) {
      tbodyFeed.innerHTML = '<tr><td colspan="4" class="muted">Nessun blocco RPZ registrato di recente in RAM</td></tr>';
    } else {
      feed.forEach(f => {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${f.orario || '-'}</td><td style="font-weight:bold; font-size:1.05em;">${f.dominio || '-'}</td><td style="color:var(--accent);">${f.lista || '-'}</td><td class="esito-warn">[ ${f.azione || '-'} ]</td>`;
        tbodyFeed.appendChild(tr);
      });
    }
    
    // Riapplica il filtro testuale corrente (se presente) sulle nuove righe generate
    filtraLiveFeed();

    // 5. UPSTREAM RADAR
    const tbodyRadar = document.querySelector('#tabellaRadar tbody');
    tbodyRadar.innerHTML = '';
    let radar = d.upstream_radar || [];
    if (!Array.isArray(radar)) { radar = [radar]; }

    if (radar.length === 0) {
      tbodyRadar.innerHTML = '<tr><td colspan="5" class="muted">Nessun resolver configurato nel file service.conf</td></tr>';
    } else {
      radar.forEach(r => {
        const tr = document.createElement('tr');
        const stIcon = r.ok ? '&#128994;' : '&#128308;';
        const stText = r.ok ? '<span class="esito-ok">PORTA 853 OK</span>' : '<span class="esito-warn">IRRAGGIUNGIBILE</span>';
        const msText = r.ok ? r.ms + ' ms' : 'TIMEOUT';
        tr.innerHTML = `<td>${stIcon}</td><td style="font-weight:bold;">${r.tag || '-'}</td><td>${r.ip || '-'}:${r.port || '853'}</td><td class="latency">${msText}</td><td>${stText}</td>`;
        tbodyRadar.appendChild(tr);
      });
    }

    // 6. REPORT TELEGRAM
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

    // 7. TOTALE SESSIONE
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

    // 8. SALUTE SISTEMA
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
  } catch (e) {
    document.getElementById('subheader').textContent = 'Errore di connessione alla Dashboard Live: ' + e;
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

Write-Host "[OK] Unbound Bunker Dashboard Live V2 in ascolto su $Prefix (Ctrl+C per arrestare)"

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
            try { $response.StatusCode = 500 } catch {}
        } finally {
            $response.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
