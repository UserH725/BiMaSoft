# =======================================================================================#
# UNBOUND BUNKER - DASHBOARD LIVE (sola lettura in RAM - BOOT ISTANTANEO ASINCRONO)      #
# =======================================================================================#

# === CONFIGURAZIONE PERCORSI E PORTA ===
$UbDir  = "C:\Program Files\Unbound"
$Port   = 8954
$Prefix = "http://127.0.0.1:$Port/"

$script:CurrentScriptPath = $MyInvocation.MyCommand.Path
if (-not $script:CurrentScriptPath) { $script:CurrentScriptPath = Join-Path $UbDir "UnboundBunkerDashboard.ps1" }

$UcExe      = Join-Path $UbDir "unbound-control.exe"
$HwConf     = Join-Path $UbDir "hardware.conf"
$SvcConf    = Join-Path $UbDir "service.conf"
$RpzLog     = "R:\unbound.log"
$SessionDat = "R:\session_totale.dat"
$SessionHistoryJson = "R:\session_history.json"
$HealthJson = "R:\bunker_health.json"
$LogFile    = "R:\dashboard_error.log"
$PidFile    = "R:\dashboard.pid"

function Write-DashLog {
    param($msg)
    try { "[$((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))] $msg" | Out-File -LiteralPath $LogFile -Append -Encoding utf8 } catch {}
}

trap {
    Write-DashLog "ERRORE NON GESTITO: $($_.Exception.Message) | Riga: $($_.InvocationInfo.ScriptLineNumber)"
    continue
}

# === AUTO-RIPARAZIONE BOM UTF-8 ===
# Se il file dello script perde il BOM (modifica con editor che salva senza BOM,
# ripristino di un vecchio backup, download che non lo preserva, ecc.), PowerShell 5.1
# lo rilegge con la codepage ANSI di sistema invece che UTF-8 e corrompe ogni carattere
# accentato/speciale (mojibake, es. "piu" -> "piÃ¹", "." -> "Â."). Questo controllo gira
# a ogni avvio, ripara il file sul disco e riavvia il processo prima che qualunque
# stringa dello script venga letta con la codifica sbagliata.
try {
    $bomCheckBytes = [System.IO.File]::ReadAllBytes($script:CurrentScriptPath)
    $hasBom = ($bomCheckBytes.Length -ge 3) -and ($bomCheckBytes[0] -eq 0xEF) -and ($bomCheckBytes[1] -eq 0xBB) -and ($bomCheckBytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $fixedBytes = New-Object byte[] ($bomCheckBytes.Length + 3)
        $fixedBytes[0] = 0xEF; $fixedBytes[1] = 0xBB; $fixedBytes[2] = 0xBF
        [Array]::Copy($bomCheckBytes, 0, $fixedBytes, 3, $bomCheckBytes.Length)
        [System.IO.File]::WriteAllBytes($script:CurrentScriptPath, $fixedBytes)
        Write-DashLog "AUTO-RIPARAZIONE: BOM UTF-8 mancante nel file dashboard, aggiunto automaticamente. Riavvio il processo per applicare la codifica corretta."
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:CurrentScriptPath)`"" -WindowStyle Hidden
        exit 0
    }
} catch {
    Write-DashLog "AUTO-RIPARAZIONE BOM fallita: $($_.Exception.Message)"
}

# === LETTURA SICURA FILE DI LOG IN USO (BYPASS FILE LOCK) ===
function Get-SafeLogLines {
    param(
        [string]$Path,
        [int]$Tail = 0
    )
    if (-not [System.IO.File]::Exists($Path)) { return @() }

    # [FIX PERFORMANCE] Quando serve solo la coda (Tail > 0), NON si legge piu'
    # l'intero file: con R:\unbound.log che puo' crescere a centinaia di migliaia
    # di righe prima dello svuotamento biorario, la vecchia implementazione
    # (ReadLine in loop dall'inizio) rendeva questa funzione via via piu' lenta
    # nel corso delle 2 ore, essendo richiamata ogni 2s da Get-RpzLogTailCached.
    # Ora si legge a blocchi dalla FINE del file (seek all'indietro) finche' non
    # si sono raccolte almeno $Tail righe: costo proporzionale a $Tail, non alla
    # dimensione del file.
    if ($Tail -gt 0) {
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $fileLen = $fs.Length
            if ($fileLen -eq 0) { $fs.Close(); return @() }

            $chunkSize  = 65536
            $pos        = $fileLen
            $newlineCnt = 0
            $collected  = New-Object System.Collections.Generic.List[byte[]]

            while ($pos -gt 0 -and $newlineCnt -le $Tail) {
                $readSize = [Math]::Min($chunkSize, $pos)
                $pos -= $readSize
                [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
                $chunk = New-Object byte[] $readSize
                $off = 0
                while ($off -lt $readSize) {
                    $n = $fs.Read($chunk, $off, $readSize - $off)
                    if ($n -le 0) { break }
                    $off += $n
                }
                for ($i = 0; $i -lt $readSize; $i++) {
                    if ($chunk[$i] -eq 10) { $newlineCnt++ }
                }
                $collected.Insert(0, $chunk)
            }
            $fs.Close()

            $totalBytes = 0
            foreach ($c in $collected) { $totalBytes += $c.Length }
            $merged = New-Object byte[] $totalBytes
            $wpos = 0
            foreach ($c in $collected) { [System.Buffer]::BlockCopy($c, 0, $merged, $wpos, $c.Length); $wpos += $c.Length }

            $text = [System.Text.Encoding]::UTF8.GetString($merged)
            $allLines = $text -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
            if ($allLines.Count -gt 0 -and $allLines[-1] -eq '' ) { $allLines = $allLines[0..([Math]::Max(0,$allLines.Count - 2))] }
            if ($pos -gt 0 -and $allLines.Count -gt 0) {
                # Il primo blocco letto puo' iniziare a meta' di una riga (il seek
                # non e' allineato a un newline): scarto la prima riga incompleta,
                # a meno di trovarci gia' all'inizio del file (pos = 0).
                $allLines = $allLines[1..($allLines.Count - 1)]
            }
            if ($allLines.Count -gt $Tail) {
                return $allLines[($allLines.Count - $Tail)..($allLines.Count - 1)]
            }
            return $allLines
        } catch {
            return @()
        }
    }

    # Percorso invariato: lettura completa del file (usata solo quando serve
    # davvero tutto il contenuto e non e' disponibile una via incrementale).
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $lines = New-Object System.Collections.Generic.List[string]
        while (-not $sr.EndOfStream) {
            [void]$lines.Add($sr.ReadLine())
        }
        $sr.Close()
        $fs.Close()
        return $lines
    } catch {
        return @()
    }
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
            $dettaglio += @{ tag = $lista.Tag; nome = $lista.Nome; emoji = $lista.Emoji; regole = $cnt }
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
    # IPv4 LAN: Raccoglie TUTTI gli indirizzi validi (esclude loopback e APIPA)
    $ip4LanList = @()
    try {
        $ip4LanList = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -ExpandProperty IPAddress
    } catch {}

    # IPv6 LAN: Raccoglie TUTTI gli indirizzi validi (esclude link-local e loopback)
    $ip6LanList = @()
    try {
        $ip6LanList = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^fe80:|^::1$' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.AddressState -eq 'Preferred' } |
            Sort-Object -Property InterfaceMetric |
            Select-Object -ExpandProperty IPAddress
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
        ipv4_lan    = if ($ip4LanList.Count -gt 0) { $ip4LanList -join ", " } else { "N/D" }
        ipv4_lan_ok = ($ip4LanList.Count -gt 0)
        ipv6_lan    = if ($ip6LanList.Count -gt 0) { $ip6LanList -join ", " } else { "N/D" }
        ipv6_lan_ok = ($ip6LanList.Count -gt 0)
        ipv4_wan    = $script:WanCacheData.ipv4_wan
        ipv4_wan_ok = $script:WanCacheData.ipv4_wan_ok
        ipv4_loc    = $script:WanCacheData.ipv4_loc
        ipv6_wan    = $script:WanCacheData.ipv6_wan
        ipv6_wan_ok = $script:WanCacheData.ipv6_wan_ok
        ipv6_loc    = $script:WanCacheData.ipv6_loc
    }
}

# === TOGGLE DNS SCHEDA DI RETE (Automatico <-> Bunker locale 127.0.0.1/::1) ===
$script:NicDnsCache       = $null
$script:NicDnsCacheTime   = [DateTime]::MinValue
$script:NicDnsCacheTtlSec = 15

function Get-ActiveNicIndexes {
    # Tutte le interfacce di rete realmente attive (Up), non solo quella con il gateway di
    # default: Get-NetAdapter senza -IncludeHidden esclude gia' da se' le pseudo-interfacce
    # (es. Loopback Pseudo-Interface). Serve a coprire i casi con piu' schede contemporaneamente
    # su (es. Ethernet + Wi-Fi, o un adattatore VPN/tunnel) cosi' il toggle DNS agisce su tutte.
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -ExpandProperty InterfaceIndex)
    } catch {
        return @()
    }
}

function Test-NicDnsManuale {
    param([Parameter(Mandatory)] $Adapter)

    # La presenza di un DNS assegnato via DHCP non implica configurazione manuale: il modo
    # affidabile e indipendente dalla lingua di Windows per distinguere automatico/manuale
    # e' leggere direttamente la chiave NameServer nel registro dell'interfaccia (vuota =
    # automatico/DHCP, valorizzata = impostazione statica) - stessa cosa che verifica la UI
    # di Windows "Ottieni DNS automaticamente" vs "Usa i seguenti indirizzi server DNS".
    $ifGuid = $Adapter.InterfaceGuid
    $regV4  = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$ifGuid"
    $regV6  = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$ifGuid"
    $staticV4 = $null; $staticV6 = $null
    if (Test-Path -LiteralPath $regV4) { $staticV4 = (Get-ItemProperty -LiteralPath $regV4 -Name NameServer -ErrorAction SilentlyContinue).NameServer }
    if (Test-Path -LiteralPath $regV6) { $staticV6 = (Get-ItemProperty -LiteralPath $regV6 -Name NameServer -ErrorAction SilentlyContinue).NameServer }
    return (-not [string]::IsNullOrWhiteSpace($staticV4)) -or (-not [string]::IsNullOrWhiteSpace($staticV6))
}

function Get-NicDnsStatus {
    param([switch]$Force)

    if (-not $Force -and $script:NicDnsCache -and (((Get-Date) - $script:NicDnsCacheTime).TotalSeconds -lt $script:NicDnsCacheTtlSec)) {
        return $script:NicDnsCache
    }

    $result = [ordered]@{
        disponibile = $false
        ifIndexes   = @()
        interfacce  = @()
        interfaccia = $null   # nomi uniti da virgola, per compatibilita' col frontend esistente
        modalita    = "sconosciuto"   # "automatico" | "manuale" | "misto" | "sconosciuto"
        dohAttivo   = $false  # true solo se 127.0.0.1 E ::1 hanno una registrazione DoH valida verso il template del Bunker
        serverV4    = @()
        serverV6    = @()
        errore      = $null
    }

    try {
        $indexes = Get-ActiveNicIndexes
        if (-not $indexes -or $indexes.Count -eq 0) { throw "Nessuna interfaccia di rete attiva trovata." }

        $voci = @()
        foreach ($ifIndex in $indexes) {
            try {
                $adapter = Get-NetAdapter -InterfaceIndex $ifIndex -ErrorAction Stop
                $isManual = Test-NicDnsManuale -Adapter $adapter
                $voci += [ordered]@{
                    ifIndex     = $ifIndex
                    interfaccia = $adapter.Name
                    modalita    = if ($isManual) { "manuale" } else { "automatico" }
                    serverV4    = @((Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
                    serverV6    = @((Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses)
                }
            } catch {
                Write-DashLog "Lettura stato DNS interfaccia indice $ifIndex fallita: $($_.Exception.Message)"
            }
        }
        if ($voci.Count -eq 0) { throw "Nessuna interfaccia di rete leggibile trovata." }

        $result.disponibile = $true
        $result.ifIndexes    = @($voci | ForEach-Object { $_.ifIndex })
        $result.interfacce   = @($voci)
        $result.interfaccia  = ($voci | ForEach-Object { $_.interfaccia }) -join ", "
        $result.serverV4     = @($voci | ForEach-Object { $_.serverV4 } | Select-Object -Unique)
        $result.serverV6     = @($voci | ForEach-Object { $_.serverV6 } | Select-Object -Unique)

        $manualiCount    = @($voci | Where-Object { $_.modalita -eq "manuale" }).Count
        $automaticiCount = @($voci | Where-Object { $_.modalita -eq "automatico" }).Count
        if ($manualiCount -eq $voci.Count) { $result.modalita = "manuale" }
        elseif ($automaticiCount -eq $voci.Count) { $result.modalita = "automatico" }
        else { $result.modalita = "misto" }

        $result.dohAttivo = Test-BunkerDohAttivo
    } catch {
        $result.errore = $_.Exception.Message
    }

    $script:NicDnsCache     = $result
    $script:NicDnsCacheTime = Get-Date
    return $result
}

$script:BunkerDohTemplate = "https://localhost:8443/dns-query"

function Test-BunkerDohAttivo {
    # true solo se ENTRAMBI 127.0.0.1 e ::1 hanno una registrazione DoH valida (stesso template
    # del Bunker) - usato per mostrare sul pulsante se il DNS crittografato e' davvero attivo,
    # non solo "presunto" perche' siamo in modalita' manuale.
    if (-not (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) { return $false }
    try {
        $voci = @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue | Where-Object {
            $_.ServerAddress -in @("127.0.0.1", "::1") -and $_.DohTemplate -eq $script:BunkerDohTemplate
        })
        return ($voci.Count -ge 2)
    } catch {
        return $false
    }
}

function Set-BunkerDohRegistration {
    # Registra 127.0.0.1 e ::1 come server DoH (DNS-over-HTTPS) verso il template del Bunker,
    # cosi' Windows non interroga mai il resolver locale in chiaro (UDP/53) ma solo via HTTPS
    # crittografato su https://localhost:8443/dns-query. Richiede Windows 11 22H2+ (cmdlet
    # Add-DnsClientDohServerAddress); su sistemi privi del cmdlet resta un fallback silenzioso
    # in chiaro, segnalato nel log.
    #
    # IMPORTANTE: Add-DnsClientDohServerAddress crea una NUOVA voce DoH; Set-DnsClientDohServerAddress
    # invece MODIFICA una voce gia' esistente e fallisce (senza errore visibile all'utente, solo
    # nel log) se l'indirizzo non e' ancora registrato. Alla primissima attivazione 127.0.0.1/::1
    # non hanno mai una voce DoH pregressa, quindi va usato Add-; se una voce esiste gia' (da un
    # toggle precedente) si usa Set- per aggiornarla senza errori di duplicato.
    if (-not (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
        Write-DashLog "Add-DnsClientDohServerAddress non disponibile su questo sistema: DNS verso 127.0.0.1/::1 restera' in chiaro (fallback)."
        return
    }
    foreach ($addr in @("127.0.0.1", "::1")) {
        try {
            $esistente = Get-DnsClientDohServerAddress -ServerAddress $addr -ErrorAction SilentlyContinue
            if ($esistente) {
                Set-DnsClientDohServerAddress -ServerAddress $addr -DohTemplate $script:BunkerDohTemplate -AutoUpgrade $True -AllowFallbackToUdp $False -ErrorAction Stop
            } else {
                Add-DnsClientDohServerAddress -ServerAddress $addr -DohTemplate $script:BunkerDohTemplate -AutoUpgrade $True -AllowFallbackToUdp $False -ErrorAction Stop
            }
        } catch {
            Write-DashLog "Impossibile registrare DoH per $addr verso $($script:BunkerDohTemplate): $($_.Exception.Message)"
        }
    }
    $verifica = @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddress -in @("127.0.0.1", "::1") -and $_.DohTemplate -eq $script:BunkerDohTemplate })
    if ($verifica.Count -gt 0) {
        Write-DashLog "DNS crittografato (DoH) abilitato su 127.0.0.1/::1 verso $script:BunkerDohTemplate (fallback a UDP in chiaro disattivato)."
    } else {
        Write-DashLog "ATTENZIONE: registrazione DoH su 127.0.0.1/::1 non confermata dopo il tentativo (Get-DnsClientDohServerAddress non la vede)."
    }
}

function Remove-BunkerDohRegistration {
    # Rimuove la registrazione DoH su 127.0.0.1/::1 quando si torna ad Automatico (DHCP), per
    # non lasciare template crittografati stale associati a indirizzi non piu' in uso come DNS.
    if (-not (Get-Command Remove-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) { return }
    foreach ($addr in @("127.0.0.1", "::1")) {
        try { Remove-DnsClientDohServerAddress -ServerAddress $addr -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-NicDnsToggle {
    $status = Get-NicDnsStatus -Force
    if (-not $status.disponibile) {
        return [ordered]@{ status = "error"; error = $(if ($status.errore) { $status.errore } else { "Interfaccia di rete non trovata." }) }
    }

    # Se anche una sola interfaccia non e' ancora sul Bunker (stato "automatico" o "misto"),
    # il clic porta TUTTE le interfacce attive su 127.0.0.1/::1 (DoH); solo se sono gia' tutte
    # manuali (Bunker) il clic le riporta TUTTE ad Automatico (DHCP). Cosi' non resta mai
    # un'interfaccia indietro rispetto alle altre.
    $vaSuBunker = ($status.modalita -ne "manuale")

    $erroriPerInterfaccia = @()
    $riuscitiPerInterfaccia = @()
    foreach ($voce in $status.interfacce) {
        try {
            if ($vaSuBunker) {
                Set-DnsClientServerAddress -InterfaceIndex $voce.ifIndex -ServerAddresses @("127.0.0.1", "::1") -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $voce.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
            $riuscitiPerInterfaccia += $voce.interfaccia
        } catch {
            $erroriPerInterfaccia += "$($voce.interfaccia): $($_.Exception.Message)"
            Write-DashLog "Errore durante il toggle DNS sull'interfaccia '$($voce.interfaccia)': $($_.Exception.Message)"
        }
    }

    if ($riuscitiPerInterfaccia.Count -eq 0) {
        return [ordered]@{ status = "error"; error = ($erroriPerInterfaccia -join " | ") }
    }

    if ($vaSuBunker) {
        Set-BunkerDohRegistration
        Write-DashLog "DNS impostato manualmente su 127.0.0.1 / ::1 (Bunker locale, DoH $script:BunkerDohTemplate) su $($riuscitiPerInterfaccia.Count) interfaccia/e ($($riuscitiPerInterfaccia -join ', ')) da richiesta Web."
    } else {
        Remove-BunkerDohRegistration
        Write-DashLog "DNS riportato su Automatico (DHCP) su $($riuscitiPerInterfaccia.Count) interfaccia/e ($($riuscitiPerInterfaccia -join ', ')) da richiesta Web."
    }

    Start-Sleep -Milliseconds 300
    $nuovoStato = Get-NicDnsStatus -Force
    $esito = [ordered]@{
        status      = if ($erroriPerInterfaccia.Count -eq 0) { "ok" } else { "parziale" }
        interfaccia = ($riuscitiPerInterfaccia -join ", ")
        precedente  = $status.modalita
        attuale     = $nuovoStato.modalita
        dohAttivo   = $nuovoStato.dohAttivo
    }
    if ($erroriPerInterfaccia.Count -gt 0) { $esito["error"] = ($erroriPerInterfaccia -join " | ") }
    return $esito
}

# === CACHE VERSIONI CLOUD E LOCALE ===
$script:CloudVersionsCache       = $null
$script:CloudVersionsCacheTime   = [DateTime]::MinValue
$script:CloudVersionsCacheTtlSec = 1800
$script:UnboundLocalVerCache     = $null
$script:DashboardLocalVerCache   = $null

function Get-BunkerVersions {
    param([switch]$Force)
    $result = [ordered]@{ unbound_local = "N/D"; unbound_cloud = "N/D"; conf_local = "N/D"; conf_cloud = "N/D"; bat_local = "N/D"; bat_cloud = "N/D"; dash_local = "N/D"; dash_cloud = "N/D" }

    if (-not $script:UnboundLocalVerCache) {
        $ubExe = Join-Path $UbDir "unbound.exe"
        if (Test-Path $ubExe) {
            try {
                $raw = & $ubExe -h 2>&1 | Out-String
                if ($raw -match 'Version\s+([0-9\.]+)') { $script:UnboundLocalVerCache = $matches[1] }
            } catch {}
        }
        if (-not $script:UnboundLocalVerCache) { $script:UnboundLocalVerCache = "N/D" }
    }
    $result.unbound_local = $script:UnboundLocalVerCache

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

    # Dashboard: numero di versione gia' presente nel tag <title> HTML del file stesso
    # aggiornato a mano da Mauro ad ogni modifica pubblicata sul repo - stessa logica di
    # bat_local, letto dal file in esecuzione (cache indefinita: cambia solo dopo un
    # self-update, che riavvia il processo). Il match e' ancorato al tag <title> (non al
    # solo testo "DASHBOARD LIVE Versione") per non confondersi con eventuali occorrenze
    # della stessa frase altrove nel file, ad esempio in un commento.
    if (-not $script:DashboardLocalVerCache) {
        $dashPath = if ($script:CurrentScriptPath) { $script:CurrentScriptPath } else { Join-Path $UbDir "UnboundBunkerDashboard.ps1" }
        if (Test-Path -LiteralPath $dashPath) {
            try {
                $dashLine = Get-Content -LiteralPath $dashPath | Where-Object { $_ -match '<title>.*DASHBOARD LIVE Versione\s+([0-9]+(?:\.[0-9]+)*)' } | Select-Object -First 1
                if ($dashLine -match 'Versione\s+([0-9]+(?:\.[0-9]+)*)') { $script:DashboardLocalVerCache = $matches[1] }
            } catch {}
        }
        if (-not $script:DashboardLocalVerCache) { $script:DashboardLocalVerCache = "N/D" }
    }
    $result.dash_local = $script:DashboardLocalVerCache

    $cloudStale = $Force -or (-not $script:CloudVersionsCache) -or ((Get-Date) - $script:CloudVersionsCacheTime).TotalSeconds -ge $script:CloudVersionsCacheTtlSec
    if ($cloudStale) {
        if (-not $script:CloudVersionsCache) { $script:CloudVersionsCache = [ordered]@{ unbound_cloud = "N/D"; conf_cloud = "N/D"; bat_cloud = "N/D"; dash_cloud = "N/D" } }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $json = (Invoke-WebRequest -Uri 'https://api.github.com/repos/NLnetLabs/unbound/releases/latest' -UseBasicParsing -TimeoutSec 1).Content | ConvertFrom-Json
            if ($json.tag_name -match 'release-(.*)') { $script:CloudVersionsCache.unbound_cloud = $matches[1] } else { $script:CloudVersionsCache.unbound_cloud = $json.tag_name }
        } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_service.txt' -UseBasicParsing -TimeoutSec 1).Content.Trim(); if($v){$script:CloudVersionsCache.conf_cloud = $v} } catch {}
        try { $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_bat.txt' -UseBasicParsing -TimeoutSec 1).Content.Trim(); if($v){$script:CloudVersionsCache.bat_cloud = $v} } catch {}
        try {
            $dashCloudRaw = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/main/UnboundBunkerDashboard.ps1' -UseBasicParsing -TimeoutSec 2).Content
            if ($dashCloudRaw -match '<title>.*DASHBOARD LIVE Versione\s+([0-9]+(?:\.[0-9]+)*)') { $script:CloudVersionsCache.dash_cloud = $matches[1] }
        } catch {}
        $script:CloudVersionsCacheTime = Get-Date
    }

    $result.unbound_cloud = $script:CloudVersionsCache.unbound_cloud
    $result.conf_cloud    = $script:CloudVersionsCache.conf_cloud
    $result.bat_cloud     = $script:CloudVersionsCache.bat_cloud
    $result.dash_cloud    = $script:CloudVersionsCache.dash_cloud
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
        # [NOTA] 1500 e non 1000: non ogni riga grezza del log e' un evento
        # (alcune sono solo segnalazioni di cambio upstream, "sending query to"),
        # quindi per garantire con margine fino a 1000 eventi utili nel feed
        # serve leggere qualche riga grezza in piu' della soglia finale.
        $script:LogTailCacheLines = Get-SafeLogLines -Path $RpzLog -Tail 1500
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
                elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\[([a-zA-Z0-9_\-]+)\].*?(\S+)\s+rpz-(nxdomain|nodata|passthru)') {
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
        $script:LiveRcodeFeedFull = $feed
        # Restituisce gli ultimi 1000 eventi mantenendo l'ORDINE CRONOLOGICO CRESCENTE
        return ($feed | Select-Object -Last 1000)
    }
    $script:LiveRcodeFeedFull = @()
    return @()
}

# === CONTATORI RUNNING "TOTALI" - DALL'ULTIMO AZZERAMENTO DEL LOG, NON DAL TAIL CACHE ===
# Il feed sopra (Get-LiveRcodeFeed) e' volutamente una finestra limitata - tail cache da
# 1000 righe grezze + cap a 300 eventi - per restare leggero ad ogni refresh e leggibile
# in lista. "Totali" invece deve rispondere a una domanda diversa: quanti eventi sono
# passati dall'ultima volta che R:\unbound.log e' stato svuotato (avvio/riavvio Unbound
# o ciclo biorario del BAT)? Per non dover rileggere l'intero file ogni 1-2 secondi, si
# tiene un puntatore di posizione byte persistente ($script:LiveFeedPos): ad ogni
# chiamata si leggono SOLO i byte aggiunti dall'ultima volta (costo proporzionale al
# traffico nuovo, non alla dimensione del file) e si sommano ai contatori cumulativi.
# Se la lunghezza del file risulta minore della posizione salvata, il file e' stato
# troncato (azzeramento) e si riparte da zero, registrando il nuovo orario di partenza.
$script:LiveFeedPos         = 0
$script:LiveFeedPendingLine = ""
$script:LiveFeedConsentite  = 0
$script:LiveFeedBloccate    = 0
$script:LiveFeedSinceOrario = $null

# === CERBERO RUNTIME SESSION (persistenza dalla accensione PC) ===
$script:RuntimeFile = Join-Path (Split-Path $RpzLog -Parent) "cerbero_runtime.json"
$script:RuntimeConsentite = 0
$script:RuntimeBloccate = 0
$script:RuntimeAvvio = Get-Date
$script:RuntimeLastSave = Get-Date

function Load-CerberoRuntime {
    try {
        if (Test-Path $script:RuntimeFile) {
            $r = Get-Content $script:RuntimeFile -Raw | ConvertFrom-Json
            if ($r) {
                $script:RuntimeConsentite = [int]$r.consentite
                $script:RuntimeBloccate = [int]$r.bloccate
                $script:RuntimeAvvio = [datetime]$r.avvio
            }
        }
    } catch {}
}

function Save-CerberoRuntime {
    try {
        $obj = [ordered]@{
            avvio = $script:RuntimeAvvio.ToString("yyyy-MM-ddTHH:mm:ss")
            consentite = $script:RuntimeConsentite
            bloccate = $script:RuntimeBloccate
            ultimo_salvataggio = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $obj | ConvertTo-Json | Set-Content -LiteralPath $script:RuntimeFile -Encoding UTF8
    } catch {}
}

Load-CerberoRuntime

function Get-LiveFeedSummary {
    if ([System.IO.File]::Exists($RpzLog)) {
        try {
            $fs  = New-Object System.IO.FileStream($RpzLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $len = $fs.Length

            if ($len -lt $script:LiveFeedPos) {
                # Troncamento rilevato (azzeramento biorario o riavvio Unbound/Dashboard): si riparte da zero.
                $script:LiveFeedPos         = 0
                $script:LiveFeedPendingLine = ""
                $script:LiveFeedConsentite  = 0
                $script:LiveFeedBloccate    = 0
                $script:LiveFeedSinceOrario = $null
            }

            if ($len -gt $script:LiveFeedPos) {
                $toRead = $len - $script:LiveFeedPos
                [void]$fs.Seek($script:LiveFeedPos, [System.IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] $toRead
                $off = 0
                while ($off -lt $toRead) {
                    $n = $fs.Read($buf, $off, $toRead - $off)
                    if ($n -le 0) { break }
                    $off += $n
                }
                $script:LiveFeedPos += $off

                $text  = $script:LiveFeedPendingLine + [System.Text.Encoding]::UTF8.GetString($buf, 0, $off)
                $parts = $text -split "`n"
                # L'ultima porzione puo' essere una riga non ancora completa (senza newline
                # finale): si tiene da parte per il prossimo giro, senza contarla adesso.
                $script:LiveFeedPendingLine = $parts[-1]
                if ($parts.Count -gt 1) {
                    foreach ($ln0 in $parts[0..($parts.Count - 2)]) {
                        $ln = $ln0.TrimEnd("`r")
                        if ($ln -match '(\d{2}:\d{2}:\d{2}).*?\s+info:\s+\S+\s+(\S+)\s+\S+\s+IN\s+(NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR)') {
                            if (-not $script:LiveFeedSinceOrario) { $script:LiveFeedSinceOrario = $matches[1] }
                            $script:LiveFeedConsentite++
                            $script:RuntimeConsentite++
                        }
                        elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\[([a-zA-Z0-9_\-]+)\].*?(\S+)\s+rpz-(nxdomain|nodata|passthru)') {
                            if (-not $script:LiveFeedSinceOrario) { $script:LiveFeedSinceOrario = $matches[1] }
                            $script:LiveFeedBloccate++
                            $script:RuntimeBloccate++
                        }
                    }
                }
            }
            $fs.Close()
        } catch {}
    }

    $totale = $script:LiveFeedConsentite + $script:LiveFeedBloccate
    if ($totale -eq 0) {
        return [ordered]@{
            totale         = 0
            consentite     = 0
            pct_consentite = 0
            bloccate       = 0
            pct_bloccate   = 0
            dalle          = $null
        }
    }

    $pctConsentite = [math]::Round(($script:LiveFeedConsentite / $totale) * 100, 1)
    $pctBloccate   = [math]::Round(($script:LiveFeedBloccate   / $totale) * 100, 1)

    if (((Get-Date) - $script:RuntimeLastSave).TotalSeconds -ge 30) {
        Save-CerberoRuntime
        $script:RuntimeLastSave = Get-Date
    }

    return [ordered]@{
        totale         = $totale
        consentite     = $script:LiveFeedConsentite
        pct_consentite = $pctConsentite
        bloccate       = $script:LiveFeedBloccate
        pct_bloccate   = $pctBloccate
        dalle          = $script:LiveFeedSinceOrario
        runtime_totale = $script:RuntimeConsentite + $script:RuntimeBloccate
        runtime_consentite = $script:RuntimeConsentite
        runtime_bloccate = $script:RuntimeBloccate
        runtime_avvio = $script:RuntimeAvvio.ToString("o")
    }
}

# === UPSTREAM RADAR (DOT PORTA 853) ===
$script:RadarCacheTime = [DateTime]::MinValue
$script:RadarCacheData = @()

function Get-UpstreamRadar {
    if (((Get-Date) - $script:RadarCacheTime).TotalSeconds -ge 8 -or $script:RadarCacheData.Count -eq 0) {
        $radar = New-Object System.Collections.Generic.List[psobject]
        $readFailed = $false
        if (Test-Path $SvcConf) {
            try {
                $lines = Get-Content -LiteralPath $SvcConf -ErrorAction Stop
                $lastResolverName = ""

                foreach ($ln in $lines) {
                    # [FIX] try/catch per singola riga: un errore isolato (es. lettura di
                    # service.conf in collisione con una scrittura concorrente sul file) non
                    # deve piu' interrompere il parsing delle righe forward-addr successive,
                    # altrimenti i resolver dopo il punto di errore sparivano dal radar invece
                    # di comparire come IRRAGGIUNGIBILE.
                    try {
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
                    } catch {}
                }
            } catch {
                # Lettura di service.conf fallita (es. file bloccato/in scrittura in quel momento).
                $readFailed = $true
            }
        }

        # [FIX] Se la lettura e' fallita, oppure il numero di resolver trovati in questo
        # ciclo e' crollato rispetto all'ultima rilevazione valida (sintomo tipico di una
        # lettura parziale causata da una scrittura concorrente su service.conf), mantengo
        # la cache precedente invece di pubblicare un elenco incompleto: i resolver non
        # devono sparire dalla dashboard, al massimo devono risultare IRRAGGIUNGIBILE.
        # Il timestamp della cache NON viene aggiornato in questo caso, cosi' il prossimo
        # ciclo di raccolta (1.5s dopo) riprova subito invece di aspettare 8s pieni.
        $previousCount = $script:RadarCacheData.Count
        if (($readFailed -or ($previousCount -gt 0 -and $radar.Count -lt $previousCount)) -and $previousCount -gt 0) {
            Write-DashLog "Upstream Radar: lettura di service.conf incompleta o fallita in questo ciclo ($($radar.Count)/$previousCount resolver trovati), mantengo l'ultimo elenco valido."
        } else {
            $sortedRadar = $radar | Sort-Object @{Expression={$_.ok}; Descending=$true}, @{Expression={$_.ms}; Ascending=$true}
            $script:RadarCacheData = @($sortedRadar)
            $script:RadarCacheTime = Get-Date
        }
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

# [FIX PERFORMANCE] Stato incrementale: invece di rileggere l'intero
# R:\unbound.log e riscansionarlo 10 volte (una per lista RPZ) ogni 15s, si
# tiene un cursore (Offset) sull'ultimo byte gia' processato e un accumulatore
# persistente dei conteggi per dominio/lista. Ad ogni ciclo si leggono e si
# processano SOLO i byte aggiunti dall'ultima volta. "Pending" conserva
# l'eventuale riga finale incompleta (file ancora in scrittura da Unbound) per
# prependerla al prossimo giro. Quando il file risulta piu' corto
# dell'Offset salvato (svuotamento biorario via SetLength(0), o riavvio
# Unbound/Dashboard), si azzera tutto e si riparte da zero — stesso
# comportamento di prima, che dopo un troncamento ripartiva naturalmente da 0.
$script:RpzIncrementalState = $null

function Get-RpzBreakdown {
    if ($script:RpzBreakdownCache -and ((Get-Date) - $script:RpzBreakdownCacheTime).TotalSeconds -lt $script:RpzBreakdownCacheTtlSec) {
        return $script:RpzBreakdownCache
    }

    if (-not $script:RpzIncrementalState) {
        $tagPattern = ($RpzListe | ForEach-Object { [regex]::Escape($_.Tag) }) -join '|'
        $counts = @{}
        foreach ($lista in $RpzListe) { $counts[$lista.Tag] = @{} }
        $script:RpzIncrementalState = @{
            Offset  = [int64]0
            Pending = ''
            Counts  = $counts
            Regex   = [regex]("\[($tagPattern)\]\s+(?:.*?\s+)?(\S+)\s+rpz-nxdomain")
        }
    }
    $state = $script:RpzIncrementalState

    try {
        if ([System.IO.File]::Exists($RpzLog)) {
            $curLen = (New-Object System.IO.FileInfo($RpzLog)).Length

            if ($curLen -lt $state.Offset) {
                $state.Offset  = [int64]0
                $state.Pending = ''
                foreach ($lista in $RpzListe) { $state.Counts[$lista.Tag] = @{} }
            }

            if ($curLen -gt $state.Offset) {
                $fs = New-Object System.IO.FileStream($RpzLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                [void]$fs.Seek($state.Offset, [System.IO.SeekOrigin]::Begin)
                $toRead = [int]($curLen - $state.Offset)
                $chunk = New-Object byte[] $toRead
                $readTotal = 0
                while ($readTotal -lt $toRead) {
                    $n = $fs.Read($chunk, $readTotal, $toRead - $readTotal)
                    if ($n -le 0) { break }
                    $readTotal += $n
                }
                $fs.Close()

                $text = $state.Pending + [System.Text.Encoding]::UTF8.GetString($chunk, 0, $readTotal)
                $state.Offset = $curLen

                $lastNl = $text.LastIndexOf("`n")
                if ($lastNl -ge 0) {
                    $state.Pending = $text.Substring($lastNl + 1)
                    $completeText  = $text.Substring(0, $lastNl)
                } else {
                    $state.Pending = $text
                    $completeText  = ''
                }

                if ($completeText) {
                    foreach ($ln in ($completeText -split "`n")) {
                        $mm = $state.Regex.Match($ln)
                        if ($mm.Success) {
                            $tag = $mm.Groups[1].Value
                            $dn  = $mm.Groups[2].Value.TrimEnd('.')
                            $bucket = $state.Counts[$tag]
                            if ($bucket) {
                                if ($bucket.ContainsKey($dn)) { $bucket[$dn]++ } else { $bucket[$dn] = 1 }
                            }
                        }
                    }
                }
            }
        } else {
            $state.Offset  = [int64]0
            $state.Pending = ''
            foreach ($lista in $RpzListe) { $state.Counts[$lista.Tag] = @{} }
        }
    } catch {
        Write-DashLog "Errore lettura incrementale RPZ log: $($_.Exception.Message)"
    }

    $liste = @()
    $blkTotale = 0
    foreach ($lista in $RpzListe) {
        $bucket = $state.Counts[$lista.Tag]
        $domini = @()
        $conteggioLista = 0
        if ($bucket -and $bucket.Count -gt 0) {
            $grp = $bucket.GetEnumerator() | Sort-Object Value -Descending
            foreach ($g in $grp) {
                $dn = $g.Key
                $wildcard = $false
                if ($dn.StartsWith("*.")) { $dn = $dn.Substring(2); $wildcard = $true }
                $dn = $dn -replace '[*_\[\]`]', ''
                $domini += @{ dominio = $dn; wildcard = $wildcard; conteggio = $g.Value }
                $conteggioLista += $g.Value
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

# === STATISTICHE A FINESTRA SCORREVOLE 24H (bucket orari su R:\) ===
# Non e' un accumulatore a somma progressiva e non si azzera a mezzanotte:
# ogni ciclo il delta viene sommato nel bucket dell'ora corrente, e prima di
# totalizzare si scartano dal file i bucket la cui ora e' finita da piu' di
# 24h. Risultato: PC acceso 23h -> 23h di dati; PC acceso 25h -> solo le
# ultime 24h. Allo spegnimento reale R:\ si svuota (ImDisk volatile) e si
# riparte da zero senza bisogno di logica dedicata.
$script:SessionHistoryIntervalSec    = 60
$script:SessionHistoryLastSampleTime = [DateTime]::MinValue
$script:SessionHistoryLastDat        = $null
$script:SessionHistoryBucketsCache   = $null

function Get-SessionHistoryTotals {
    param($Buckets = $null)

    if (-not $Buckets) {
        if ($script:SessionHistoryBucketsCache) {
            $Buckets = $script:SessionHistoryBucketsCache
        } elseif ([System.IO.File]::Exists($SessionHistoryJson)) {
            try {
                $raw = Get-Content -LiteralPath $SessionHistoryJson -Raw
                $Buckets = [ordered]@{}
                if ($raw) {
                    $parsed = $raw | ConvertFrom-Json
                    foreach ($prop in $parsed.PSObject.Properties) { $Buckets[$prop.Name] = $prop.Value }
                }
            } catch { $Buckets = [ordered]@{} }
        } else {
            $Buckets = [ordered]@{}
        }
    }

    $totQuery = [double]0; $totHits = [double]0; $totRpz = [double]0
    $chiaviOrdinate = @($Buckets.Keys | Sort-Object)
    foreach ($k in $chiaviOrdinate) {
        $totQuery += [double]$Buckets[$k].query
        $totHits  += [double]$Buckets[$k].hits
        $totRpz   += [double]$Buckets[$k].rpz
    }
    $effPct = if ($totQuery -gt 0) { [math]::Round(($totHits / $totQuery) * 100, 1) } else { 0 }
    $piuVecchio = if ($chiaviOrdinate.Count -gt 0) { $chiaviOrdinate[0] + ":00" } else { $null }

    # Nomi "query"/"blocchi"/"dal" mantenuti per compatibilita' col frontend esistente
    return [ordered]@{
        query                 = [int64]$totQuery
        blocchi               = [int64]$totRpz
        cache_hits            = [int64]$totHits
        cache_efficienza_pct  = $effPct
        ore_coperte           = $chiaviOrdinate.Count
        dal                   = $piuVecchio
        finestra              = "Ultime 24h (bucket orari scorrevoli)"
    }
}

function Update-SessionHistory {
    $now = Get-Date

    # Non ricalcolare/riscrivere il file ad ogni polling della dashboard (ogni ~1.5s):
    # si campiona e si scrive su disco al massimo una volta ogni SessionHistoryIntervalSec.
    # session_totale.dat comunque cambia solo ogni ~2 ore (ciclo biorario del BAT), quindi
    # nella stragrande maggioranza dei campionamenti il delta sara' semplicemente zero.
    if ($script:SessionHistoryLastSampleTime -ne [DateTime]::MinValue -and
        ($now - $script:SessionHistoryLastSampleTime).TotalSeconds -lt $script:SessionHistoryIntervalSec) {
        return Get-SessionHistoryTotals
    }
    $script:SessionHistoryLastSampleTime = $now

    # session_totale.dat e' scritto dal BAT (routine :DAILY_REPORT_ONLY) come accumulatore
    # a sola crescita: ad ogni ciclo biorario somma il delta di query/cachehits/blocchi
    # letto da "unbound-control stats" (che si auto-azzera dopo la lettura, quindi il
    # valore che il BAT somma e' gia' un delta corretto) PRIMA di troncare il log RPZ.
    # Per questo qui non serve nessuna euristica di rilevamento riavvio o troncamento
    # (a differenza dei contatori live "stats_noreset" letti altrove nella dashboard,
    # che infatti si azzerano ogni 2 ore quando il BAT esegue il report biorario, un
    # evento che l'uptime del servizio Unbound non riflette): basta leggere due volte
    # questo file e fare la differenza, che e' per costruzione sempre >= 0.
    $cur = Get-SessionTotal
    if (-not $cur) {
        return Get-SessionHistoryTotals
    }

    if (-not $script:SessionHistoryLastDat) {
        # Primo campionamento dopo l'avvio della dashboard: registra solo la baseline,
        # senza scrivere un bucket (altrimenti si "regalerebbe" alla finestra tutto cio'
        # che il BAT aveva gia' accumulato prima che la dashboard iniziasse a guardare).
        $script:SessionHistoryLastDat = $cur
        return Get-SessionHistoryTotals
    }

    $deltaQuery = [double]$cur.query     - [double]$script:SessionHistoryLastDat.query
    $deltaHits  = [double]$cur.cachehits - [double]$script:SessionHistoryLastDat.cachehits
    $deltaRpz   = [double]$cur.blocchi   - [double]$script:SessionHistoryLastDat.blocchi

    # Un valore minore del precedente puo' capitare solo se R:\ e' stata svuotata
    # (spegnimento/riavvio reale del PC: ImDisk e' volatile) e il file e' ripartito
    # da zero: in quel caso tutto il valore corrente e' il delta.
    if ($deltaQuery -lt 0 -or $deltaHits -lt 0 -or $deltaRpz -lt 0) {
        $deltaQuery = [double]$cur.query
        $deltaHits  = [double]$cur.cachehits
        $deltaRpz   = [double]$cur.blocchi
    }

    $script:SessionHistoryLastDat = $cur

    if ($deltaQuery -eq 0 -and $deltaHits -eq 0 -and $deltaRpz -eq 0) {
        return Get-SessionHistoryTotals
    }

    # Chiave del bucket = ora piena in cui la dashboard ha VISTO cambiare il file
    # (session_totale.dat si aggiorna solo ogni ~2h, quindi il delta va comunque
    # attribuito per intero a un'unica ora: qui non c'e' granularita' piu' fine
    # da recuperare, dato che il BAT non scrive un timestamp per ogni singola query).
    $bucketKey = $now.ToString("yyyy-MM-dd HH")

    $buckets = [ordered]@{}
    if ([System.IO.File]::Exists($SessionHistoryJson)) {
        try {
            $raw = Get-Content -LiteralPath $SessionHistoryJson -Raw
            if ($raw) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($prop in $parsed.PSObject.Properties) {
                    $buckets[$prop.Name] = @{
                        query = [double]$prop.Value.query
                        hits  = [double]$prop.Value.hits
                        rpz   = [double]$prop.Value.rpz
                    }
                }
            }
        } catch { $buckets = [ordered]@{} }
    }

    if (-not $buckets.Contains($bucketKey)) {
        $buckets[$bucketKey] = @{ query = [double]0; hits = [double]0; rpz = [double]0 }
    }
    $buckets[$bucketKey].query = [double]$buckets[$bucketKey].query + $deltaQuery
    $buckets[$bucketKey].hits  = [double]$buckets[$bucketKey].hits  + $deltaHits
    $buckets[$bucketKey].rpz   = [double]$buckets[$bucketKey].rpz   + $deltaRpz

    # Scarta i bucket la cui ora e' terminata da piu' di 24h (finestra scorrevole).
    # Si confronta la FINE del bucket (inizio ora + 1h) con la soglia, non il numero
    # di bucket indietro, cosi' l'ora parziale di accensione non viene scartata troppo presto.
    $sogliaMinima = $now.AddHours(-24)
    $chiaviDaRimuovere = @()
    foreach ($k in $buckets.Keys) {
        $bucketTime = [DateTime]::MinValue
        $okParse = [DateTime]::TryParseExact($k, "yyyy-MM-dd HH", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$bucketTime)
        if (-not $okParse -or $bucketTime.AddHours(1) -le $sogliaMinima) {
            $chiaviDaRimuovere += $k
        }
    }
    foreach ($k in $chiaviDaRimuovere) { $buckets.Remove($k) }

    # Scrittura atomica (file temporaneo + rename) per evitare che una lettura
    # concorrente della dashboard trovi il JSON troncato a meta' scrittura.
    try {
        $tmpPath = "$SessionHistoryJson.tmp"
        ($buckets | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $tmpPath -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tmpPath -Destination $SessionHistoryJson -Force
    } catch {}

    $script:SessionHistoryBucketsCache = $buckets
    return Get-SessionHistoryTotals -Buckets $buckets
}

# === FRESCHEZZA AGGIORNAMENTI BLOCKLIST RPZ ===
$script:RpzFreshnessCache     = $null
$script:RpzFreshnessCacheTime = [DateTime]::MinValue
$script:RpzFreshnessCacheTtlSec = 300

function Get-RpzFreshness {
    if ($script:RpzFreshnessCache -and ((Get-Date) - $script:RpzFreshnessCacheTime).TotalSeconds -lt $script:RpzFreshnessCacheTtlSec) {
        return $script:RpzFreshnessCache
    }

    $risultati = @()
    $peggioreScore = 100
    $listaPiuCritica = ""

    foreach ($lista in $RpzListe) {
        $file = Join-Path $UbDir "$($lista.Tag).conf"
        $stato = [ordered]@{
            tag        = $lista.Tag
            nome       = $lista.Nome
            emoji      = $lista.Emoji
            ultimo_agg = "N/D"
            ore_fa     = -1
            eta_txt    = "--"
            esito      = "sconosciuto"
        }

        # 1. Definizione delle soglie dinamiche basate sul tag
        if ($lista.Tag -match 'urlhaus|threatfox|hagezi-tif') {
            $tOk = 12; $tWarn = 24
        } elseif ($lista.Tag -match 'spamhaus') {
            $tOk = 48; $tWarn = 72
        } else {
            $tOk = 96; $tWarn = 168
        }

        $scoreAttuale = 100

        if ([System.IO.File]::Exists($file)) {
            try {
                $mtime  = (Get-Item -LiteralPath $file).LastWriteTime
                $totSec = [int64][math]::Round(((Get-Date) - $mtime).TotalSeconds, 0)
                if ($totSec -lt 0) { $totSec = 0 }
                $secRes    = [int]($totSec % 60)
                $totMin    = [int64][math]::Floor($totSec / 60)
                $minRes    = [int]($totMin % 60)
                $totOre    = [int64][math]::Floor($totMin / 60)
                $oreRes    = [int]($totOre % 24)
                $totGiorni = [int64][math]::Floor($totOre / 24)
                $giorniRes = [int]($totGiorni % 365)
                $anniRes   = [int][math]::Floor($totGiorni / 365)
                $oreFa     = [math]::Round(($totSec / 3600.0), 1)
                $stato.ultimo_agg = $mtime.ToString("dd.MM.yyyy") + " - " + $mtime.ToString("HH:mm:ss")
                $stato.ore_fa     = $oreFa
                $unitaEta = @()
                if ($anniRes -gt 0) { $unitaEta += "${anniRes}a" }
                if ($giorniRes -gt 0 -or $unitaEta.Count -gt 0) { $unitaEta += "$giorniRes g" }
                if ($oreRes -gt 0 -or $unitaEta.Count -gt 0) { $unitaEta += "$oreRes ore" }
                if ($minRes -gt 0 -or $unitaEta.Count -gt 0) { $unitaEta += "$minRes min" }
                $unitaEta += ("{0:D2}" -f $secRes) + " sec"
                $stato.eta_txt    = ($unitaEta -join ' ') + " fa"
                
                # 2. Assegnazione dell'esito in base alla propria soglia
                if ($oreFa -le $tOk) {
                    $stato.esito = "ok"
                } elseif ($oreFa -lt $tWarn) {
                    $stato.esito = "attenzione"
                    # Degrado lineare del punteggio da 100% a 50%
                    $scoreAttuale = [math]::Round(100 - ((($oreFa - $tOk) / ($tWarn - $tOk)) * 50))
                } else {
                    $stato.esito = "scaduta"
                    $scoreAttuale = 50
                }
            } catch {}
        } else {
            $stato.esito = "mancante"
            $scoreAttuale = 0
        }

        if ($scoreAttuale -lt $peggioreScore) { 
            $peggioreScore = $scoreAttuale
            $listaPiuCritica = $lista.Nome
        }

        $risultati += $stato
    }

    $result = @{ liste = $risultati; score_globale = $peggioreScore; lista_critica = $listaPiuCritica }
    $script:RpzFreshnessCache     = $result
    $script:RpzFreshnessCacheTime = Get-Date
    return $result
}

# === STATO DEI TASK PIANIFICATI DEL BUNKER (RPZ, statistiche, NTP, ecc.) ===
# Interroga UNA volta sola TUTTI i task il cui nome contiene "Unbound_Bunker",
# cosi' da non dover elencare a mano ogni singolo task pianificato dal BAT.
# Metodo primario: modulo ScheduledTasks (Get-ScheduledTask/-TaskInfo), che
# restituisce LastRunTime/NextRunTime gia' come [DateTime] nativi - a differenza
# di "schtasks.exe /FO CSV", il cui output testuale va parsato con [DateTime]::Parse
# e puo' fallire silenziosamente (risultando in "N/D" per tutto) se la cultura con
# cui schtasks formatta le date non coincide con quella del processo che legge
# (es. dashboard eseguita come SYSTEM vs sessione utente interattiva). Il modulo
# ScheduledTasks era gia' stato scartato altrove nel codice, ma solo per la
# REGISTRAZIONE di nuovi task (Register-ScheduledTask, vedi /api/force-rpz-update):
# qui si usa solo in LETTURA, operazione molto piu' affidabile. schtasks.exe resta
# come fallback nel solo caso in cui il modulo non sia disponibile sulla macchina.
$script:BunkerTasksCache      = $null
$script:BunkerTasksCacheTime  = [DateTime]::MinValue
$script:BunkerTasksCacheTtlSec = 120

function Get-BunkerScheduledTasks {
    if ($script:BunkerTasksCache -and ((Get-Date) - $script:BunkerTasksCacheTime).TotalSeconds -lt $script:BunkerTasksCacheTtlSec) {
        return $script:BunkerTasksCache
    }

    $risultati = @()
    $moduloOk  = $false

    try {
        $tasks = Get-ScheduledTask -TaskName "Unbound_Bunker*" -ErrorAction Stop
        $moduloOk = $true
        foreach ($task in $tasks) {
            $stato = [ordered]@{
                nome         = $task.TaskName
                ultimo_run   = "N/D"
                min_fa       = -1
                prossimo_run = "N/D"
                last_result  = "N/D"
                esito        = "sconosciuto"
            }
            try {
                $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
                if ($info) {
                    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1900) {
                        $stato.ultimo_run = $info.LastRunTime.ToString("dd.MM.yyyy HH:mm")
                        $stato.min_fa     = [math]::Round(((Get-Date) - $info.LastRunTime).TotalMinutes, 0)
                    }
                    if ($info.NextRunTime -and $info.NextRunTime.Year -gt 1900) {
                        $stato.prossimo_run = $info.NextRunTime.ToString("dd.MM.yyyy HH:mm")
                    }
                    if ($null -ne $info.LastTaskResult) {
                        $stato.last_result = "0x{0:X}" -f $info.LastTaskResult
                        $resultOk = ($info.LastTaskResult -eq 0)
                        if ($stato.min_fa -ge 0) {
                            if (-not $resultOk) {
                                $stato.esito = "attenzione"
                            } elseif ($task.State -ne 'Disabled' -and $info.NextRunTime -and $info.NextRunTime.Year -gt 1900 -and $info.NextRunTime -lt (Get-Date)) {
                                # prossima esecuzione prevista gia' nel passato: il task e' probabilmente
                                # in ritardo/bloccato invece di girare regolarmente
                                $stato.esito = "attenzione"
                            } else {
                                $stato.esito = "ok"
                            }
                        }
                    }
                }
            } catch {}
            $risultati += $stato
        }
    } catch {
        $moduloOk = $false
    }

    if (-not $moduloOk) {
        # Fallback: modulo ScheduledTasks non disponibile su questa macchina
        try {
            $csvRaw = & schtasks.exe /Query /FO CSV /V 2>$null
            if ($LASTEXITCODE -eq 0 -and $csvRaw) {
                $rows = $csvRaw | ConvertFrom-Csv
                foreach ($row in $rows) {
                    $nameProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^task ?name$|nome attivit' } |
                        Select-Object -First 1
                    if (-not $nameProp -or -not $nameProp.Value) { continue }
                    $taskNameFull = $nameProp.Value.TrimStart('\')
                    if ($taskNameFull -notmatch '(?i)Unbound_Bunker') { continue }

                    $runProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^last ?run ?time$|esecuzione precedente' } |
                        Select-Object -First 1
                    $nextProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^next ?run ?time$|esecuzione successiva' } |
                        Select-Object -First 1
                    $resProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^last ?result$|ultimo risultato|risultato' } |
                        Select-Object -First 1

                    $stato = [ordered]@{
                        nome         = $taskNameFull
                        ultimo_run   = "N/D"
                        min_fa       = -1
                        prossimo_run = "N/D"
                        last_result  = "N/D"
                        esito        = "sconosciuto"
                    }

                    $dtRun = $null
                    if ($runProp -and $runProp.Value -and ($runProp.Value -notmatch '(?i)^(N/A|N/D)$')) {
                        foreach ($cultura in @([System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.CultureInfo]::GetCultureInfo("en-US"), [System.Globalization.CultureInfo]::GetCultureInfo("it-IT"))) {
                            if ($dtRun) { break }
                            try { $dtRun = [DateTime]::Parse($runProp.Value, $cultura) } catch {}
                        }
                        if ($dtRun) {
                            $stato.ultimo_run = $dtRun.ToString("dd.MM.yyyy HH:mm")
                            $stato.min_fa     = [math]::Round(((Get-Date) - $dtRun).TotalMinutes, 0)
                        }
                    }
                    $dtNext = $null
                    if ($nextProp -and $nextProp.Value -and ($nextProp.Value -notmatch '(?i)^(N/A|N/D)$')) {
                        foreach ($cultura in @([System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.CultureInfo]::GetCultureInfo("en-US"), [System.Globalization.CultureInfo]::GetCultureInfo("it-IT"))) {
                            if ($dtNext) { break }
                            try { $dtNext = [DateTime]::Parse($nextProp.Value, $cultura) } catch {}
                        }
                        if ($dtNext) { $stato.prossimo_run = $dtNext.ToString("dd.MM.yyyy HH:mm") }
                    }
                    if ($resProp -and $resProp.Value) { $stato.last_result = $resProp.Value }

                    $resultOk = ($stato.last_result -match '^0$|^0x0$')
                    if ($dtRun) {
                        if ($stato.last_result -ne "N/D" -and -not $resultOk) {
                            $stato.esito = "attenzione"
                        } elseif ($dtNext -and $dtNext -lt (Get-Date)) {
                            $stato.esito = "attenzione"
                        } else {
                            $stato.esito = "ok"
                        }
                    }

                    $risultati += $stato
                }
            }
        } catch {}
    }

    $risultati = @($risultati | Sort-Object nome)
    $result = [ordered]@{ tasks = $risultati }
    $script:BunkerTasksCache     = $result
    $script:BunkerTasksCacheTime = Get-Date
    return $result
}

# === STATO LIVE (IN ESECUZIONE ORA) DEI TASK PIANIFICATI ===
# Query separata e leggerissima rispetto a Get-BunkerScheduledTasks: quest'ultima
# e' cachata 120s (chiama anche Get-ScheduledTaskInfo per ogni task, piu' costosa),
# troppo lenta per un indicatore "live". Qui si legge SOLO $task.State
# (Running/Ready/Queued/Disabled), gia' incluso gratis in Get-ScheduledTask senza
# bisogno di -TaskInfo, con una cache di 2s allineata al ritmo di polling del
# frontend (2s): evita di rifare la query se per qualche motivo arrivano due
# richieste ravvicinate, senza introdurre un ritardo percepibile sull'indicatore.
# NOTA: per Boot/Daily/2h, nella rarissima finestra di un self-update
# del BAT (nuova versione rilevata su GitHub), il task madre lancia un helper
# scollegato via "start" e chiude subito con exit 0: per quei pochi secondi lo
# stato potrebbe tornare "Ready" mentre l'helper sta ancora finendo il lavoro.
# Accettabile per un indicatore semplice on/off; il task 30m (AbuseCh30m) non ha
# questo percorso e il suo stato live e' quindi sempre affidabile al 100%.
$script:BunkerTasksLiveCache      = $null
$script:BunkerTasksLiveCacheTime  = [DateTime]::MinValue
$script:BunkerTasksLiveCacheTtlSec = 2

function Get-BunkerTasksLiveState {
    if ($script:BunkerTasksLiveCache -and ((Get-Date) - $script:BunkerTasksLiveCacheTime).TotalSeconds -lt $script:BunkerTasksLiveCacheTtlSec) {
        return $script:BunkerTasksLiveCache
    }

    $live = @{}
    $bunkerTaskNames = @('Unbound_Bunker_Boot', 'Unbound_Bunker_Daily', 'Unbound_Bunker_2h', 'Unbound_Bunker_AbuseCh30m')
    try {
        # [FIX PERFORMANCE] Niente wildcard "Unbound_Bunker*": Get-ScheduledTask con
        # wildcard enumera l'INTERO albero dei task pianificati di Windows prima di
        # filtrare, costoso se richiamato ad ogni polling (2s) invece che ogni 120s
        # come la query "storica" in Get-BunkerScheduledTasks. Passando i 4 nomi
        # esatti, il modulo fa una lookup mirata per nome invece di una scansione
        # completa - stessa informazione, frazione del costo.
        $tasks = Get-ScheduledTask -TaskName $bunkerTaskNames -ErrorAction Stop
        foreach ($task in $tasks) {
            $live[$task.TaskName] = ($task.State -eq 'Running')
        }
    } catch {
        # Fallback: modulo ScheduledTasks non disponibile, stessa strategia di
        # Get-BunkerScheduledTasks (schtasks.exe /FO CSV), leggendo la colonna
        # "Status"/"Stato" invece di Last Run/Next Run/Result.
        try {
            $csvRaw = & schtasks.exe /Query /FO CSV /V 2>$null
            if ($LASTEXITCODE -eq 0 -and $csvRaw) {
                $rows = $csvRaw | ConvertFrom-Csv
                foreach ($row in $rows) {
                    $nameProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^task ?name$|nome attivit' } |
                        Select-Object -First 1
                    if (-not $nameProp -or -not $nameProp.Value) { continue }
                    $taskNameFull = $nameProp.Value.TrimStart('\')
                    if ($taskNameFull -notmatch '(?i)Unbound_Bunker') { continue }

                    $statusProp = $row.PSObject.Properties |
                        Where-Object { $_.Name -match '(?i)^status$|^stato$' } |
                        Select-Object -First 1
                    $isRunning = $statusProp -and $statusProp.Value -match '(?i)^running$|in esecuzione'
                    $live[$taskNameFull] = [bool]$isRunning
                }
            }
        } catch {}
    }

    $script:BunkerTasksLiveCache     = $live
    $script:BunkerTasksLiveCacheTime = Get-Date
    return $live
}

# Combina i dati "storici" (cachati 120s: ultimo_run/prossimo_run/last_result/esito)
# con lo stato live (cachato 2s) aggiungendo il campo in_esecuzione ad ogni task,
# senza dover abbassare il TTL della query piu' pesante.
function Get-BunkerScheduledTasksWithLiveState {
    $base = Get-BunkerScheduledTasks
    $live = Get-BunkerTasksLiveState

    $tasksOut = @($base.tasks | ForEach-Object {
        # [FIX] .Clone() su [ordered]@{...} non e' disponibile come metodo
        # chiamabile su questo PowerShell (5.1): "non contiene un metodo
        # denominato 'Clone'". Si ricostruisce la ordered dictionary a mano
        # copiando le chiavi, evitando del tutto la dipendenza da Clone().
        $orig = $_
        $t = [ordered]@{}
        foreach ($key in $orig.Keys) { $t[$key] = $orig[$key] }
        $t.in_esecuzione = [bool]($live.ContainsKey($orig.nome) -and $live[$orig.nome])
        $t
    })

    return [ordered]@{ tasks = $tasksOut }
}

function Get-RpzTaskLastRun {
    $rpzTaskNames = @("Unbound_Bunker_2h", "Unbound_Bunker_AbuseCh30m")
    $tutti   = Get-BunkerScheduledTasks
    $subset  = @($tutti.tasks | Where-Object { $rpzTaskNames -contains $_.nome })

    $conRun = @($subset | Where-Object { $_.min_fa -ge 0 } | Sort-Object min_fa)
    $piuRecenteTask = $conRun | Select-Object -First 1

    $tasksOut = $subset | ForEach-Object {
        [ordered]@{ task = $_.nome; ultimo_run = $_.ultimo_run; last_result = $_.last_result }
    }

    return [ordered]@{
        tasks              = $tasksOut
        piu_recente        = if ($piuRecenteTask) { $piuRecenteTask.ultimo_run } else { "N/D" }
        piu_recente_min_fa = if ($piuRecenteTask) { $piuRecenteTask.min_fa } else { -1 }
    }
}

# === ESECUZIONE DI UNA SINGOLA FASE (pulsanti nella tabella "Stato di salute") ===
# Il BAT (UnboundBunkerManager.BAT --fase <CODICE>) crea R:\bunker_phase_<CODICE>.run
# all'avvio e lo cancella a fine fase, dopo aver aggiornato la riga della fase in
# R:\bunker_health.json. La Dashboard legge questi marcatori per mostrare "in corso".
$script:PhaseCodes = @('F1','F2','F3','F4','F5','F6','F7','F8','F9','F9B','F10','F10B','F10C','F10D','F10E','F10F','F10G','F10H','F10I','F10J','F11','F12','F13','F14')
$script:PhaseRunDir = "R:\"
$script:PhaseRunCache = @{}
$script:PhaseRunCacheTime = [DateTime]::MinValue
$script:HealthLastGood = $null

# True se esiste un cmd.exe che sta eseguendo il Manager .BAT. Con -SoloFase cerca solo
# le esecuzioni "--fase"; senza, qualunque esecuzione (avvio, refresh pianificati, ecc.).
function Test-ManagerBatRunning {
    param([switch]$SoloFase)
    try {
        $pattern = if ($SoloFase) { '*UnboundBunkerManager*--fase*' } else { '*UnboundBunkerManager*' }
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction Stop |
                   Where-Object { $_.CommandLine -and ($_.CommandLine -like $pattern) })
        return ($procs.Count -gt 0)
    } catch {
        # nel dubbio (query CIM fallita) si assume "in esecuzione": meglio non cancellare
        # un marcatore valido ne' lanciare due fasi insieme
        return $true
    }
}

# Ritorna una hashtable @{ 'F3' = $true; ... } con le fasi attualmente in esecuzione.
# Marcatori orfani (BAT morto o fermo da oltre 30 minuti) vengono ripuliti.
function Get-PhaseRunMarkers {
    if (((Get-Date) - $script:PhaseRunCacheTime).TotalSeconds -lt 1) { return $script:PhaseRunCache }
    $running = @{}
    try {
        $files = @(Get-ChildItem -Path $script:PhaseRunDir -Filter 'bunker_phase_*.run' -File -ErrorAction SilentlyContinue)
        if ($files.Count -gt 0) {
            $batAlive = $null
            foreach ($fi in $files) {
                $code = ($fi.BaseName -replace '^bunker_phase_', '')
                $age  = ((Get-Date) - $fi.LastWriteTime).TotalSeconds
                $valid = $true
                if ($age -gt 1800) {
                    $valid = $false
                } elseif ($age -gt 20) {
                    if ($null -eq $batAlive) { $batAlive = Test-ManagerBatRunning -SoloFase }
                    if (-not $batAlive) { $valid = $false }
                }
                if ($valid) {
                    if ($script:PhaseCodes -contains $code) { $running[$code] = $true }
                } else {
                    try { Remove-Item -LiteralPath $fi.FullName -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    } catch {}
    $script:PhaseRunCache = $running
    $script:PhaseRunCacheTime = Get-Date
    return $running
}

function Get-HealthSnapshot {
    $snap = $null
    if ([System.IO.File]::Exists($HealthJson)) {
        try {
            $snap = (Get-Content -LiteralPath $HealthJson -Raw | ConvertFrom-Json)
        } catch {
            # il BAT sostituisce il file in modo atomico ma una lettura in collisione e'
            # possibile: si riusa l'ultimo snapshot valido invece di svuotare la tabella
            return $script:HealthLastGood
        }
    }
    if ($snap -and $snap.fasi) {
        $run = Get-PhaseRunMarkers
        foreach ($f in @($snap.fasi)) {
            $isRun = ($run.Count -gt 0) -and $run.ContainsKey([string]$f.fase)
            $f | Add-Member -NotePropertyName in_corso -NotePropertyValue ([bool]$isRun) -Force
        }
    }
    $script:HealthLastGood = $snap
    return $snap
}

# === LOG FALLBACK DNS ===
$script:DnsFallbackCache     = $null
$script:DnsFallbackCacheTime = [DateTime]::MinValue
$script:DnsFallbackCacheTtlSec = 5

function Get-DnsFallbackLog {
    if ($script:DnsFallbackCache -and ((Get-Date) - $script:DnsFallbackCacheTime).TotalSeconds -lt $script:DnsFallbackCacheTtlSec) {
        return $script:DnsFallbackCache
    }

    $eventi = @()
    $lines = Get-RpzLogTailCached
    if ($lines -and $lines.Count -gt 0) {
        try {
            $tentativi = @()
            foreach ($ln in $lines) {
                if ($ln -match '(\d{2}:\d{2}:\d{2}).*?info:\s+sending query to\s+([0-9a-fA-F.:]+)(?:@\d+)?') {
                    $tentativi += @{ orario = $matches[1]; ip = $matches[2] }
                }
                elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\s+info:\s+\S+\s+(\S+)\s+\S+\s+IN\s+(NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR)') {
                    if ($tentativi.Count -gt 1) {
                        $eventi += @{
                            orario           = $matches[1]
                            dominio          = $matches[2].TrimEnd('.')
                            rcode_finale     = $matches[3].ToUpper()
                            resolver_tentati = @($tentativi | ForEach-Object { $_.ip })
                            resolver_finale  = $tentativi[-1].ip
                            n_tentativi      = $tentativi.Count
                        }
                    }
                    $tentativi = @()
                }
            }
        } catch {}
    }

    $eventiRecenti = @($eventi | Select-Object -Last 100)
    [array]::Reverse($eventiRecenti)
    $result = @{ totale = $eventi.Count; eventi = $eventiRecenti }
    $script:DnsFallbackCache     = $result
    $script:DnsFallbackCacheTime = Get-Date
    return $result
}

# === DISTRIBUZIONE ORARIA DEI BLOCCHI RPZ ===
$script:BlocksHourlyCache     = $null
$script:BlocksHourlyCacheTime = [DateTime]::MinValue
$script:BlocksHourlyCacheTtlSec = 15

function Get-BlocksHourlyDistribution {
    if ($script:BlocksHourlyCache -and ((Get-Date) - $script:BlocksHourlyCacheTime).TotalSeconds -lt $script:BlocksHourlyCacheTtlSec) {
        return $script:BlocksHourlyCache
    }

    # [FIX] Prima si leggeva da R:\unbound.log (il log live di Unbound), che pero'
    # viene svuotato sia ogni ~2h dal ciclo biorario del BAT (subito dopo l'invio
    # del report Telegram) sia ad ogni riavvio di Unbound/Dashboard (per rilasciare
    # il lock prima del troncamento): il grafico "per ora del giorno" ripartiva da
    # zero molto piu' spesso di quanto il titolo del pannello suggerisse. Si legge
    # ora da session_history.json, la stessa finestra scorrevole a 24h gia' usata
    # per "Finestra dati", che sopravvive sia ai troncamenti del log sia ai riavvii
    # del servizio/della dashboard, e si azzera solo a un vero riavvio di Windows
    # (R:\ e' un RAM disk volatile via ImDisk).
    $buckets = [ordered]@{}
    if ([System.IO.File]::Exists($SessionHistoryJson)) {
        try {
            $raw = Get-Content -LiteralPath $SessionHistoryJson -Raw
            if ($raw) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($prop in $parsed.PSObject.Properties) { $buckets[$prop.Name] = $prop.Value }
            }
        } catch { $buckets = [ordered]@{} }
    }

    # [FIX] In precedenza i bucket venivano ripiegati su un asse fisso "ora del
    # giorno" 00-23 ($ore[$bucketTime.Hour] += ...), perdendo l'ordine cronologico
    # reale. Ora si generano SEMPRE 24 slot orari fissi, dall'ora corrente (a
    # destra) indietro di 23 ore (a sinistra, eventualmente "ieri"), in modo che
    # il grafico scorra sempre da sinistra (piu' vecchio) a destra (adesso).
    # Gli slot senza un bucket corrispondente valgono 0 (mostrato comunque).
    $now = Get-Date
    $oggiStr = $now.ToString("yyyy-MM-dd")
    $ore       = @()
    $etichette = @()
    $giornoOgg = @()
    for ($i = 23; $i -ge 0; $i--) {
        $slotTime = $now.AddHours(-$i)
        $key = $slotTime.ToString("yyyy-MM-dd HH")
        $val = 0
        if ($buckets.Contains($key)) {
            $val = [int][math]::Round([double]$buckets[$key].rpz)
        }
        $ore       += $val
        $etichette += $slotTime.Hour
        $giornoOgg += ($slotTime.ToString("yyyy-MM-dd") -eq $oggiStr)
    }

    $picco = 0
    $oraPicco = -1
    for ($i = 0; $i -lt $ore.Count; $i++) {
        if ($ore[$i] -gt $picco) { $picco = $ore[$i]; $oraPicco = $i }
    }
    # Nota: NIENTE prefisso "," qui - questi array sono proprieta' annidate di un
    # hashtable (non l'input diretto in pipeline di ConvertTo-Json), quindi il
    # bug di collasso "array con un solo elemento" di PowerShell non si applica;
    # aggiungere la virgola avrebbe invece creato un doppio annidamento reale
    # (array-dentro-array) nel JSON, con conseguente rottura del grafico.
    $result = @{ ore = $ore; etichette = $etichette; oggi = $giornoOgg; picco = $picco; ora_picco = $oraPicco }
    $script:BlocksHourlyCache     = $result
    $script:BlocksHourlyCacheTime = Get-Date
    return $result
}

# === STATO WINDOWS UPDATE ===
$script:WinUpdateCache     = $null
$script:WinUpdateCacheTime = [DateTime]::MinValue
$script:WinUpdateCacheTtlSec = 900

function Get-WindowsUpdateStatus {
    if ($script:WinUpdateCache -and ((Get-Date) - $script:WinUpdateCacheTime).TotalSeconds -lt $script:WinUpdateCacheTtlSec) {
        return $script:WinUpdateCache
    }

    $stato = [ordered]@{
        ultimo_agg_installato = "N/D"
        giorni_fa             = -1
        riavvio_richiesto     = $false
        ultima_ricerca        = "N/D"
        ultimo_esito_ricerca  = "N/D"
        aggiornamenti_in_attesa = -1
        errore                = $null
    }

    try {
        $hotfix = Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction SilentlyContinue |
                  Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hotfix -and $hotfix.InstalledOn) {
            $dt = [DateTime]$hotfix.InstalledOn
            $stato.ultimo_agg_installato = $dt.ToString("dd.MM.yyyy")
            $stato.giorni_fa = [math]::Round(((Get-Date) - $dt).TotalDays, 0)
        }
    } catch {}

    try {
        $rebootKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        $stato.riavvio_richiesto = [bool](Test-Path -LiteralPath $rebootKey)
    } catch {}

    try {
        $auSettings = New-Object -ComObject "Microsoft.Update.AutoUpdate" -ErrorAction Stop
        $results = $auSettings.Results
        if ($results.LastSearchSuccessDate) {
            $stato.ultima_ricerca = ([DateTime]$results.LastSearchSuccessDate).ToString("dd.MM.yyyy HH:mm")
        }
        if ($results.LastInstallationSuccessDate) {
            $stato.ultimo_esito_ricerca = "Ultima installazione riuscita: $(([DateTime]$results.LastInstallationSuccessDate).ToString('dd.MM.yyyy HH:mm'))"
        }
    } catch {
        $stato.errore = "COM Windows Update non disponibile: $($_.Exception.Message)"
    }

    $result = $stato
    $script:WinUpdateCache     = $result
    $script:WinUpdateCacheTime = Get-Date
    return $result
}

# === GLOBAL JSON CACHE ===
$script:LastJsonCacheTime = [DateTime]::MinValue
$script:CachedStatusJson  = $null

# === RILEVAMENTO ANOMALIE DI TRAFFICO ===
function Update-AnomalyTracking {
    param($liveRcode)

    if (-not $script:AnomalyState) {
        $script:AnomalyState       = @{}
        $script:AnomalySeenEvents  = New-Object System.Collections.Generic.HashSet[string]
        $script:AnomalyLastMinuteTs = Get-Date
        $script:AnomalyLastPruneTs  = Get-Date
        $script:AnomalyAlerts      = New-Object System.Collections.Generic.List[object]
    }

    foreach ($e in $liveRcode) {
        $sig = "$($e.orario)|$($e.dominio)|$($e.rcode)|$($e.resolver)"
        if ($script:AnomalySeenEvents.Add($sig)) {
            if (-not $script:AnomalyState.ContainsKey($e.dominio)) {
                $script:AnomalyState[$e.dominio] = @{ ewma = 0.0; contaMinuto = 0 }
            }
            $script:AnomalyState[$e.dominio].contaMinuto++
        }
    }

    $now = Get-Date
    if (($now - $script:AnomalyLastMinuteTs).TotalSeconds -ge 60) {
        foreach ($dom in @($script:AnomalyState.Keys)) {
            $st     = $script:AnomalyState[$dom]
            $conta  = $st.contaMinuto
            if ($st.ewma -gt 0.5 -and $conta -ge 8 -and $conta -ge ($st.ewma * 4)) {
                [void]$script:AnomalyAlerts.Add([ordered]@{
                    dominio  = $dom
                    conta    = $conta
                    baseline = [math]::Round($st.ewma, 1)
                    orario   = $now.ToString("HH:mm")
                })
                while ($script:AnomalyAlerts.Count -gt 30) { $script:AnomalyAlerts.RemoveAt(0) }
            }
            $st.ewma = if ($st.ewma -eq 0) { $conta } else { (0.3 * $conta) + (0.7 * $st.ewma) }
            $st.contaMinuto = 0
        }
        $script:AnomalyLastMinuteTs = $now
    }

    if (($now - $script:AnomalyLastPruneTs).TotalSeconds -ge 300) {
        $script:AnomalySeenEvents.Clear()
        $script:AnomalyLastPruneTs = $now
    }

    return $script:AnomalyAlerts
}

function Get-BunkerStatusJson {
    param([switch]$ForceVersions)

    if (-not $ForceVersions -and $script:CachedStatusJson -and ((Get-Date) - $script:LastJsonCacheTime).TotalMilliseconds -lt 1500) {
        return $script:CachedStatusJson
    }

    $hw          = Get-HardwareTier
    $ramDisk     = Get-RamDiskGauge
    $versioni    = Get-BunkerVersions -Force:$ForceVersions
    $engineOn    = Get-EngineStatus
    $stats       = Get-LiveStats
    $liveRcode   = Get-LiveRcodeFeed
    $liveFeedSummary = Get-LiveFeedSummary
    $trafficAnomalie = Update-AnomalyTracking -liveRcode $liveRcode
    $radar       = Get-UpstreamRadar
    $rootRadar   = Get-RootServersRadar
    $rpz         = Get-RpzBreakdown
    $rpzFresh    = Get-RpzFreshness
    $rpzTaskRun  = Get-RpzTaskLastRun
    $bunkerTasks = Get-BunkerScheduledTasksWithLiveState
    $sessione    = Update-SessionHistory
    $salute      = Get-HealthSnapshot
    $netSpeed    = Get-NetworkSpeed
    $ipConn      = Get-IpConnectivityStatus
    $dnsFallback = Get-DnsFallbackLog
    $blocchiOrari = Get-BlocksHourlyDistribution
    $winUpdate   = Get-WindowsUpdateStatus

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

    if (-not $script:UnboundRestartLog) {
        $script:UnboundRestartLog    = New-Object System.Collections.Generic.List[object]
        $script:UnboundLastUptimeSec = $null
    }
    $curUptimeSec = $stats.base.uptime_secondi
    if ($null -ne $script:UnboundLastUptimeSec -and $curUptimeSec -lt ($script:UnboundLastUptimeSec - 5)) {
        [void]$script:UnboundRestartLog.Add([ordered]@{
            orario                = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
            uptime_precedente_sec = $script:UnboundLastUptimeSec
        })
        while ($script:UnboundRestartLog.Count -gt 20) { $script:UnboundRestartLog.RemoveAt(0) }
    }
    $script:UnboundLastUptimeSec = $curUptimeSec

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

    if (-not $script:HistoryBuffer) {
        $script:HistoryBuffer          = New-Object System.Collections.Generic.List[object]
        $script:HistoryLastSampleTime  = [DateTime]::MinValue
        $script:HistoryLastQueryTotali = $null
        $script:HistoryIntervalSec     = 60
        $script:HistoryMaxPoints       = 360
    }
    $nowTs = Get-Date
    if ($script:HistoryBuffer.Count -eq 0 -or ($nowTs - $script:HistoryLastSampleTime).TotalSeconds -ge $script:HistoryIntervalSec) {
        $qps = 0
        if ($null -ne $script:HistoryLastQueryTotali -and $script:HistoryLastSampleTime -ne [DateTime]::MinValue) {
            $deltaSec = ($nowTs - $script:HistoryLastSampleTime).TotalSeconds
            $deltaQ   = $stats.base.query_totali - $script:HistoryLastQueryTotali
            if ($deltaQ -lt 0) { $deltaQ = 0 }
            if ($deltaSec -gt 0) { $qps = [math]::Round($deltaQ / $deltaSec, 2) }
        }
        $latOk = @($radar | Where-Object { $_.ok })
        $latAvg = if ($latOk.Count -gt 0) { [math]::Round((($latOk | Measure-Object -Property ms -Average).Average), 1) } else { 0 }
        [void]$script:HistoryBuffer.Add([ordered]@{
            t     = $nowTs.ToString("HH:mm")
            qps   = $qps
            cache = $stats.base.cache_efficienza_pct
            block = $pctBlocchi
            lat   = $latAvg
        })
        if ($script:HistoryBuffer.Count -gt $script:HistoryMaxPoints) { $script:HistoryBuffer.RemoveAt(0) }
        $script:HistoryLastSampleTime  = $nowTs
        $script:HistoryLastQueryTotali = $stats.base.query_totali
    }

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
        rpz_freshness    = $rpzFresh
        rpz_task_last_run = $rpzTaskRun
        periodic_tasks   = $bunkerTasks
        storico          = $script:HistoryBuffer
        anomalie_traffico = $trafficAnomalie
        unbound_restart_log = $script:UnboundRestartLog
        live_rcode_feed  = $liveRcode
        live_feed_summary = $liveFeedSummary
        upstream_radar   = $radar
        root_radar       = $rootRadar
        dns_fallback_log = $dnsFallback
        blocchi_orari    = $blocchiOrari
        windows_update   = $winUpdate
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
    
    $script:CachedStatusJson = ($obj | ConvertTo-Json -Depth 8 -Compress)
    $script:LastJsonCacheTime = Get-Date

    if ($script:BunkerSyncHash) {
        $script:BunkerSyncHash.Json = $script:CachedStatusJson
        $script:BunkerSyncHash.Ts   = $script:LastJsonCacheTime
    }

    return $script:CachedStatusJson
}

# === INTERFACCIA WEB HTML5 / JS ===

$HtmlPage = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1100.1 - by Mauro Bigoni</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 32 32%27%3E%3Cpath fill=%27%234fb3ff%27 d=%27M16 1.5 3.5 6.5v9c0 8 5.2 13.6 12.5 15 7.3-1.4 12.5-7 12.5-15v-9z%27/%3E%3Cpath fill=%27none%27 stroke=%27%230a0e14%27 stroke-width=%273%27 stroke-linecap=%27round%27 stroke-linejoin=%27round%27 d=%27M10.5 16.5l4 4 7.5-8.5%27/%3E%3C/svg%3E">
<style>
  /* =====================================================================
     TEMA "PRO" - Design elegante e professionale
     ===================================================================== */
  :root {
    color-scheme: dark;
    --bg: #06090d;
    --panel: #0d1219;
    --panel-2: #111720;
    --panel-3: #0a0e14;
    --border: rgba(255, 255, 255, 0.07);
    --border-strong: rgba(255, 255, 255, 0.12);
    --text: #dbe5ee; 
    --dim: #8497ab;
    --text-secondary: #6e849c;
    --green: #208b4c; --green-bright: #3ddc84; 
    --red: #c0392b; --red-bright: #ff5c5c;
    --amber: #d35400; --amber-bright: #ffb300;
    --accent: #4fb3ff; --purple: #b388ff; 
    --orange-bright: #ff8c1a;
    --teal: #0f8a80; --teal-bright: #2dd4bf;
    --cyan: #0e7490; --cyan-bright: #22d3ee;
    --font-ui: "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
    --font-mono: "Consolas", "Cascadia Mono", "Liberation Mono", monospace;
    --radius: 12px; --radius-sm: 8px;
    --shadow-card: 0 1px 0 rgba(255,255,255,0.03) inset, 0 12px 32px rgba(0,0,0,0.45);
  }
  
  * { box-sizing: border-box; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.15) transparent; }
  ::-webkit-scrollbar { width: 8px; height: 8px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15); border-radius: 999px; }
  ::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.25); }
  ::selection { background: rgba(79, 179, 255, 0.35); color: #ffffff; }

  body {
    background:
      radial-gradient(1200px 600px at 15% -10%, rgba(79,179,255,0.06), transparent 60%),
      radial-gradient(1000px 500px at 100% 0%, rgba(179,136,255,0.04), transparent 60%),
      var(--bg);
    background-repeat: no-repeat;
    background-attachment: fixed;
    color: var(--text);
    font-family: var(--font-mono);
    margin: 0; padding: 24px 28px 40px; min-height: 100vh;
    -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
  }

  /* ---------- Intestazione & Animazione Shimmer ---------- */
  .header-container {
    display: flex; justify-content: space-between; align-items: flex-start; gap: 16px;
    margin-bottom: 16px; padding-bottom: 14px; border-bottom: 1px solid var(--border);
  }
  .clock-box {
    background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%);
    border: 1px solid var(--border-strong); border-radius: var(--radius);
    padding: 10px 20px; text-align: right; box-shadow: var(--shadow-card); flex-shrink: 0;
  }
  .clock-time {
    font-size: 1.9em; font-weight: bold; color: var(--accent); line-height: 1.1;
    letter-spacing: 0.04em; font-variant-numeric: tabular-nums;
  }
  .clock-date {
    font-family: var(--font-ui); font-size: 0.78em; color: var(--dim); margin-top: 3px;
    text-transform: capitalize; letter-spacing: 0.04em;
  }

  @keyframes shimmer {
    0% { background-position: -200% center; }
    100% { background-position: 200% center; }
  }

  h1 {
    font-family: var(--font-ui);
    font-size: 1.55em; margin: 0 0 6px 0; font-weight: 700; letter-spacing: 0.01em; line-height: 1.25;
    background: linear-gradient(90deg, var(--accent) 0%, #ffffff 30%, #cfe8ff 50%, #ffffff 70%, var(--accent) 100%);
    background-size: 200% auto;
    -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
    display: inline-block;
    animation: shimmer 4s linear infinite;
  }
  .sub { font-family: var(--font-ui); color: var(--dim); font-size: 0.84em; line-height: 1.5; margin-bottom: 12px; }

/* ---------- Barra pulsanti ---------- */
  .button-row {
    display: flex; flex-wrap: wrap; align-items: center; gap: 14px;
    background: var(--panel); border: 1px solid var(--border); border-radius: var(--radius);
    padding: 16px 20px; margin-bottom: 20px; box-shadow: var(--shadow-card);
  }
  
  /* RISOLVE IL PROBLEMA DEGLI SPAZI IRREGOLARI: nasconde gli span vuoti */
  .button-row-status:empty { display: none; }
  .button-row-status { font-family: var(--font-ui); font-size: 0.85em; margin: 0 4px; flex: 1 1 100%; text-align: center; }

/* ---------- Stile Base Pulsanti (Premium Glassmorphism) ---------- */
  .btn-action {
    flex: 1 1 auto; 
    display: flex; align-items: center; justify-content: center; gap: 10px;
    padding: 12px 18px; 
    font-family: var(--font-ui); font-size: 0.86em; font-weight: 600; letter-spacing: 0.03em;
    border-radius: var(--radius-sm); cursor: pointer;
    transition: all 0.3s cubic-bezier(0.2, 0.8, 0.2, 1); /* Transizione ancora più vellutata */
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    white-space: nowrap; backdrop-filter: blur(8px);
    text-shadow: 0 1px 2px rgba(0,0,0,0.6); /* Fa risaltare il testo e le emoji */
  }
  .btn-action:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .btn-action:disabled { opacity: 0.4; cursor: not-allowed; filter: grayscale(60%); transform: none; box-shadow: none; }
  .btn-action:hover:not(:disabled) { transform: translateY(-2px); }
  .btn-action:active:not(:disabled) { transform: translateY(0); box-shadow: 0 2px 6px rgba(0,0,0,0.4); }

  /* 🔄 AMBER (Riavvia Dashboard) */
  .btn-amber {
    background: linear-gradient(180deg, rgba(211,84,0,0.18) 0%, rgba(211,84,0,0.05) 100%);
    border: 1px solid rgba(255,179,0,0.25);
    border-top-color: rgba(255,179,0,0.5); /* Luce riflessa dall'alto */
    color: var(--amber-bright);
  }
  .btn-amber:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(211,84,0,0.28) 0%, rgba(211,84,0,0.1) 100%);
    border-color: rgba(255,179,0,0.5);
    box-shadow: 0 6px 20px rgba(211,84,0,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff; /* Il testo diventa bianco ottico all'hover */
  }

  /* 🛡️ BLUE (Riavvia Unbound) */
  .btn-blue {
    background: linear-gradient(180deg, rgba(79,179,255,0.18) 0%, rgba(79,179,255,0.05) 100%);
    border: 1px solid rgba(79,179,255,0.25);
    border-top-color: rgba(79,179,255,0.5);
    color: var(--accent);
  }
  .btn-blue:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(79,179,255,0.28) 0%, rgba(79,179,255,0.1) 100%);
    border-color: rgba(79,179,255,0.5);
    box-shadow: 0 6px 20px rgba(79,179,255,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* 🔧 PURPLE (Riavvia Manager) */
  .btn-purple {
    background: linear-gradient(180deg, rgba(179,136,255,0.18) 0%, rgba(179,136,255,0.05) 100%);
    border: 1px solid rgba(179,136,255,0.25);
    border-top-color: rgba(179,136,255,0.5);
    color: var(--purple);
  }
  .btn-purple:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(179,136,255,0.28) 0%, rgba(179,136,255,0.1) 100%);
    border-color: rgba(179,136,255,0.5);
    box-shadow: 0 6px 20px rgba(179,136,255,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* 📥 GREEN (Forza Aggiornamento RPZ) */
  .btn-green {
    background: linear-gradient(180deg, rgba(61,220,132,0.18) 0%, rgba(61,220,132,0.05) 100%);
    border: 1px solid rgba(61,220,132,0.25);
    border-top-color: rgba(61,220,132,0.5);
    color: var(--green-bright);
  }
  .btn-green:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(61,220,132,0.28) 0%, rgba(61,220,132,0.1) 100%);
    border-color: rgba(61,220,132,0.5);
    box-shadow: 0 6px 20px rgba(61,220,132,0.2), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* ⬇️ RED (Aggiorna Dash) */
  .btn-red {
    background: linear-gradient(180deg, rgba(255,92,92,0.18) 0%, rgba(255,92,92,0.05) 100%);
    border: 1px solid rgba(255,92,92,0.25);
    border-top-color: rgba(255,92,92,0.5);
    color: var(--red-bright);
  }
  .btn-red:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(255,92,92,0.28) 0%, rgba(255,92,92,0.1) 100%);
    border-color: rgba(255,92,92,0.5);
    box-shadow: 0 6px 20px rgba(255,92,92,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* 🧩 TEAL (Aggiorna Componenti: Dashboard + Engine/BAT/service.conf via Manager) */
  .btn-teal {
    background: linear-gradient(180deg, rgba(45,212,191,0.18) 0%, rgba(45,212,191,0.05) 100%);
    border: 1px solid rgba(45,212,191,0.25);
    border-top-color: rgba(45,212,191,0.5);
    color: var(--teal-bright);
  }
  .btn-teal:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(45,212,191,0.28) 0%, rgba(45,212,191,0.1) 100%);
    border-color: rgba(45,212,191,0.5);
    box-shadow: 0 6px 20px rgba(45,212,191,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* 🔀 CYAN (Toggle DNS scheda di rete) */
  .btn-cyan {
    background: linear-gradient(180deg, rgba(34,211,238,0.18) 0%, rgba(34,211,238,0.05) 100%);
    border: 1px solid rgba(34,211,238,0.25);
    border-top-color: rgba(34,211,238,0.5);
    color: var(--cyan-bright);
  }
  .btn-cyan:hover:not(:disabled) {
    background: linear-gradient(180deg, rgba(34,211,238,0.28) 0%, rgba(34,211,238,0.1) 100%);
    border-color: rgba(34,211,238,0.5);
    box-shadow: 0 6px 20px rgba(34,211,238,0.25), inset 0 1px 0 rgba(255,255,255,0.15);
    color: #ffffff;
  }

  /* ---------- Overlay riavvio e toast ---------- */
  .restart-overlay {
    display: none; position: fixed; inset: 0;
    background: rgba(6, 9, 13, 0.9); backdrop-filter: blur(8px);
    z-index: 9999; align-items: center; justify-content: center;
  }
  .restart-overlay.active { display: flex; }
  .restart-overlay-box {
    background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%);
    border: 1px solid var(--border-strong); border-radius: 14px;
    padding: 30px 42px; min-width: 380px; max-width: 90vw; text-align: center;
    box-shadow: 0 16px 48px rgba(0,0,0,0.65);
  }
  .restart-overlay-icon { font-size: 2.4em; margin-bottom: 8px; }
  .restart-overlay-title { font-family: var(--font-ui); font-size: 1.15em; font-weight: 700; color: var(--text); margin-bottom: 6px; }
  .restart-overlay-sub { font-family: var(--font-ui); font-size: 0.85em; color: var(--dim); margin-bottom: 20px; line-height: 1.5; }
  .restart-progress-track {
    width: 100%; height: 10px; background: rgba(255,255,255,0.05);
    border: 1px solid var(--border); border-radius: 999px; overflow: hidden;
  }
  .restart-progress-fill {
    height: 100%; width: 0%; border-radius: 999px; transition: width 0.4s ease;
    background-image: repeating-linear-gradient(45deg, var(--accent) 0 12px, rgba(79,179,255,0.35) 12px 24px);
    background-size: 34px 34px;
    animation: restart-stripes 0.9s linear infinite;
  }
  @keyframes restart-stripes {
    from { background-position: 0 0; }
    to { background-position: 34px 0; }
  }
  .restart-progress-pct { margin-top: 10px; font-size: 0.85em; color: var(--dim); letter-spacing: 0.5px; font-variant-numeric: tabular-nums; }

  /* ---------- Banner esecuzione/attenzione (prima riga della dashboard) ---------- */
  .status-banner {
    display: flex; align-items: center; gap: 10px;
    padding: 10px 20px; margin-bottom: 14px;
    border-radius: 10px; font-family: var(--font-ui);
    font-size: 0.95em; font-weight: 600; letter-spacing: 0.2px;
    border: 1px solid transparent; transition: background 0.3s ease, border-color 0.3s ease;
  }
  .status-banner .sb-icon { font-size: 1.1em; line-height: 1; }
  .status-banner .sb-label { font-weight: 800; letter-spacing: 0.5px; margin-right: 2px; }
  .status-banner.sb-ok {
    background: rgba(61,220,132,0.08); border-color: rgba(61,220,132,0.3); color: var(--green-bright);
  }
  .status-banner.sb-warn {
    background: rgba(255,179,0,0.10); border-color: rgba(255,179,0,0.35); color: var(--amber-bright);
  }
  .status-banner.sb-error {
    background: rgba(255,92,92,0.12); border-color: rgba(255,92,92,0.4); color: var(--red-bright);
  }

  .update-toast {
    position: fixed; top: 20px; left: 50%;
    transform: translateX(-50%) translateY(-12px);
    background: var(--panel); border: 1px solid var(--green-bright); color: var(--text);
    font-family: var(--font-ui);
    padding: 12px 22px; border-radius: 10px; font-size: 0.95em; font-weight: 600;
    box-shadow: 0 10px 30px rgba(0,0,0,0.55), 0 0 0 3px rgba(61,220,132,0.12);
    z-index: 10000; opacity: 0; pointer-events: none;
    transition: opacity 0.35s ease, transform 0.35s ease;
  }
  .update-toast.active { opacity: 1; transform: translateX(-50%) translateY(0); }

  /* ---------- Badge di stato ---------- */
  .badges {
    display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; width: 100%;
    align-items: center; padding-bottom: 6px;
  }
  .badge {
    font-family: var(--font-ui);
    padding: 8px 14px; border-radius: var(--radius-sm); font-size: 0.9em; font-weight: 600;
    letter-spacing: 0.02em;
    display: inline-flex; align-items: center; box-shadow: 0 4px 10px rgba(0,0,0,0.2);
    white-space: nowrap; flex-shrink: 0; border: 1px solid transparent;
  }
  .badge b { font-family: var(--font-mono); font-weight: 700; }

  .badge.ok { background-color: rgba(61,220,132,0.08); color: var(--green-bright); border-color: rgba(61,220,132,0.3); }
  .badge.bad { background-color: rgba(255,92,92,0.12); color: #ffffff; border-color: var(--red-bright); }
  .badge.ram { background-color: rgba(179,136,255,0.08); color: var(--purple); border-color: rgba(179,136,255,0.3); }
  .badge.net { background-color: rgba(255,179,0,0.08); color: var(--amber-bright); border-color: rgba(255,179,0,0.3); }
  .badge.blocchi { background-color: rgba(255,92,92,0.08); color: var(--red-bright); border-color: rgba(255,92,92,0.3); }
  .badge.latenza { background-color: rgba(79,179,255,0.08); color: var(--accent); border-color: rgba(79,179,255,0.3); }

  .cache-highlight {
    background: linear-gradient(135deg, rgba(79,179,255,0.12) 0%, rgba(61,220,132,0.12) 100%);
    color: #ffffff; border-color: rgba(61,220,132,0.4);
    box-shadow: 0 0 0 3px rgba(61,220,132,0.05), 0 6px 20px rgba(61,220,132,0.15);
  }
  .cache-highlight b { color: var(--green-bright); font-size: 1.15em; margin-left: 6px; }

  .gain-highlight {
    font-size: 1em; padding: 10px 18px; border-radius: 10px;
    border: 1px solid var(--amber-bright); box-shadow: 0 0 18px rgba(255,179,0,0.2);
    transition: all 0.4s ease-in-out;
  }
  .gain-highlight b { font-size: 1.32em; margin-left: 6px; text-shadow: 0 2px 5px rgba(0,0,0,0.5); }

  /* ---------- Indicatori di stato (pallini radar) ---------- */
  .status-dot-container { display: inline-flex; align-items: center; justify-content: center; width: 16px; height: 16px; vertical-align: middle; }
  .status-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; position: relative; }
  .status-dot.ok { background-color: var(--green-bright); box-shadow: 0 0 8px var(--green-bright); }
  .status-dot.ok::after {
    content: ''; position: absolute; top: -3px; left: -3px; right: -3px; bottom: -3px;
    border-radius: 50%; border: 2px solid var(--green-bright);
    animation: radar-pulse-green 2s cubic-bezier(0.2, 0.8, 0.2, 1) infinite; opacity: 0;
  }
  .status-dot.bad { background-color: var(--red-bright); box-shadow: 0 0 8px var(--red-bright); }
  .status-dot.bad::after {
    content: ''; position: absolute; top: -3px; left: -3px; right: -3px; bottom: -3px;
    border-radius: 50%; border: 2px solid var(--red-bright);
    animation: radar-pulse-red 2s cubic-bezier(0.2, 0.8, 0.2, 1) infinite; opacity: 0;
  }
  @keyframes radar-pulse-green {
    0% { transform: scale(0.5); opacity: 0.8; }
    70% { transform: scale(2.2); opacity: 0; }
    100% { transform: scale(2.5); opacity: 0; }
  }
  @keyframes radar-pulse-red {
    0% { transform: scale(0.5); opacity: 0.8; }
    70% { transform: scale(2.2); opacity: 0; }
    100% { transform: scale(2.5); opacity: 0; }
  }

  /* ---------- Indicatore LIVE / OFFLINE ---------- */
  .live-indicator { display: flex; align-items: center; gap: 14px; width: 100%; margin: 8px 0 16px 0; }
  .live-badge {
    display: flex; align-items: center; gap: 9px; flex-shrink: 0;
    padding: 7px 16px; border-radius: 999px;
    font-family: var(--font-ui); font-size: 0.8em; font-weight: 700;
    letter-spacing: 0.07em; text-transform: uppercase; white-space: nowrap;
    border: 1px solid transparent;
  }
  .live-badge.on {
    color: var(--green-bright); background: rgba(60, 220, 130, 0.08);
    border-color: rgba(60, 220, 130, 0.3);
  }
  .live-badge.off {
    color: var(--red-bright); background: rgba(255, 92, 92, 0.1);
    border-color: rgba(255, 92, 92, 0.4);
    animation: liveBadgeBlink 1s steps(2, start) infinite;
  }
  @keyframes liveBadgeBlink { 50% { opacity: 0.45; } }

  .live-bar-track {
    position: relative; flex: 1 1 auto; height: 6px; margin-left: 15px;
    background: rgba(255,255,255,0.03); border-radius: 999px; overflow: hidden;
  }
  .live-scanner {
    position: absolute; top: 0; left: -5%; height: 100%; width: 110%;
    background: linear-gradient(90deg, transparent 0%, rgba(61, 220, 132, 0.1) 15%, var(--green-bright) 50%, rgba(61, 220, 132, 0.1) 85%, transparent 100%);
    animation: heartbeatPulse 2.5s ease-in-out infinite;
  }
  .live-bar-track.offline .live-scanner {
    background: linear-gradient(90deg, transparent 0%, rgba(255, 92, 92, 0.2) 15%, var(--red-bright) 50%, rgba(255, 92, 92, 0.2) 85%, transparent 100%);
    animation: offlineBlink 1s steps(2, start) infinite;
  }
  @keyframes heartbeatPulse {
    0%, 100% { opacity: 0.1; transform: scaleX(0.9); }
    50% { opacity: 1; transform: scaleX(1); }
  }
  @keyframes offlineBlink {
    0%, 100% { opacity: 1; transform: scaleX(1); }
    50% { opacity: 0.1; }
  }

  /* ---------- Schede metriche (boost / bunker) ---------- */
  .boost-subrow {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 12px; margin-bottom: 10px; background: rgba(0,0,0,0.15); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 14px;
  }
  .bunker-subrow {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 14px; margin-bottom: 22px; background: rgba(0,0,0,0.15); border: 1px solid rgba(79, 179, 255, 0.15);
    border-radius: var(--radius); padding: 14px; box-shadow: inset 0 4px 20px rgba(0,0,0,0.2);
  }
  .bunker-layout { display: flex; gap: 14px; margin-bottom: 22px; align-items: stretch; flex-wrap: wrap; }
  .bunker-rpz-panel { flex: 1 1 380px; max-width: 460px; display: flex; flex-direction: column; }
  .bunker-badges-grid { flex: 3 1 620px; margin-bottom: 0; }
  @media (max-width: 900px) {
    .bunker-rpz-panel { max-width: none; }
  }

  .boost-item {
    background: rgba(255,255,255,0.02); border: 1px solid var(--border); border-radius: 10px; padding: 12px 16px;
    transition: all 0.2s ease;
  }
  .boost-item:hover { border-color: rgba(255,255,255,0.15); background: rgba(255,255,255,0.03); }
  .boost-item-header {
    display: flex; justify-content: space-between; gap: 10px; align-items: baseline;
    font-family: var(--font-ui); font-size: 0.72em; color: var(--dim);
    margin-bottom: 8px; font-weight: 700; letter-spacing: 0.05em;
  }
  .boost-item-val { color: var(--text); font-family: var(--font-mono); font-size: 1.15em; font-weight: 700; }
  .boost-item-wide { grid-column: span 2; }
  .boost-item-extrawide { grid-column: span 3; }
  @media (max-width: 650px) {
    .boost-item-wide, .boost-item-extrawide { grid-column: span 1; }
  }

  .g-bar-bg { background: rgba(0,0,0,0.3); border-radius: 999px; height: 8px; overflow: hidden; display: flex; }
  .g-bar-fill { height: 100%; border-radius: 999px; transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1), background 0.5s ease; }

  /* ---------- Pannelli ---------- */
  .panel {
    background: linear-gradient(180deg, rgba(255,255,255,0.01) 0%, rgba(255,255,255,0) 100%), var(--panel);
    border: 1px solid var(--border); border-radius: var(--radius);
    padding: 20px; margin-bottom: 20px; box-shadow: var(--shadow-card);
  }
  .panel h2 {
    display: flex; align-items: center; gap: 9px;
    margin: 0 0 16px 0; font-family: var(--font-ui); font-size: 0.82em; font-weight: 700;
    letter-spacing: 0.08em; text-transform: uppercase; color: #c9d6e3;
    border-bottom: 1px solid rgba(255,255,255,0.04); padding-bottom: 12px;
  }
  .panel h2::before { content: ''; width: 4px; height: 14px; border-radius: 2px; background: var(--accent); flex-shrink: 0; }

  .panel-versioni {
    background: linear-gradient(180deg, #101621 0%, var(--panel) 100%);
    border: 1px solid rgba(79, 179, 255, 0.2) !important; 
    padding: 16px !important; margin-bottom: 14px !important;
    display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap;
  }
  .panel-versioni h2 { color: #e6eef6 !important; border: none !important; margin: 0 !important; padding: 0 !important; font-size: 0.78em !important; white-space: nowrap; }

  .stat-ver {
    background: rgba(0,0,0,0.2); border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 8px 14px;
    display: flex; align-items: center; gap: 8px; font-size: 0.82em; transition: all 0.2s ease;
  }
  .stat-ver:hover { border-color: rgba(79, 179, 255, 0.4); box-shadow: 0 4px 12px rgba(0,0,0,0.3); }
  
  .ver-status-ok, .ver-status-warn {
    font-family: var(--font-ui); font-size: 0.75em; font-weight: 700; letter-spacing: 0.03em;
    padding: 3px 10px; border-radius: 999px; border: 1px solid transparent;
  }
  .ver-status-ok { color: var(--green-bright); background: rgba(61,220,132,0.08); border-color: rgba(61,220,132,0.25); }
  .ver-status-warn { color: var(--amber-bright); background: rgba(255,179,0,0.08); border-color: rgba(255,179,0,0.25); }

  #statsVersioni { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  #statsVersioni .stat-ver { flex-wrap: wrap; }

  .winupdate-tasks-row { display: flex; gap: 20px; margin-bottom: 14px; align-items: stretch; flex-wrap: wrap; }
  .winupdate-tasks-row > .panel-versioni { margin-bottom: 0; flex-direction: column; align-items: flex-start; }
  .winupdate-third { flex: 1 1 220px; }
  .periodic-tasks-twothird { flex: 2 1 340px; }
  .periodic-tasks-grid { display: flex; flex-direction: column; gap: 10px; width: 100%; }
  
  .periodic-task-chip {
    background: rgba(0,0,0,0.2); border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 12px 16px;
    display: flex; flex-direction: row; align-items: center; justify-content: space-between; gap: 14px;
    font-size: 0.8em; width: 100%; transition: border-color 0.2s;
  }
  .periodic-task-chip:hover { border-color: rgba(255,255,255,0.15); }
  .periodic-task-chip .ptc-nome { font-weight: bold; color: var(--text); flex: 0 1 auto; }
  .periodic-task-chip .ptc-info { flex: 0 0 auto; margin-left: auto; display: flex; align-items: baseline; gap: 10px; white-space: nowrap; }
  .periodic-task-chip .ptc-eta { font-size: 0.92em; }
  .periodic-task-chip .ptc-sep { color: var(--dim); opacity: 0.4; }
  .periodic-task-chip .ptc-run { color: var(--dim); font-size: 0.85em; }
  .periodic-task-chip.ptc-live { border-color: rgba(255, 214, 0, 0.4); background: rgba(255, 214, 0, 0.05); }
  
  .ptc-live-badge {
    display: inline-flex; align-items: center; gap: 6px; flex-shrink: 0;
    color: #ffd600; font-family: var(--font-ui); font-weight: 700; font-size: 0.82em;
    letter-spacing: 0.04em; text-transform: uppercase; white-space: nowrap;
  }
  .ptc-live-dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #ffd600; box-shadow: 0 0 8px rgba(255, 214, 0, 0.6);
    animation: ptcLivePulse 1.5s ease-in-out infinite;
  }
  @keyframes ptcLivePulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.4; transform: scale(0.8); }
  }

  /* ---------- Statistiche e card ---------- */
  .stats-grid, .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 14px; margin-bottom: 16px; }
  .stat { background: rgba(255,255,255,0.015); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; transition: transform 0.2s; }
  .stat:hover { transform: translateY(-2px); border-color: rgba(255,255,255,0.1); }
  .stat .val { font-size: 1.45em; font-weight: bold; font-variant-numeric: tabular-nums; }
  .stat .lbl { font-family: var(--font-ui); color: var(--dim); font-size: 0.78em; margin-top: 4px; }

  .stat-breakdown-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 10px; margin-bottom: 12px; }
  #gridTypes { grid-template-columns: repeat(4, 1fr); }
  .stat-card { border-radius: 10px; padding: 12px 10px; text-align: center; border: 1px solid var(--border); background: rgba(0,0,0,0.15); transition: transform 0.2s ease, border-color 0.2s; }
  .stat-card:hover { transform: translateY(-3px); border-color: rgba(255,255,255,0.15); }
  .stat-card .sc-lbl { font-family: var(--font-ui); font-size: 0.74em; font-weight: 700; margin-bottom: 6px; letter-spacing: 0.05em; }
  .stat-card .sc-val { font-size: 1.5em; font-weight: bold; line-height: 1.1; margin-bottom: 4px; font-variant-numeric: tabular-nums; }
  .stat-card .sc-pct { font-size: 0.9em; font-weight: bold; opacity: 0.85; }

  /* ---------- Tabelle ---------- */
  .table-scroll { border: 1px solid var(--border); border-radius: var(--radius-sm); background: var(--panel-2); overflow: hidden; }
  .table-scroll table { width: 100%; border-collapse: collapse; font-size: 0.85em; border: none; }
  .table-scroll th, .table-scroll td { text-align: left; padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,0.03); }
  .table-scroll th { position: sticky; top: 0; background: rgba(255,255,255,0.02); z-index: 2; box-shadow: 0 1px 0 var(--border); backdrop-filter: blur(5px); }

  table { width: 100%; border-collapse: collapse; font-size: 0.85em; }
  th, td { text-align: left; padding: 9px 14px; border-bottom: 1px solid rgba(255,255,255,0.03); }
  th {
    font-family: var(--font-ui); color: var(--dim); font-weight: 600; font-size: 0.78em;
    text-transform: uppercase; letter-spacing: 0.05em; background: rgba(255,255,255,0.015);
  }
  tbody tr { transition: background 0.15s; }
  tbody tr:hover td { background: rgba(255,255,255,0.025); }

#tabellaRadar th, #tabellaRadar td,
  #tabellaRootRadar th, #tabellaRootRadar td {
    padding: 5px 4px !important; /* Padding ridotto al minimo indispensabile */
    font-size: 0.75em !important;
    line-height: 1.2 !important;
    letter-spacing: -0.2px !important;
    /* RIMOSSO white-space: nowrap; così il testo si adatta fluidamente al box */
  }
  
  /* Proteggiamo solo le colonne con IP e Latenza per non spezzare i numeri */
  #tabellaRadar td:nth-child(3), #tabellaRadar td:nth-child(4),
  #tabellaRootRadar td:nth-child(4), #tabellaRootRadar td:nth-child(5) {
    white-space: nowrap !important;
  }

  details { margin-top: 8px; }
  summary { cursor: pointer; color: var(--accent); font-weight: bold; transition: color 0.2s; }
  summary:hover { color: #82caff; }

  .esito-warn { color: var(--red-bright); font-weight: bold; }
  .esito-ok { color: var(--green-bright); }
  .esito-running { color: #ffd600; font-weight: bold; animation: faseRunningPulse 1.5s ease-in-out infinite; }
  @keyframes faseRunningPulse { 50% { opacity: 0.5; } }
  
  .fase-btn-cell { width: 44px; text-align: center; padding-right: 6px !important; }
  .btn-fase {
    width: 32px; height: 28px; padding: 0; line-height: 1; font-size: 0.85em; cursor: pointer;
    background: rgba(79, 179, 255, 0.08); color: var(--accent);
    border: 1px solid rgba(79, 179, 255, 0.3); border-radius: 6px; transition: all 0.2s ease;
  }
  .btn-fase:hover:not(:disabled) { background: rgba(79, 179, 255, 0.2); border-color: var(--accent); transform: scale(1.05); }
  .btn-fase:disabled { opacity: 0.3; cursor: not-allowed; }
  
  .esito-attenzione { color: var(--amber-bright); font-weight: bold; }
  .esito-critica { color: var(--orange-bright); font-weight: bold; }
  .latency { color: var(--accent); font-weight: bold; }
  .muted { color: var(--text-secondary); }

  .bar-bg { background: rgba(0,0,0,0.2); border: 1px solid var(--border); border-radius: 6px; height: 18px; overflow: hidden; display: flex; }
  .bar-fill { height: 100%; transition: width 0.4s ease; }
  .legend-box { font-family: var(--font-ui); font-size: 0.84em; color: var(--dim); margin-top: 12px; line-height: 1.8; }

  /* ---------- Layout a colonne e Allineamento Altezza LOG ---------- */
  .grid-three-columns { display: flex; gap: 20px; flex-wrap: wrap; margin-bottom: 20px; }
  .grid-three-columns > div { flex: 1; min-width: 310px; margin-bottom: 0; }

  .live-log-row { display: flex; gap: 20px; margin-bottom: 20px; align-items: stretch; flex-wrap: wrap; }
  
  .live-log-left { flex: 2 1 460px; display: flex; flex-direction: column; gap: 20px; }
  .live-log-left .panel { margin-bottom: 0; }
  
  .badges-panel { flex: 1 1 auto; display: flex; align-items: center; }
  .badges-panel .badges { margin-bottom: 0; width: 100%; align-content: space-evenly; row-gap: 16px; }
  .badges-panel .badge { font-size: 0.95em; padding: 10px 16px; }
  .badges-panel .gain-highlight { margin-left: 0; }
  
  .live-log-panel { flex: 1.6 1 380px; display: flex; flex-direction: column; min-width: 380px; margin-bottom: 0; }
  
  /* L'altezza si allinea ai badge grazie al flex: 1 1 0px, non spingendo più in basso */
.live-log-feed {
    flex: 1 1 0px; /* Ignora l'altezza del testo interno */
    overflow-y: auto; 
    overflow-x: hidden; 
    font-family: var(--font-mono); 
    font-size: 0.78em;
    line-height: 1.8; 
    background: rgba(0,0,0,0.2); 
    border: 1px solid var(--border); 
    border-radius: var(--radius-sm);
    padding: 12px 14px; 
    min-height: 400px; /* Misura di sicurezza per i display verticali/smartphone */
    /* Nessun max-height: ora riempirà fluidamente tutto lo spazio lasciato dalla colonna sinistra! */
    position: relative;
  }
  
  .live-log-track { display: flex; flex-direction: column; }
  .live-log-line { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; border-radius: 4px; padding: 2px 6px; transition: background 0.15s; }
  .live-log-line:hover { background: rgba(255,255,255,0.03); }
  .live-log-num { display: inline-block; min-width: 5.5em; text-align: right; color: var(--text-secondary); margin-right: 8px; }
  
  @keyframes liveLogEntra { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
  .live-log-line.nuova { animation: liveLogEntra 0.3s cubic-bezier(0.2, 0, 0, 1); }
  .live-log-subtitle { font-family: var(--font-ui); font-size: 0.82em; color: var(--dim); margin: -4px 0 12px 0; }

  /* ---------- Grafici storici ---------- */
  .storico-grid { display: flex; gap: 20px; flex-wrap: wrap; }
  .storico-chart-box { flex: 1; min-width: 260px; }
  .storico-chart-title {
    font-family: var(--font-ui); font-size: 0.74em; font-weight: 700; color: #b7c6d6;
    text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px;
  }
  .storico-chart-box svg { width: 100%; height: 110px; display: block; background: rgba(0,0,0,0.15); border: 1px solid var(--border); border-radius: var(--radius-sm); }
  .storico-range { font-family: var(--font-ui); font-size: 0.8em; color: var(--dim); margin-top: 12px; text-align: right; }
  
  .rpz-fresh-row { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.03); padding: 10px 4px; font-size: 0.92em; gap: 12px; flex-wrap: wrap; }
  .rpz-fresh-row:last-child { border-bottom: none; }

  #inputRicercaRcode { outline: none; transition: all 0.2s ease; }
  #inputRicercaRcode::placeholder { color: var(--text-secondary); }
  #inputRicercaRcode:focus { border-color: var(--accent) !important; box-shadow: 0 0 0 3px rgba(79, 179, 255, 0.15); background: rgba(255,255,255,0.02); }

  /* Compressa al minimo la colonna "Stato" per avvicinare i Provider/Root */
  #tabellaRadar th:first-child, #tabellaRadar td:first-child,
  #tabellaRootRadar th:first-child, #tabellaRootRadar td:first-child {
    width: 1% !important; /* Si restringe esattamente alla larghezza del contenuto */
    padding-right: 2px !important; /* Elimina il margine inutile verso destra */
    text-align: center; /* Centra il pallino e il testo "Stato" */
  }
</style>
</head>
<body>

<div class="status-banner sb-ok" id="statusBanner">
  <span class="sb-icon" id="statusBannerIcon">&#9989;</span>
  <span id="statusBannerText">ESECUZIONE REGOLARE</span>
</div>

<div class="header-container">
  <div>
    <h1>&#128737; UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1100.1 - by Mauro Bigoni</h1>
    <div class="sub" id="subheader">Connessione al Bunker in corso...</div>
  </div>
  <div class="clock-box">
    <div class="clock-time" id="clockTime">--:--:--</div>
    <div class="clock-date" id="clockDate">-----------------</div>
  </div>
</div>

<div class="button-row" id="buttonRow">
  <button id="btnRestart" onclick="confirmRestart()" class="btn-action btn-amber" title="Riavvia la Dashboard ed esegui la verifica della porta">
    &#128260; Riavvia Dashboard
  </button>
  <button id="btnRestartUnbound" onclick="confirmRestartUnbound()" class="btn-action btn-blue" title="Riavvia il servizio Windows di Unbound">
    &#128737;&#65039; Riavvia Unbound
  </button>
  <button id="btnRestartManager" onclick="confirmRestartManager()" class="btn-action btn-purple" title="Rilancia lo scheduled task Unbound_Bunker_Boot che avvia UnboundBunkerManager.BAT">
    &#128295; Riavvia Manager .BAT
  </button>
  <span id="restartManagerStatus" class="muted button-row-status"></span>
  <button id="btnForceRpz" onclick="confirmForceRpzUpdate()" class="btn-action btn-green" title="Avvia subito i task pianificati di aggiornamento RPZ (HaGeZi/Spamhaus/TIF + abuse.ch)">
    &#128229; Forza Aggiornamento RPZ
  </button>
  <span id="forceRpzStatus" class="muted button-row-status"></span>
  <button id="btnUpdateDash" onclick="confirmUpdateDashboard()" class="btn-action btn-red" title="Scarica dal repository GitHub l'ultima versione della dashboard e riavvia">
    &#11015;&#65039; Aggiorna Dashboard da GitHub
  </button>
  <span id="updateDashStatus" class="muted button-row-status"></span>
  <button id="btnUpdateComponents" onclick="confirmUpdateComponents()" class="btn-action btn-teal" title="Aggiorna tutti i componenti del Bunker: Dashboard (GitHub, con verifica SHA256) poi Unbound Engine + BAT + service.conf (rilanciando UnboundBunkerManager.BAT)">
    &#129513; Aggiorna Componenti
  </button>
  <span id="updateComponentsStatus" class="muted button-row-status"></span>
  <button id="btnToggleDns" onclick="confirmToggleDns()" class="btn-action btn-cyan" style="white-space: normal; line-height: 1.3; flex-basis: 260px;" title="Rileva il DNS della scheda di rete principale e lo commuta: se manuale lo riporta su Automatico (DHCP), se automatico lo imposta su 127.0.0.1 / ::1 (Bunker locale)">
    &#128257; <span id="dnsToggleLabel">DNS: rilevamento...</span>
  </button>
  <span id="dnsToggleStatus" class="muted button-row-status"></span>
  <div id="bunkerGainContainer" style="margin-left: auto; display: flex; align-items: center;"></div>
</div>

<div class="update-toast" id="updateToast">&#9989; Aggiornamento dashboard avvenuto</div>

<div class="restart-overlay" id="restartOverlay">
  <div class="restart-overlay-box">
    <div class="restart-overlay-icon" id="restartOverlayIcon">&#9203;</div>
    <div class="restart-overlay-title" id="restartOverlayTitle">Riavvio in corso...</div>
    <div class="restart-overlay-sub" id="restartOverlaySub"></div>
    <div class="restart-progress-track">
      <div class="restart-progress-fill" id="restartProgressFill" style="width:0%;"></div>
    </div>
    <div class="restart-progress-pct" id="restartProgressPct">0%</div>
  </div>
</div>

<div class="live-indicator" id="liveIndicator">
  <div class="live-badge on" id="liveBadge">
    <span class="status-dot ok" id="liveDot"></span>
    <span id="liveLabel">DASHBOARD ATTIVA - Dati in tempo reale</span>
  </div>
  <div class="live-bar-track" id="liveBarTrack"></div>
</div>

<div class="panel badges-panel">
  <div class="badges" id="badges"></div>
</div>

<div class="live-log-row">
  <div class="live-log-left">
    <div class="panel panel-versioni">
      <h2>&#127760; Connettivit&agrave; IP</h2>
      <div id="statsIpConn" style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; width: 100%;"></div>
    </div>

    <div class="panel panel-versioni">
      <h2>&#128230; Versioni Componenti (Locale vs Cloud)</h2>
      <div id="statsVersioni"></div>
    </div>

    <div class="winupdate-tasks-row">
      <div class="panel panel-versioni winupdate-third">
        <h2>&#128295; Windows Update</h2>
        <div id="statsWinUpdate" style="display: flex; gap: 10px; flex-wrap: wrap; align-items: center;"></div>
      </div>

      <div class="panel panel-versioni periodic-tasks-twothird">
        <h2>&#128197; Task Pianificati</h2>
        <div id="statsPeriodicTasks" class="periodic-tasks-grid"></div>
      </div>
    </div>

    <!-- INCASTRATO A SINISTRA: BUNKER BOOST METRICHE + DETTAGLIO GAIN -->
    <div class="panel" style="margin-bottom: 0;">
      <h2>&#128640; Bunker Boost Score &amp; Guadagno (Gain)</h2>
      <div class="boost-subrow">
        <div class="boost-item">
          <div class="boost-item-header"><span>CACHE REALE (NO RPZ) &middot; 30%</span><span class="boost-item-val" id="valRealCache">--%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barRealCache" style="width:100%"></div></div>
        </div>
        <div class="boost-item">
          <div class="boost-item-header"><span>EFFICIENZA LATENZA &middot; 25%</span><span class="boost-item-val" id="valLatScore">--%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barLatScore" style="width:100%"></div></div>
        </div>
        <div class="boost-item">
          <div class="boost-item-header"><span>UPSTREAM DoT ONLINE &middot; 15%</span><span class="boost-item-val" id="valUpstreamScore">--%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barUpstreamScore" style="width:100%"></div></div>
        </div>
        <div class="boost-item">
          <div class="boost-item-header"><span>INTEGRIT&Agrave; DNSSEC &middot; 15%</span><span class="boost-item-val" id="valDnssecScore">--%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barDnssecScore" style="width:100%"></div></div>
        </div>
        <div class="boost-item">
          <div class="boost-item-header"><span>RISERVA QPS &middot; 5%</span><span class="boost-item-val" id="valQpsScore">100%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barQpsScore" style="width:100%"></div></div>
        </div>
        <div class="boost-item">
          <div class="boost-item-header"><span>SALUTE SISTEMA &middot; 10%</span><span class="boost-item-val" id="valHealthScore">--%</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barHealthScore" style="width:100%"></div></div>
        </div>
        <div class="boost-item" style="grid-column: 1 / -1;">
          <div class="boost-item-header"><span>PRONTEZZA PREFETCH &middot; info</span><span class="boost-item-val" id="valPrefetchScore">--</span></div>
          <div class="g-bar-bg"><div class="g-bar-fill" id="barPrefetchScore" style="width:100%"></div></div>
        </div>
      </div>

      <div style="font-size: 0.85em; font-weight: bold; color: var(--accent); margin: 10px 0 6px 0; border-top: 1px solid var(--border); padding-top: 8px;">&#9889; Dettaglio Punteggio Guadagno (Bunker Gain)</div>
      <div class="boost-subrow" id="gainSubrow" style="margin-bottom: 0;">
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
    </div>
  </div>

  <div class="panel live-log-panel">
    <h2>&#128225; Attivit&agrave; Live - ultimi 1.000 eventi</h2>
    <div id="liveLogSummary" class="live-log-subtitle">In attesa di dati...</div>
    <div id="liveLogFeed" class="live-log-feed"></div>
  </div>
</div>

<div class="bunker-layout">
  <div class="boost-item bunker-rpz-panel">
    <div class="boost-item-header"><span>&#128737; VOLUME SCUDO RPZ</span><span class="boost-item-val" id="valRpzRules">-- regole</span></div>
    <div style="font-size:0.72em; color:var(--text-secondary,#999); margin-top:-2px; margin-bottom:4px;" id="valRpzTaskCheck">Ultimo controllo liste: --</div>
    <div class="g-bar-bg"><div class="g-bar-fill" id="barRpzRules" style="width:100%"></div></div>
    <div id="rpzDettaglio" style="margin-top:8px; font-size:0.75em; line-height:1.5; display:grid; grid-template-columns: 1fr; gap:4px;"></div>
  </div>

  <div class="bunker-subrow bunker-badges-grid">
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
</div>

<div class="grid-three-columns">
  <!-- 1. STATISTICHE (Ristretto a flex: 0.65 per cedere spazio) -->
  <div class="panel" style="margin-bottom: 0; display: flex; flex-direction: column; flex: 0.65; min-width: 250px;">
    
    <!-- Titolo diviso su 2 righe con allineamento ottimizzato -->
    <h2 style="align-items: flex-start;">
      <span style="margin-top: 2px;">&#128202;</span>
      <div style="line-height: 1.3;">
        Statistiche Avanzate Traffico<br>
        <span style="font-size: 0.75em; color: var(--dim); font-weight: normal; letter-spacing: 0; text-transform: none;">(In-Memory Breakdown)</span>
      </div>
    </h2>

    <div style="display: flex; flex-direction: column; gap: 16px;">
      <div>
        <div style="font-size: 0.95em; font-weight: bold; color: var(--accent); margin-bottom: 6px;">Codici Risposta (RCODE)</div>
        <div class="stat-breakdown-grid" id="gridRcode" style="grid-template-columns: repeat(3, 1fr); gap: 6px;"></div>
        <div class="bar-bg" id="barRcode" style="height: 12px;"></div>
        <div class="legend-box" style="font-size: 0.75em; line-height: 1.5; margin-top: 8px;">
          &bull; <b style="color:var(--green-bright)">NOERROR</b>: Lecite/risolte<br>
          &bull; <b style="color:var(--red-bright)">NXDOMAIN</b>: Inesistenti/<b>bloccate</b><br>
          &bull; <b style="color:var(--amber-bright)">SERVFAIL</b>: Errori/DNSSEC
        </div>
      </div>
      <div>
        <div style="font-size: 0.95em; font-weight: bold; color: var(--accent); margin-bottom: 6px;">Tipologia (RR Type)</div>
        <!-- TRUCCO: Griglia 2x2 invece di 4 in riga per recuperare un sacco di spazio orizzontale! -->
        <div class="stat-breakdown-grid" id="gridTypes" style="grid-template-columns: repeat(2, 1fr); gap: 6px;"></div>
        <div class="bar-bg" id="barTypes" style="height: 12px;"></div>
        <div class="legend-box" style="font-size: 0.75em; line-height: 1.5; margin-top: 8px;">
          &bull; <b style="color:var(--accent)">A (v4)</b> / <b style="color:var(--purple)">AAAA (v6)</b><br>
          &bull; <b style="color:#ffffff">HTTPS</b>: ECH, DoH, HTTP/3
        </div>
      </div>
    </div>
  </div>

  <!-- 2. UPSTREAM RADAR -->
  <div class="panel" style="margin-bottom: 0; flex: 1.3; min-width: 320px;">
    <h2>&#128257; Upstream Radar (DoT 853 &amp; Latenza)</h2>
    <div style="overflow: hidden;"> <!-- MODIFICATO QUI -->
      <table id="tabellaRadar">
        <thead>
          <tr>
            <!-- Testi delle intestazioni snelliti -->
            <th>Stato</th>
            <th>Provider DoT</th>
            <th>IP</th>
            <th>Ms</th>
            <th>Porta 853</th>
          </tr>
        </thead>
        <tbody>
          <tr><td colspan="5" class="muted">Verifica in corso...</td></tr>
        </tbody>
      </table>
    </div>
  </div>

  <!-- 3. ROOT RADAR -->
  <div class="panel" style="margin-bottom: 0; flex: 1.3; min-width: 320px;">
    <h2>&#127757; Root Server (Latenza ICMP)</h2>
    <div style="overflow: hidden;"> <!-- MODIFICATO QUI -->
      <table id="tabellaRootRadar">
        <thead>
          <tr>
            <!-- Testi delle intestazioni snelliti -->
            <th>Stato</th>
            <th>Root</th>
            <th>Gestore</th>
            <th>IP (v4/v6)</th>
            <th>Ms</th>
          </tr>
        </thead>
        <tbody>
          <tr><td colspan="5" class="muted">Misurazione in corso...</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>



<div class="panel" id="cerberoRuntimePanel">
  <h2>&#128737;&#65039; Cerbero - Sessione PC (dall'accensione)</h2>
  <div id="cerberoRuntimeStats" class="stat-grid"></div>
</div>

<div class="panel">
  <h2>&#128200; Andamento Storico (dall'ultimo avvio, 1 campione/minuto)</h2>
  <div class="storico-grid">
    <div class="storico-chart-box">
      <div class="storico-chart-title">Query al secondo</div>
      <svg id="chartQps" viewBox="0 0 600 110" preserveAspectRatio="none"></svg>
    </div>
    <div class="storico-chart-box">
      <div class="storico-chart-title">Efficienza cache (%)</div>
      <svg id="chartCache" viewBox="0 0 600 110" preserveAspectRatio="none"></svg>
    </div>
    <div class="storico-chart-box">
      <div class="storico-chart-title">Blocchi RPZ (%)</div>
      <svg id="chartBlock" viewBox="0 0 600 110" preserveAspectRatio="none"></svg>
    </div>
    <div class="storico-chart-box">
      <div class="storico-chart-title">Latenza media upstream DoT (ms)</div>
      <svg id="chartLat" viewBox="0 0 600 110" preserveAspectRatio="none"></svg>
    </div>
  </div>
  <div class="storico-range" id="storicoRange">Raccolta dati storici in corso...</div>
</div>

<div class="panel">
  <h2>&#128200; Distribuzione Oraria dei Blocchi RPZ (per ora del giorno)</h2>
  <div class="sub">Conteggio blocchi RPZ per ogni ora effettivamente coperta dalle ultime 24h (finestra scorrevole).</div>
  <svg id="chartBlocchiOrari" viewBox="0 0 600 150" preserveAspectRatio="none" style="width:100%; height:150px;"></svg>
  <div class="storico-range" id="blocchiOrariInfo">In attesa di dati...</div>
</div>

<div class="panel">
  <h2>&#128202; Dall'ultimo report Telegram (Dettaglio Block List)</h2>
  <div class="stats-grid" id="statsUltimoReport"></div>
  <div id="listeRpz" style="padding-right: 4px;"></div>
</div>

<div class="panel">
  <h2>&#9888;&#65039; Anomalie di Traffico Rilevate</h2>
  <div class="sub">Domini che in un minuto hanno superato sia una soglia minima assoluta sia 4&times; la loro media storica di sessione &mdash; rilevamento statistico semplice, non un antivirus: verifica sempre a occhio prima di allarmarti.</div>
  <div id="anomalieTraffico"></div>
</div>

<div class="panel">
  <h2>&#128260; Storico Riavvii Servizio Unbound</h2>
  <div class="sub">Rilevato dal contatore interno di uptime di Unbound: sappiamo che c'&egrave; stato un riavvio, non la causa (crash, recovery automatico "sc failure", riavvio manuale...).</div>
  <div id="restartLog"></div>
</div>

<div class="panel">
  <h2>&#128260; Log Fallback DNS (Cambio Resolver Upstream)</h2>
  <div class="sub">Interrogazioni per cui Unbound ha dovuto passare a un resolver upstream successivo (il precedente non ha risposto in tempo o ha restituito errore).</div>
  <div id="dnsFallbackLog"></div>
</div>

<div class="panel">
  <h2>&#9854; Totale sessione (dall'ultimo avvio)</h2>
  <div class="stats-grid" id="statsSessione"></div>
</div>


<div class="panel">
  <h2>&#9877; Stato di salute del sistema (Log Fasi di Avvio)</h2>
  <table id="tabellaSalute"><thead><tr><th class="fase-btn-cell">Esegui</th><th>Fase</th><th>Azione</th><th>Esito</th></tr></thead><tbody></tbody></table>
  <div class="muted" style="font-size:0.78em; margin-top:8px;">&#9654; esegue solo quella fase, con la stessa logica dell'avvio del .BAT (una alla volta). Le liste RPZ aggiornate vengono caricate da Unbound al successivo riavvio del servizio.</div>
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
let lastDataTs = 0;
let liveState = true;
const baseTitle = document.title;
let audioCtx = null;

function playOfflineBeep() {
  try {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === 'suspended') audioCtx.resume();
    const startAt = audioCtx.currentTime;
    const beepTimes = [startAt, startAt + 0.22];
    beepTimes.forEach(t => {
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = 'square';
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.25, t + 0.015);
      gain.gain.setValueAtTime(0.25, t + 0.12);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.17);
      osc.connect(gain);
      gain.connect(audioCtx.destination);
      osc.start(t);
      osc.stop(t + 0.2);
    });
  } catch (e) {}
}

function buildLiveDotGrid() {
  const track = document.getElementById('liveBarTrack');
  if (!track) return;
  if (track.childElementCount === 0) {
    track.innerHTML = '<div class="live-scanner"></div>';
  }
}
window.addEventListener('resize', () => { buildLiveDotGrid(); });
buildLiveDotGrid();

function setLiveStatus(isLive) {
  const dot = document.getElementById('liveDot');
  const badge = document.getElementById('liveBadge');
  const label = document.getElementById('liveLabel');
  const track = document.getElementById('liveBarTrack');
  if (!dot || !badge || !label || !track) return;
  if (isLive) {
    dot.classList.remove('bad'); dot.classList.add('ok');
    badge.classList.remove('off'); badge.classList.add('on');
    label.textContent = 'DASHBOARD ATTIVA - Dati in tempo reale';
    track.classList.remove('offline');
    document.title = '\u{1F7E2} ' + baseTitle;
  } else {
    dot.classList.remove('ok'); dot.classList.add('bad');
    badge.classList.remove('on'); badge.classList.add('off');
    label.textContent = 'DASHBOARD OFFLINE - Nessun dato da Unbound';
    track.classList.add('offline');
    document.title = '\u{1F534} ' + baseTitle;
    if (liveState) playOfflineBeep();
  }
  liveState = isLive;
}

function fmt(n) {
  if (n === undefined || n === null || n === '') return "-";
  const num = Number(n);
  if (isNaN(num)) return "-";
  const negativo = num < 0;
  const parti = Math.round(Math.abs(num)).toString().split('.');
  parti[0] = parti[0].replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return (negativo ? '-' : '') + parti.join(',');
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

// Interpola dal verde brillante (--green-bright, 1o posto) all'arancione
// (--orange-bright, ultimo posto) in base alla posizione in classifica.
// Usato per l'Upstream Radar: sostituisce il badge testuale "TOP N" (che
// andava a capo con nomi resolver lunghi) con un'evidenziazione a colpo
// d'occhio su tutte le righe, aggiornata ad ogni ciclo di test.
function rankColor(index, total) {
  const from = [61, 220, 132];   // --green-bright #3ddc84
  const to   = [255, 140, 26];   // --orange-bright #ff8c1a
  const ratio = total > 1 ? index / (total - 1) : 0;
  const rgb = from.map((c, i) => Math.round(c + (to[i] - c) * ratio));
  return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
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

// === GRAFICI STORICI (mini line-chart SVG, senza dipendenze esterne) ===
function renderSparkline(svgId, points, colorVar, suffix) {
  const svg = document.getElementById(svgId);
  if (!svg) return;
  if (!points || points.length < 2) {
    svg.innerHTML = '<text x="300" y="58" text-anchor="middle" fill="var(--dim)" font-size="13">In attesa di dati storici&hellip;</text>';
    return;
  }
  const w = 600, h = 110, padX = 6, padY = 16;
  const vals = points.map(p => p.v);
  let minV = Math.min(...vals), maxV = Math.max(...vals);
  if (minV === maxV) { minV -= 1; maxV += 1; }
  const range = maxV - minV;
  const stepX = (w - padX * 2) / (points.length - 1);
  const coords = points.map((p, i) => {
    const x = padX + i * stepX;
    const y = h - padY - ((p.v - minV) / range) * (h - padY * 2);
    return [x.toFixed(1), y.toFixed(1)];
  });
  const polyStr = coords.map(c => c.join(',')).join(' ');
  const last = coords[coords.length - 1];
  const areaStr = `${padX.toFixed(1)},${(h - padY).toFixed(1)} ${polyStr} ${last[0]},${(h - padY).toFixed(1)}`;
  svg.innerHTML = `
    <polygon points="${areaStr}" fill="${colorVar}" opacity="0.12"></polygon>
    <polyline points="${polyStr}" fill="none" stroke="${colorVar}" stroke-width="2"></polyline>
    <circle cx="${last[0]}" cy="${last[1]}" r="3.2" fill="${colorVar}"></circle>
    <text x="${padX}" y="12" fill="var(--dim)" font-size="11">${maxV}${suffix}</text>
    <text x="${padX}" y="${h - 4}" fill="var(--dim)" font-size="11">${minV}${suffix}</text>
  `;
}

function renderStorico(d) {
  const storico = Array.isArray(d.storico) ? d.storico : (d.storico ? [d.storico] : []);
  renderSparkline('chartQps',   storico.map(p => ({ v: p.qps })),   'var(--accent)',      ' q/s');
  renderSparkline('chartCache', storico.map(p => ({ v: p.cache })), 'var(--green-bright)', '%');
  renderSparkline('chartBlock', storico.map(p => ({ v: p.block })), 'var(--red-bright)',   '%');
  renderSparkline('chartLat',   storico.map(p => ({ v: p.lat })),   'var(--purple)',       ' ms');

  const elRange = document.getElementById('storicoRange');
  if (!elRange) return;
  if (storico.length < 2) {
    elRange.textContent = 'Raccolta dati storici in corso... (1 punto ogni minuto)';
  } else {
    elRange.textContent = `${storico[0].t} \u2192 ${storico[storico.length - 1].t} &middot; ${storico.length} campioni, 1/minuto`.replace('&middot;', '·');
  }
}

// === ANOMALIE DI TRAFFICO ===
function renderAnomalie(d) {
  const cont = document.getElementById('anomalieTraffico');
  if (!cont) return;
  let allarmi = Array.isArray(d.anomalie_traffico) ? d.anomalie_traffico : (d.anomalie_traffico ? [d.anomalie_traffico] : []);
  if (!allarmi.length) {
    cont.innerHTML = '<div class="muted">Nessuna anomalia rilevata dall\'ultimo avvio.</div>';
    return;
  }
  allarmi = allarmi.slice().reverse();
  cont.innerHTML = allarmi.map(a => `
    <div class="rpz-fresh-row">
      <span class="esito-warn">${a.orario || '--'} &middot; ${a.dominio || '-'}</span>
      <span>${fmt(a.conta)} query/min <span class="muted">(media storica &asymp; ${a.baseline})</span></span>
    </div>
  `).join('');
}

// === STORICO RIAVVII UNBOUND ===
function fmtDurata(sec) {
  sec = Math.max(0, Math.round(sec || 0));
  const g = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const parti = [];
  if (g > 0) parti.push(g + 'g');
  if (h > 0) parti.push(h + 'h');
  if (g === 0 && m > 0) parti.push(m + 'min');
  return parti.length ? parti.join(' ') : '<1min';
}

function renderRestartLog(d) {
  const cont = document.getElementById('restartLog');
  if (!cont) return;
  let log = Array.isArray(d.unbound_restart_log) ? d.unbound_restart_log : (d.unbound_restart_log ? [d.unbound_restart_log] : []);
  if (!log.length) {
    cont.innerHTML = '<div class="muted">Nessun riavvio rilevato dall\'ultimo avvio della dashboard.</div>';
    return;
  }
  log = log.slice().reverse();
  cont.innerHTML = log.map(r => `
    <div class="rpz-fresh-row">
      <span class="esito-warn">${r.orario || '--'}</span>
      <span>era in esecuzione da <b>${fmtDurata(r.uptime_precedente_sec)}</b> prima del riavvio</span>
    </div>
  `).join('');
}

// === DISTRIBUZIONE ORARIA DEI BLOCCHI RPZ (BAR CHART) ===
function renderBlocchiOrari(d) {
  const svg = document.getElementById('chartBlocchiOrari');
  const info = document.getElementById('blocchiOrariInfo');
  if (!svg) return;
  const bo = d.blocchi_orari;
  const ore = (bo && Array.isArray(bo.ore)) ? bo.ore : null;
  const etichette = (bo && Array.isArray(bo.etichette)) ? bo.etichette : null;
  if (!ore || !ore.length || !etichette) {
    svg.innerHTML = '<text x="300" y="75" text-anchor="middle" fill="var(--dim)" font-size="13">Nessun blocco registrato nel log corrente&hellip;</text>';
    if (info) info.textContent = 'In attesa di dati...';
    return;
  }
  const n = ore.length;
  const w = 600, h = 150, padX = 6, padTop = 18, padBottom = 20, gap = 2;
  const areaH = h - padTop - padBottom;
  const maxV = Math.max(...ore, 1);
  const slot = (w - padX * 2) / n;
  const barW = slot - gap;
  let bars = '';
  for (let i = 0; i < n; i++) {
    const v = ore[i];
    const barH = (v / maxV) * areaH;
    const x = padX + i * slot;
    const y = h - padBottom - barH;
    const colore = (bo.ora_picco === i) ? 'var(--red-bright)' : 'var(--accent)';
    const yBar = h - padBottom - Math.max(barH, 1);
    bars += `<rect x="${x.toFixed(1)}" y="${yBar.toFixed(1)}" width="${barW.toFixed(1)}" height="${Math.max(barH,1).toFixed(1)}" fill="${colore}" opacity="0.85"></rect>`;

    // Valore sopra ogni barra, sempre mostrato (anche 0), tenuto entro l'area utile.
    const yVal = Math.max(y - 3, padTop + 8);
    bars += `<text x="${(x + barW / 2).toFixed(1)}" y="${yVal.toFixed(1)}" text-anchor="middle" fill="var(--text)" font-size="8">${fmt(v)}</text>`;

    // Etichetta oraria per OGNI barra (non piu' una ogni 3). Niente indicazione
    // "oggi/ieri": con tutte le 24 ore in ordine cronologico la progressione
    // sinistra->destra e' gia' chiara da sola.
    const etichettaOra = String(etichette[i]).padStart(2, '0');
    bars += `<text x="${(x + barW / 2).toFixed(1)}" y="${h - 5}" text-anchor="middle" fill="var(--dim)" font-size="8">${etichettaOra}</text>`;
  }
  svg.innerHTML = bars;
  if (info) {
    if (bo.ora_picco >= 0) {
      const etichettaPicco = String(etichette[bo.ora_picco]).padStart(2, '0') + ':00';
      info.textContent = `Ora di picco: ${etichettaPicco} · ${fmt(bo.picco)} blocchi`;
    } else {
      info.textContent = 'In attesa di dati...';
    }
  }
}

// === LOG FALLBACK DNS ===
function renderDnsFallbackLog(d) {
  const cont = document.getElementById('dnsFallbackLog');
  if (!cont) return;
  const fb = d.dns_fallback_log;
  let eventi = fb && Array.isArray(fb.eventi) ? fb.eventi : (fb && fb.eventi ? [fb.eventi] : []);
  if (!eventi.length) {
    cont.innerHTML = '<div class="muted">Nessun fallback su resolver upstream rilevato nel log corrente.</div>';
    return;
  }
  cont.innerHTML = eventi.map(e => `
    <div class="rpz-fresh-row">
      <span class="esito-warn">${e.orario || '--'} &middot; ${e.dominio || '-'}</span>
      <span>${(e.n_tentativi || 0)} tentativi: ${(e.resolver_tentati || []).join(' &rarr; ')} <span class="muted">(esito: ${e.rcode_finale || '-'})</span></span>
    </div>
  `).join('');
}

// === BANNER DI STATO (prima riga della dashboard: ESECUZIONE REGOLARE / ATTENZIONE) ===
// Valuta le anomalie note in ordine di gravita' e mostra un solo messaggio,
// sintetico e operativo, su cosa va fatto. Nessuna anomalia rilevata => banner verde.
function buildStatusBannerFinding(d) {
  // 1) Fasi di avvio in ERRORE (massima priorita': il Bunker potrebbe non essere pienamente operativo)
  const fasi = (d.salute_sistema && d.salute_sistema.dettaglio && d.salute_sistema.dettaglio.fasi) || [];
  const faseErr = fasi.find(f => /ERR|ERRORE|FALLITO/i.test(f.esito || ''));
  if (faseErr) {
    return { level: 'error', text: `Fase "${faseErr.fase}" in errore (${faseErr.esito}) - eseguila manualmente dal pannello "Stato di salute del sistema"` };
  }

  // 2) Riavvio di Windows richiesto
  if (d.windows_update && d.windows_update.riavvio_richiesto) {
    return { level: 'warn', text: 'Riavvio di Windows richiesto per completare gli aggiornamenti - pianificare un riavvio del PC appena possibile' };
  }

  // 3) Connettivita' IPv4/IPv6 incompleta (LAN o WAN)
  const ipc = d.connettivita_ip || {};
  const ipProblemi = [];
  if (ipc.ipv4_lan_ok === false) ipProblemi.push('IPv4 LAN');
  if (ipc.ipv6_lan_ok === false) ipProblemi.push('IPv6 LAN');
  if (ipc.ipv4_wan_ok === false) ipProblemi.push('IPv4 WAN');
  if (ipc.ipv6_wan_ok === false) ipProblemi.push('IPv6 WAN');
  if (ipProblemi.length > 0) {
    return { level: 'warn', text: `Connettivita' incompleta: ${ipProblemi.join(', ')} non raggiungibile - verificare la rete` };
  }

  // 4) Versioni componenti non allineate al cloud (locale vs cloud, valori entrambi noti)
  const v = d.versioni || {};
  const coppie = [
    ['Unbound Engine', v.unbound_local, v.unbound_cloud],
    ['service.conf', v.conf_local, v.conf_cloud],
    ['Manager .BAT', v.bat_local, v.bat_cloud],
    ['Dashboard', v.dash_local, v.dash_cloud]
  ];
  const nonAllineati = coppie
    .filter(([, loc, cld]) => loc && cld && loc !== 'N/D' && cld !== 'N/D' && loc !== cld)
    .map(([nome]) => nome);
  if (nonAllineati.length > 0) {
    return { level: 'warn', text: `Componenti non allineati alla versione cloud: ${nonAllineati.join(', ')} - usare il pulsante "Aggiorna Componenti"` };
  }

  // 5) Fasi di avvio con esito WARN/ALLARME
  const faseWarn = fasi.find(f => /WARN|ALLARME/i.test(f.esito || ''));
  if (faseWarn) {
    return { level: 'warn', text: `Fase "${faseWarn.fase}" in allarme (${faseWarn.esito}) - verificare dal pannello "Stato di salute del sistema"` };
  }

  // 6) Fallback generico: salute complessiva del sistema non al 100%
  const score = (d.salute_sistema && typeof d.salute_sistema.score === 'number') ? d.salute_sistema.score : 100;
  if (score < 100) {
    return { level: 'warn', text: `Salute generale del Bunker al ${score}% (non ottimale) - verificare il pannello "Stato di salute del sistema"` };
  }

  return null; // tutto regolare
}

function renderStatusBanner(d) {
  const el     = document.getElementById('statusBanner');
  const icon   = document.getElementById('statusBannerIcon');
  const txt    = document.getElementById('statusBannerText');
  if (!el || !icon || !txt) return;

  const finding = buildStatusBannerFinding(d);

  el.classList.remove('sb-ok', 'sb-warn', 'sb-error');

  if (!finding) {
    el.classList.add('sb-ok');
    icon.innerHTML = '&#9989;';
    txt.textContent = 'ESECUZIONE REGOLARE';
    return;
  }

  el.classList.add(finding.level === 'error' ? 'sb-error' : 'sb-warn');
  icon.innerHTML = finding.level === 'error' ? '&#10060;' : '&#9888;';
  txt.textContent = `ATTENZIONE: ${finding.text}`;
}

// === STATO WINDOWS UPDATE ===
function renderWinUpdate(d) {
  const cont = document.getElementById('statsWinUpdate');
  if (!cont) return;
  const w = d.windows_update;
  if (!w) { cont.innerHTML = '<div class="muted">Dati non disponibili.</div>'; return; }
  const giorniTxt = (w.giorni_fa >= 0) ? `${w.giorni_fa} giorni fa` : '-';
  const rebootBadge = w.riavvio_richiesto
    ? '<span class="esito-warn">&#9888;&#65039; Riavvio in attesa</span>'
    : '<span class="esito-ok">&#10003; Nessun riavvio in attesa</span>';
  cont.innerHTML = `
    <div class="stat"><div class="val" style="font-size:1.1em">${w.ultimo_agg_installato}</div><div class="lbl">Ultimo aggiornamento installato (${giorniTxt})</div></div>
    <div class="stat"><div class="val" style="font-size:1.1em">${w.ultima_ricerca}</div><div class="lbl">Ultima ricerca aggiornamenti</div></div>
    <div class="stat"><div class="val" style="font-size:0.85em">${rebootBadge}</div><div class="lbl">Stato riavvio</div></div>
  `;
  if (w.errore) {
    cont.innerHTML += `<div class="muted" style="width:100%; margin-top:6px;">${w.errore}</div>`;
  }
}

// === ULTIMA ESECUZIONE DEI TASK PIANIFICATI (RPZ, statistiche, NTP, ecc.) ===
function renderPeriodicTasks(d) {
  const cont = document.getElementById('statsPeriodicTasks');
  if (!cont) return;
  let tasks = (d.periodic_tasks && d.periodic_tasks.tasks) || [];
  if (!Array.isArray(tasks)) { tasks = [tasks]; }
  if (!tasks.length) {
    cont.innerHTML = '<div class="muted">Nessun task pianificato rilevato.</div>';
    return;
  }
  const classeEsito = { ok: 'esito-ok', attenzione: 'esito-warn', sconosciuto: 'esito-warn' };
  cont.innerHTML = tasks.map(t => {
    const cls = classeEsito[t.esito] || 'esito-warn';
    let etaTxt = '--';
    if (typeof t.min_fa === 'number' && t.min_fa >= 0) {
      const oreInt = Math.floor(t.min_fa / 60);
      const minRes = t.min_fa % 60;
      etaTxt = oreInt > 0 ? `${oreInt}h ${minRes}m fa` : `${minRes}m fa`;
    }
    const inEsecuzione = !!t.in_esecuzione;
    const titleAttr = inEsecuzione
      ? 'Task in esecuzione adesso'
      : `Prossima esecuzione prevista: ${t.prossimo_run || 'N/D'} | Ultimo risultato: ${t.last_result || 'N/D'}`;
    const liveBadge = inEsecuzione
      ? '<span class="ptc-live-badge"><span class="ptc-live-dot"></span>In esecuzione adesso</span>'
      : '';
    return `<div class="periodic-task-chip${inEsecuzione ? ' ptc-live' : ''}" title="${titleAttr}">
      <span class="ptc-nome ${cls}">${t.nome || '-'}</span>
      <span class="ptc-info">
        ${liveBadge}
        <span class="ptc-eta ${cls}">${etaTxt}</span>
        <span class="ptc-sep">&middot;</span>
        <span class="ptc-run">${t.ultimo_run || 'N/D'}</span>
      </span>
    </div>`;
  }).join('');
}

let liveLogSignature = '';
let liveLogChiaviRese = [];

function renderLiveLogFeed(d) {
  const cont = document.getElementById('liveLogFeed');
  if (!cont) return;
  let feed = d.live_rcode_feed || [];
  if (!Array.isArray(feed)) { feed = [feed]; }

  if (feed.length === 0) {
    cont.innerHTML = '<div class="muted">In attesa di eventi...</div>';
    return;
  }

  // Prende gli ultimi 1000 elementi nell'ordine nativo (dal meno recente al piu recente)
  // Stesso cap del server (Select-Object -Last 1000 in Get-LiveRcodeFeed).
  const voci = feed.slice(-1000);

  // Numero progressivo calcolato a ritroso dal totalizzatore corrente (s.totale),
  // cosi' l'ultima riga in fondo corrisponde esattamente al totale mostrato sopra
  // e le righe precedenti scalano di 1 in 1 risalendo la lista.
  const totaleCorrente = (d.live_feed_summary && d.live_feed_summary.totale) || 0;

  const righe = voci.map((f, idx) => {
    const code = (f.rcode || '').toUpperCase();
    let colore = 'var(--dim)';
    if (code === 'NOERROR') colore = 'var(--green-bright)';
    else if (code === 'NXDOMAIN') colore = 'var(--red-bright)';
    else if (code === 'SERVFAIL') colore = 'var(--amber-bright)';
    
    const dominio = (f.dominio || '-').length > 120 ? (f.dominio.slice(0, 120) + '\u2026') : (f.dominio || '-');
    const numero = totaleCorrente - (voci.length - 1 - idx);
    const numeroTxt = numero > 0 ? fmt(numero) + '.' : '-';
    
    return `<div class="live-log-line">` +
      `<span class="live-log-num">${numeroTxt}</span>` +
      `<span class="muted">${f.orario || '--:--:--'}</span> ` +
      `<span style="color:${colore};">${dominio}</span>` +
      `</div>`;
  }).join('');

  cont.innerHTML = `<div class="live-log-track">${righe}</div>`;
  // Mantiene lo scorrimento automatico focalizzato sul fondo (sull'ultimo evento registrato)
  cont.scrollTop = cont.scrollHeight;
}

function parseCerberoDate(value) {
  if (!value) return null;
  let v = String(value).trim();
  let d = new Date(v);
  if (isNaN(d.getTime())) {
    d = new Date(v.replace(' ', 'T'));
  }
  return isNaN(d.getTime()) ? null : d;
}

function renderCerberoRuntime(d) {
  const el = document.getElementById('cerberoRuntimeStats');
  if (!el) return;
  const s = d.live_feed_summary;
  if (!s || s.runtime_totale === undefined) {
    el.innerHTML = '<div class="muted">Sessione runtime non disponibile</div>';
    return;
  }
  const dataAvvio = parseCerberoDate(s.runtime_avvio || s.avvio || s.runtimeAvvio);
  const avvio = dataAvvio ? dataAvvio.toLocaleString('it-IT') : 'Sessione attiva';
  const uptimeSec = dataAvvio ? Math.max(0, Math.floor((Date.now() - dataAvvio.getTime()) / 1000)) : 0;
  const uptime = uptimeSec >= 86400 ? Math.floor(uptimeSec/86400) + 'g ' + Math.floor((uptimeSec%86400)/3600) + 'h' : Math.floor(uptimeSec/3600) + 'h ' + Math.floor((uptimeSec%3600)/60) + 'm';
  const pct = s.runtime_totale > 0 ? ((s.runtime_bloccate / s.runtime_totale) * 100).toFixed(1) : '0.0';
  el.innerHTML = `
    <div class="stat"><div class="val">${fmt(s.runtime_totale)}</div><div class="lbl">Query sessione</div></div>
    <div class="stat"><div class="val">${fmt(s.runtime_bloccate)}</div><div class="lbl">Bloccate</div></div>
    <div class="stat"><div class="val">${fmt(s.runtime_consentite)}</div><div class="lbl">Consentite</div></div>
    <div class="stat"><div class="val">${pct}%</div><div class="lbl">Block rate</div></div>
    <div class="stat"><div class="val">${uptime}</div><div class="lbl">Uptime sessione</div></div>
    <div class="stat"><div class="val muted" style="font-size:0.9em">${avvio}</div><div class="lbl">Avvio sessione</div></div>`;
}

function renderLiveLogSummary(d) {
  const el = document.getElementById('liveLogSummary');
  if (!el) return;
  const s = d.live_feed_summary;
  if (!s || s.runtime_totale === undefined || s.runtime_totale === 0) {
    el.innerHTML = 'In attesa di dati...';
    return;
  }

  // FIX4: il riepilogo usa la sessione Cerbero dall'accensione PC.
  // La lista eventi resta limitata agli ultimi 1000 eventi, ma i numeri sono persistenti.
  const totale = s.runtime_totale;
  const consentite = s.runtime_consentite;
  const bloccate = s.runtime_bloccate;
  const pctCons = ((consentite / totale) * 100).toFixed(1).replace('.', ',');
  const pctBloc = ((bloccate / totale) * 100).toFixed(1).replace('.', ',');
  const dataAvvioLive = parseCerberoDate(s.runtime_avvio || s.avvio || s.runtimeAvvio);
  const rangeTxt = dataAvvioLive ? ` &middot; (dalle ${dataAvvioLive.toLocaleTimeString('it-IT')})` : '';

  el.innerHTML = `Totali: <b>${fmt(totale)}</b> - ` +
    `<span style="color:var(--green-bright);">${fmt(consentite)} consentite (${pctCons}%)</span> &middot; ` +
    `<span style="color:var(--red-bright);">${fmt(bloccate)} bloccate (${pctBloc}%)</span>` +
    `<span class="muted">${rangeTxt}</span>`;
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

function showRestartOverlay(icon, title, sub) {
  document.getElementById('restartOverlayIcon').innerHTML = icon;
  document.getElementById('restartOverlayTitle').textContent = title;
  document.getElementById('restartOverlaySub').textContent = sub;
  updateRestartProgress(0);
  document.getElementById('restartOverlay').classList.add('active');
}

function updateRestartProgress(pct) {
  const p = Math.min(100, Math.max(0, pct));
  const fill = document.getElementById('restartProgressFill');
  const label = document.getElementById('restartProgressPct');
  if (fill) fill.style.width = p + '%';
  if (label) label.textContent = Math.round(p) + '%';
}

function hideRestartOverlay() {
  updateRestartProgress(100);
  setTimeout(() => {
    const ov = document.getElementById('restartOverlay');
    if (ov) ov.classList.remove('active');
  }, 500);
}

function showUpdateToast() {
  const t = document.getElementById('updateToast');
  if (!t) return;
  t.classList.add('active');
  setTimeout(() => t.classList.remove('active'), 4000);
}

async function confirmRestart() {
  if (!confirm("Sei sicuro di voler riavviare la Dashboard?\n\nVerrà eseguita la procedura automatica di rilascio e verifica della porta " + location.port + ".")) return;

  const btn = document.getElementById('btnRestart');
  if (btn) {
    btn.disabled = true;
    btn.innerHTML = '&#9203; Riavvio in corso...';
  }

  try {
    await fetch('/api/restart', { method: 'POST', cache: 'no-store' });
  } catch(e) {}

  setLiveStatus(false);
  document.getElementById('subheader').textContent = 'Riavvio in corso... Rilascio e controllo porta ' + location.port + ' in esecuzione...';
  showRestartOverlay('&#128472;&#65039;', 'Riavvio della Dashboard in corso...', 'Rilascio e verifica della porta ' + location.port + ' in esecuzione...');

  let attempts = 0;
  const SOFT_LIMIT = 35;
  const HARD_LIMIT = 90;
  const checkInterval = setInterval(async () => {
    attempts++;
    updateRestartProgress((attempts / HARD_LIMIT) * 95);
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (res.ok) {
        clearInterval(checkInterval);
        if (btn) {
          btn.disabled = false;
          btn.innerHTML = '&#128260; Riavvia Dashboard';
        }
        hideRestartOverlay();
        refresh(true);
      }
    } catch(e) {}

    if (attempts === SOFT_LIMIT) {
      document.getElementById('restartOverlaySub').textContent =
        'Sta impiegando più del previsto (possibile scansione antivirus del processo appena avviato)... continuo ad attendere.';
    }

    if (attempts > HARD_LIMIT) {
      clearInterval(checkInterval);
      alert("Il riavvio non è ancora completato dopo " + HARD_LIMIT + " secondi. Ricarica manualmente la pagina tra qualche secondo, oppure controlla che il processo sia effettivamente ripartito.");
      if (btn) {
        btn.disabled = false;
        btn.innerHTML = '&#128260; Riavvia Dashboard';
      }
      document.getElementById('restartOverlay').classList.remove('active');
    }
  }, 1000);
}

async function confirmRestartUnbound() {
  if (!confirm("Sei sicuro di voler riavviare il servizio Unbound?\n\nLa risoluzione DNS potrebbe interrompersi per qualche secondo durante il riavvio.")) return;

  const btn = document.getElementById('btnRestartUnbound');
  if (btn) {
    btn.disabled = true;
    btn.innerHTML = '&#9203; Riavvio in corso...';
  }

  try {
    await fetch('/api/restart-unbound', { method: 'POST', cache: 'no-store' });
  } catch(e) {}

  document.getElementById('subheader').textContent = 'Riavvio del servizio Unbound in corso...';
  showRestartOverlay('&#128737;&#65039;', 'Riavvio del servizio Unbound in corso...', 'La risoluzione DNS potrebbe interrompersi per qualche secondo...');

  let attempts = 0;
  let seenDown = false;
  const SOFT_LIMIT = 35;
  const HARD_LIMIT = 150;
  const checkInterval = setInterval(async () => {
    attempts++;
    updateRestartProgress((attempts / HARD_LIMIT) * 95);
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        if (!data.engine_attivo) {
          seenDown = true;
        }
        if (data.engine_attivo && (seenDown || attempts > 3)) {
          clearInterval(checkInterval);
          if (btn) {
            btn.disabled = false;
            btn.innerHTML = '&#128737;&#65039; Riavvia Unbound';
          }
          hideRestartOverlay();
          refresh(true);
        }
      }
    } catch(e) {}

    if (attempts === SOFT_LIMIT) {
      document.getElementById('restartOverlaySub').textContent =
        'Sta impiegando più del previsto (probabile ricaricamento delle blocklist RPZ)... continuo ad attendere.';
    }

    if (attempts > HARD_LIMIT) {
      clearInterval(checkInterval);
      alert("Il riavvio di Unbound non risulta ancora completato dopo " + HARD_LIMIT + " secondi. Controlla lo stato del servizio manualmente (potrebbe essere ancora al lavoro sul caricamento delle blocklist).");
      if (btn) {
        btn.disabled = false;
        btn.innerHTML = '&#128737;&#65039; Riavvia Unbound';
      }
      document.getElementById('restartOverlay').classList.remove('active');
    }
  }, 1000);
}

async function confirmRestartManager() {
  if (!confirm("Riavviare UnboundBunkerManager.BAT?\n\nVerrà rilanciato lo scheduled task \"Unbound_Bunker_Boot\": il manager rieseguirà l'intera procedura di avvio (controlli, auto-tuning, eventuale self-update, ripianificazione task). Non c'è un segnale affidabile di completamento: verifica lo stato manualmente dopo qualche minuto.")) return;

  const btn = document.getElementById('btnRestartManager');
  const status = document.getElementById('restartManagerStatus');
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Avvio in corso...'; }
  if (status) status.textContent = '';

  try {
    const res = await fetch('/api/restart-manager', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.status === 'started') {
      if (status) status.textContent = 'Task avviato alle ' + new Date().toLocaleTimeString('it-IT') + '. Verifica manualmente l\'esito tra qualche minuto.';
    } else {
      if (status) status.textContent = 'Errore nell\'avvio del task: ' + (data.error || 'sconosciuto');
    }
  } catch (e) {
    if (status) status.textContent = 'Errore di rete durante la richiesta.';
  }

  if (btn) {
    btn.disabled = false;
    btn.innerHTML = '&#128295; Riavvia Manager .BAT';
  }
  setTimeout(() => { if (status) status.textContent = ''; }, 30000);
}

// === STATO DI SALUTE: pulsante per eseguire la singola fase ===
// Conferma solo per le fasi che interrompono/riavviano la protezione DNS.
const PHASE_CONFIRM = {
  F8:  "Fase F8: ferma il servizio Unbound e imposta temporaneamente i DNS pubblici 1.1.1.1 / 9.9.9.9.\n\nSubito dopo parte in automatico la fase F13 (controllo di service.conf, DNS su 127.0.0.1, avvio di Unbound): in pratica e un riavvio del servizio.\n\nProcedere?",
  F13: "Fase F13: controlla la sintassi di service.conf, ripristina i DNS su 127.0.0.1 e avvia il servizio Unbound.\n\nProcedere?"
};
const phaseLocal = {};        // codice -> { t, ts0, seen }: fasi lanciate da questa pagina, in attesa dell'esito
let lastHealthTs = '';
let lastStatusData = null;

function renderSaluteFasi(d) {
  const tbody = document.querySelector('#tabellaSalute tbody');
  if (!tbody) return;
  lastStatusData = d;
  const det = (d.salute_sistema && d.salute_sistema.dettaglio) || {};
  let fasi = det.fasi || [];
  if (!Array.isArray(fasi)) { fasi = [fasi]; }
  const ts = det.timestamp || '';
  lastHealthTs = ts;

  // Stato locale "in attesa": si chiude quando il server ha visto la fase partire e finire,
  // oppure quando lo snapshot e' stato riscritto (fasi velocissime), oppure dopo 20s senza
  // alcun segnale (avvio fallito in silenzio).
  const now = Date.now();
  Object.keys(phaseLocal).forEach(code => {
    const p = phaseLocal[code];
    const f = fasi.find(x => x.fase === code);
    if (f && f.in_corso) { p.seen = true; }
    else if (p.seen) { delete phaseLocal[code]; }
    else if (ts && ts !== p.ts0) { delete phaseLocal[code]; }
    else if (now - p.t > 20000) { delete phaseLocal[code]; }
  });

  const anyRunning = fasi.some(f => f.in_corso) || Object.keys(phaseLocal).length > 0;

  // Il corpo tabella viene ricostruito solo se qualcosa e' cambiato: cosi' un click sul
  // pulsante non va perso perche' il nodo e' stato sostituito dal polling ogni 2 secondi.
  const sig = JSON.stringify(fasi.map(f => [f.fase, f.azione, f.esito, !!f.in_corso, !!phaseLocal[f.fase]])) + '|' + anyRunning;
  if (tbody.dataset.sig === sig) return;
  tbody.dataset.sig = sig;

  tbody.innerHTML = '';
  if (fasi.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">Nessun dato di salute ancora disponibile</td></tr>';
    return;
  }
  fasi.forEach(f => {
    const code = String(f.fase || '').replace(/[^A-Za-z0-9]/g, '');
    const running = !!(f.in_corso || phaseLocal[code]);
    const isWarn = /WARN|ERR|ERRORE|ALLARME|FALLITO/.test(f.esito || '');
    const esitoHtml = running ? '<span class="esito-running">......esecuzione in corso......attendere......</span>' : (f.esito || '');
    const tdClass = running ? '' : (isWarn ? 'esito-warn' : 'esito-ok');
    const btn = code
      ? '<button class="btn-fase" ' + (anyRunning ? 'disabled ' : '') + 'onclick="runPhase(\'' + code + '\')" title="Esegui solo la fase ' + code + '">&#9654;</button>'
      : '';
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="fase-btn-cell">${btn}</td><td>${code || '-'}</td><td>${f.azione || ''}</td><td class="${tdClass}">${esitoHtml}</td>`;
    tbody.appendChild(tr);
  });
}

async function runPhase(code) {
  code = String(code || '').replace(/[^A-Za-z0-9]/g, '');
  if (!code) return;
  if (PHASE_CONFIRM[code] && !confirm(PHASE_CONFIRM[code])) return;
  const ts0 = lastHealthTs;
  try {
    const res = await fetch('/api/run-phase?fase=' + encodeURIComponent(code), {
      method: 'POST', cache: 'no-store', headers: { 'X-Bunker-Fase': '1' }
    });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.status === 'started') {
      phaseLocal[code] = { t: Date.now(), ts0: ts0, seen: false };
      if (lastStatusData) renderSaluteFasi(lastStatusData);
    } else {
      alert('Impossibile avviare la fase ' + code + ': ' + (data.error || ('errore HTTP ' + res.status)));
    }
  } catch (e) {
    alert('Errore di rete durante la richiesta della fase ' + code + '.');
  }
}

async function confirmForceRpzUpdate() {
  if (!confirm("Avviare subito i task pianificati di aggiornamento RPZ?\n\n\u2022 Unbound_Bunker_2h (HaGeZi/Spamhaus/TIF)\n\u2022 Unbound_Bunker_AbuseCh30m (abuse.ch URLhaus/ThreatFox)\n\nIl download e il ricaricamento delle blocklist possono richiedere alcuni minuti.")) return;

  const btn = document.getElementById('btnForceRpz');
  const status = document.getElementById('forceRpzStatus');
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Avvio in corso...'; }

  try {
    const res = await fetch('/api/force-rpz-update', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.status === 'started') {
      if (status) status.textContent = 'Task avviati alle ' + new Date().toLocaleTimeString('it-IT') + '. Controlla "Freschezza Blocklist" tra qualche minuto.';
    } else {
      if (status) status.textContent = 'Errore nell\'avvio dei task: ' + (data.error || 'sconosciuto');
    }
  } catch (e) {
    if (status) status.textContent = 'Errore di rete durante la richiesta.';
  }

  if (btn) {
    btn.disabled = false;
    btn.innerHTML = '&#128260; Forza Aggiornamento RPZ';
  }
  setTimeout(() => { if (status) status.textContent = ''; }, 30000);
}

async function refreshDnsToggleStatus() {
  const label = document.getElementById('dnsToggleLabel');
  const btn = document.getElementById('btnToggleDns');
  if (!label || !btn || btn.disabled) return;
  try {
    const res = await fetch('/api/dns-status', { cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (data.disponibile) {
      window.__dnsToggleState = data;
      if (data.modalita === 'manuale') {
        const dohTag = data.dohAttivo ? ' \ud83d\udd12 DoH' : ' \u26a0\ufe0f DoH non attivo';
        label.textContent = 'DNS attuale: Bunker (127.0.0.1/::1)' + dohTag + ' \u2014 Clic: passa ad Automatico';
        btn.title = 'Interfacce "' + data.interfaccia + '": DNS attualmente manuale su 127.0.0.1/::1 (Bunker). ' +
          (data.dohAttivo ? 'Crittografato via DoH su https://localhost:8443/dns-query.' : 'ATTENZIONE: DoH non risulta attivo, il DNS potrebbe viaggiare in chiaro su UDP/53.') +
          ' Clic per riportarlo su Automatico (DHCP).';
      } else if (data.modalita === 'automatico') {
        label.textContent = 'DNS attuale: Automatico (DHCP) \u2014 Clic: passa a Bunker (127.0.0.1/::1)';
        btn.title = 'Interfacce "' + data.interfaccia + '": DNS attualmente Automatico (DHCP) su tutte. Clic per impostarlo su 127.0.0.1/::1 (Bunker) con DoH.';
      } else if (data.modalita === 'misto') {
        label.textContent = 'DNS attuale: MISTO \u26a0\ufe0f \u2014 Clic: allinea tutte a Bunker';
        btn.title = 'Interfacce "' + data.interfaccia + '": alcune sono su Bunker (127.0.0.1/::1) e altre su Automatico. Clic per portarle TUTTE su Bunker.';
      } else {
        label.textContent = 'DNS attuale: sconosciuto';
      }
    } else {
      window.__dnsToggleState = null;
      label.textContent = 'DNS: N/D';
      btn.title = data.errore ? data.errore : 'Interfaccia di rete non rilevata.';
    }
  } catch (e) {
    label.textContent = 'N/D';
  }
}

async function confirmToggleDns() {
  const st = window.__dnsToggleState;
  let msg;
  if (st && st.modalita === 'manuale') {
    msg = 'Interfacce "' + st.interfaccia + '": il DNS e\' attualmente impostato manualmente su 127.0.0.1 / ::1 (Bunker) su tutte.\n\nRiportarlo su Automatico (DHCP) su tutte?';
  } else if (st && st.modalita === 'automatico') {
    msg = 'Interfacce "' + st.interfaccia + '": il DNS e\' attualmente Automatico (DHCP) su tutte.\n\nImpostarlo manualmente su 127.0.0.1 (IPv4) e ::1 (IPv6), puntando al Bunker locale, su tutte?';
  } else if (st && st.modalita === 'misto') {
    msg = 'Interfacce "' + st.interfaccia + '": alcune sono gia\' su Bunker (127.0.0.1/::1) e altre su Automatico.\n\nPortarle TUTTE su Bunker locale (127.0.0.1 / ::1)?';
  } else {
    msg = 'Commutare il DNS di tutte le schede di rete attive tra Automatico e Bunker locale (127.0.0.1 / ::1)?';
  }
  if (!confirm(msg)) return;

  const btn = document.getElementById('btnToggleDns');
  const label = document.getElementById('dnsToggleLabel');
  const status = document.getElementById('dnsToggleStatus');
  if (btn) btn.disabled = true;
  if (label) label.textContent = '...';

  try {
    const res = await fetch('/api/dns-toggle', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.status === 'ok') {
      if (status) {
        const dohInfo = data.attuale === 'manuale' ? (data.dohAttivo ? ' DoH attivo \ud83d\udd12.' : ' ATTENZIONE: DoH non attivo, DNS in chiaro!') : '';
        status.textContent = 'Interfacce "' + data.interfaccia + '": DNS commutato da ' + data.precedente + ' a ' + data.attuale + '.' + dohInfo + ' (' + new Date().toLocaleTimeString('it-IT') + ')';
      }
    } else if (res.ok && data.status === 'parziale') {
      if (status) status.textContent = 'DNS commutato solo su alcune interfacce ("' + data.interfaccia + '"); errori: ' + (data.error || 'sconosciuto');
    } else {
      if (status) status.textContent = 'Errore nel toggle DNS: ' + (data.error || 'sconosciuto');
    }
  } catch (e) {
    if (status) status.textContent = 'Errore di rete durante la richiesta.';
  }

  if (btn) btn.disabled = false;
  await refreshDnsToggleStatus();
  setTimeout(() => { if (status) status.textContent = ''; }, 30000);
}

async function confirmUpdateDashboard() {
  if (!confirm("Scaricare l'ultima versione della dashboard dal repository GitHub?\n\nSe l'hash SHA256 non corrisponde l'aggiornamento viene annullato automaticamente e la versione attuale resta invariata. Se invece va a buon fine, la dashboard si riavvia da sola (perderai la connessione per qualche secondo).")) return;

  const btn = document.getElementById('btnUpdateDash');
  const status = document.getElementById('updateDashStatus');
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Download e verifica in corso...'; }
  if (status) status.textContent = '';

  try {
    const res = await fetch('/api/update-dashboard', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (res.ok && data.status === 'updated') {
      if (status) status.textContent = 'Aggiornamento riuscito, riavvio in corso...';
      if (btn) btn.innerHTML = '&#9203; Riavvio in corso...';
      waitForDashboardRestartAfterUpdate();
      return;
    } else {
      if (status) status.textContent = 'Aggiornamento annullato: ' + (data.error || 'errore sconosciuto');
    }
  } catch (e) {
    if (status) status.textContent = 'Errore di rete durante la richiesta.';
  }

  if (btn) { btn.disabled = false; btn.innerHTML = '&#11015;&#65039; Aggiorna Dashboard da GitHub'; }
  setTimeout(() => { if (status) status.textContent = ''; }, 30000);
}

function waitForDashboardRestartAfterUpdate() {
  setLiveStatus(false);
  document.getElementById('subheader').textContent = 'Aggiornamento applicato, riavvio della Dashboard in corso...';
  showRestartOverlay('&#11015;&#65039;', 'Aggiornamento applicato, riavvio della Dashboard...', 'La nuova versione sta ripartendo, attendere...');

  let attempts = 0;
  const SOFT_LIMIT = 35;
  const HARD_LIMIT = 90;
  const checkInterval = setInterval(async () => {
    attempts++;
    updateRestartProgress((attempts / HARD_LIMIT) * 95);
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (res.ok) {
        clearInterval(checkInterval);
        updateRestartProgress(100);
        location.href = location.pathname + '?dashboard_updated=1';
      }
    } catch(e) {}

    if (attempts === SOFT_LIMIT) {
      document.getElementById('restartOverlaySub').textContent =
        'Sta impiegando più del previsto (possibile scansione antivirus del processo appena avviato)... continuo ad attendere.';
    }

    if (attempts > HARD_LIMIT) {
      clearInterval(checkInterval);
      alert("Il riavvio dopo l'aggiornamento non risulta ancora completato dopo " + HARD_LIMIT + " secondi. Ricarica manualmente la pagina tra qualche secondo, oppure controlla che il processo sia effettivamente ripartito.");
      document.getElementById('restartOverlay').classList.remove('active');
      const btn = document.getElementById('btnUpdateDash');
      if (btn) { btn.disabled = false; btn.innerHTML = '&#11015;&#65039; Aggiorna Dashboard da GitHub'; }
    }
  }, 1000);
}

// === AGGIORNA COMPONENTI (Dashboard + Engine/BAT/service.conf) ===
// Passo 1: riusa /api/update-dashboard (stesso meccanismo del pulsante "Aggiorna
// Dashboard da GitHub": download, verifica SHA256, backup, sostituzione, riavvio).
// Passo 2: riusa /api/restart-manager per rilanciare UnboundBunkerManager.BAT, che
// nella sua normale routine di avvio esegue il controllo/aggiornamento di Unbound
// Engine, del BAT stesso e di service.conf. Nessun nuovo endpoint server-side:
// entrambi i passi si appoggiano a meccanismi gia' collaudati.
// Il passo 1 riavvia il processo Dashboard (perdendo lo stato JS in memoria), quindi
// la prosecuzione al passo 2 viene segnalata attraverso un parametro nell'URL dopo
// il ricaricamento della pagina (stesso pattern di ?dashboard_updated=1).
function resetUpdateComponentsButton() {
  const btn = document.getElementById('btnUpdateComponents');
  if (btn) { btn.disabled = false; btn.innerHTML = '&#129513; Aggiorna Componenti'; }
}

async function confirmUpdateComponents() {
  if (!confirm("Aggiornare tutti i componenti del Bunker?\n\n1) Dashboard (da GitHub, con verifica SHA256 e riavvio automatico)\n2) Unbound Engine + UnboundBunkerManager.BAT + service.conf (rilanciando il Manager, che esegue da solo il controllo/aggiornamento di questi 3 file durante il suo avvio)\n\nIl passo 2 non ha un segnale affidabile di completamento: verifica lo stato/le versioni manualmente dopo qualche minuto.")) return;

  const btn = document.getElementById('btnUpdateComponents');
  const status = document.getElementById('updateComponentsStatus');
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Aggiornamento in corso...'; }
  if (status) status.textContent = '';

  runUpdateComponentsStep1();
}

async function runUpdateComponentsStep1() {
  setLiveStatus(false);
  document.getElementById('subheader').textContent = 'Aggiornamento Componenti in corso... Passo 1 di 2: Dashboard';
  showRestartOverlay('&#129513;', 'Aggiornamento Componenti - Passo 1 di 2', 'Download e verifica SHA256 della Dashboard da GitHub in corso...');
  updateRestartProgress(8);

  let esito = 'error';
  let errMsg = 'errore sconosciuto';
  try {
    const res = await fetch('/api/update-dashboard', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    esito = data.status || 'error';
    errMsg = data.error || errMsg;
  } catch (e) {
    errMsg = 'errore di rete durante la richiesta';
  }

  if (esito === 'updated') {
    document.getElementById('restartOverlaySub').textContent = 'Dashboard aggiornata, riavvio in corso...';
    sessionStorage.setItem('bunkerComponentsUpdateStep2', '1');
    waitForComponentsStep1Restart();
    return;
  }

  // Passo 1 fallito (es. hash non corrispondente, repo irraggiungibile): non blocca il
  // passo 2, che riguarda file indipendenti (Engine/BAT/service.conf).
  const status = document.getElementById('updateComponentsStatus');
  if (status) status.textContent = 'Passo 1 (Dashboard) non riuscito: ' + errMsg + ' - si procede comunque con il Passo 2.';
  document.getElementById('restartOverlaySub').textContent = 'Passo 1 (Dashboard) non riuscito: ' + errMsg + '. Si procede con il Passo 2...';
  await new Promise(r => setTimeout(r, 2500));
  runUpdateComponentsStep2();
}

function waitForComponentsStep1Restart() {
  let attempts = 0;
  const SOFT_LIMIT = 35;
  const HARD_LIMIT = 90;
  const checkInterval = setInterval(async () => {
    attempts++;
    updateRestartProgress(8 + (attempts / HARD_LIMIT) * 37);
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (res.ok) {
        clearInterval(checkInterval);
        updateRestartProgress(45);
        location.href = location.pathname + '?components_update_step2=1';
      }
    } catch(e) {}

    if (attempts === SOFT_LIMIT) {
      document.getElementById('restartOverlaySub').textContent =
        'Sta impiegando più del previsto (possibile scansione antivirus del processo appena avviato)... continuo ad attendere.';
    }

    if (attempts > HARD_LIMIT) {
      clearInterval(checkInterval);
      alert("Il riavvio della Dashboard dopo l'aggiornamento (Passo 1) non risulta completato dopo " + HARD_LIMIT + " secondi. Ricarica manualmente la pagina, poi usa \"Riavvia Manager .BAT\" per completare l'aggiornamento di Engine/BAT/service.conf.");
      document.getElementById('restartOverlay').classList.remove('active');
      sessionStorage.removeItem('bunkerComponentsUpdateStep2');
      resetUpdateComponentsButton();
    }
  }, 1000);
}

async function runUpdateComponentsStep2() {
  sessionStorage.removeItem('bunkerComponentsUpdateStep2');
  document.getElementById('subheader').textContent = 'Aggiornamento Componenti in corso... Passo 2 di 2: Engine/BAT/service.conf';
  showRestartOverlay('&#128295;', 'Aggiornamento Componenti - Passo 2 di 2', 'Avvio di UnboundBunkerManager.BAT per il controllo/aggiornamento di Unbound Engine, BAT e service.conf...');
  updateRestartProgress(55);

  const status = document.getElementById('updateComponentsStatus');
  let esito = 'error';
  let errMsg = 'errore sconosciuto';
  try {
    const res = await fetch('/api/restart-manager', { method: 'POST', cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    esito = data.status || 'error';
    errMsg = data.error || errMsg;
  } catch (e) {
    errMsg = 'errore di rete durante la richiesta';
  }

  updateRestartProgress(100);

  if (esito === 'started') {
    document.getElementById('restartOverlaySub').textContent = 'Manager avviato. Il controllo/aggiornamento di Engine, BAT e service.conf procede in background.';
    if (status) status.textContent = 'Manager avviato alle ' + new Date().toLocaleTimeString('it-IT') + '. Verifica versioni/stato tra qualche minuto.';
  } else {
    document.getElementById('restartOverlaySub').textContent = 'Errore nell\'avvio del Manager: ' + errMsg;
    if (status) status.textContent = 'Passo 2 (Manager) non riuscito: ' + errMsg;
  }

  setTimeout(() => {
    hideRestartOverlay();
    resetUpdateComponentsButton();
    refresh(true);
  }, 1500);

  setTimeout(() => { if (status) status.textContent = ''; }, 30000);
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

    lastDataTs = Date.now();
    setLiveStatus(true);

    try { renderStatusBanner(d); } catch (e) { /* il banner non deve mai bloccare il resto del refresh */ }

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
        <span style="color:var(--dim); font-weight:bold; display:inline-block; min-width:64px;">Ipv4 Lan</span>
        <span style="display:inline-block; min-width:58px;" class="${ipc.ipv4_lan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv4_lan_ok ? 'ONLINE' : 'OFFLINE'}</span>
        <span style="color:var(--dim); font-weight:bold;">:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv4_lan || 'N/D'}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv4_wan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold; display:inline-block; min-width:64px;">Ipv4 WAN</span>
        <span style="display:inline-block; min-width:58px;" class="${ipc.ipv4_wan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv4_wan_ok ? 'ONLINE' : 'OFFLINE'}</span>
        <span style="color:var(--dim); font-weight:bold;">:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv4_wan || 'N/D'}${locV4Str}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv6_lan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold; display:inline-block; min-width:64px;">Ipv6 Lan</span>
        <span style="display:inline-block; min-width:58px;" class="${ipc.ipv6_lan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv6_lan_ok ? 'ONLINE' : 'OFFLINE'}</span>
        <span style="color:var(--dim); font-weight:bold;">:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv6_lan || 'N/D'}</span>
      </div>
      <div class="stat-ver">
        <div class="status-dot-container"><span class="status-dot ${ipc.ipv6_wan_ok ? 'ok' : 'bad'}"></span></div>
        <span style="color:var(--dim); font-weight:bold; display:inline-block; min-width:64px;">Ipv6 WAN</span>
        <span style="display:inline-block; min-width:58px;" class="${ipc.ipv6_wan_ok ? 'ver-status-ok' : 'esito-warn'}">${ipc.ipv6_wan_ok ? 'ONLINE' : 'OFFLINE'}</span>
        <span style="color:var(--dim); font-weight:bold;">:</span>
        <span style="color:#ffffff; font-weight:bold;">${ipc.ipv6_wan || 'N/D'}${locV6Str}</span>
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
      <div class="stat-ver">
        <span style="color:var(--dim); font-weight:bold;">&#128421;&#65039; Dashboard:</span>
        <span style="color:#ffffff; font-weight:bold;">v${v.dash_local || 'N/D'}</span>
        <span class="muted" style="font-size:0.8em;">(Cloud: v${v.dash_cloud || 'N/D'})</span>
        ${getVerBadge(v.dash_local, v.dash_cloud)}
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
    if (qTot === 0 && (!effectiveLat || effectiveLat <= 0) && radarList.length > 0) {
      const okRadars = radarList.filter(r => r.ok);
      if (okRadars.length > 0) {
        effectiveLat = Math.round(okRadars.reduce((acc, r) => acc + r.ms, 0) / okRadars.length);
      }
    }
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

    const displayLat = effectiveLat;
    const msSaved = Math.max(0, Math.round(effectiveBaselineMs - displayLat));

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

    document.getElementById('valRpzRules').textContent = fmt(bf.total_rpz_rules || 0) + ' regole';

    const rpzTaskRun = d.rpz_task_last_run || {};
    const valRpzTaskCheckEl = document.getElementById('valRpzTaskCheck');
    if (valRpzTaskCheckEl) {
      if (rpzTaskRun.piu_recente && rpzTaskRun.piu_recente !== 'N/D') {
        const minFa = rpzTaskRun.piu_recente_min_fa;
        let etaTxt = '';
        if (typeof minFa === 'number' && minFa >= 0) {
          const oreInt = Math.floor(minFa / 60);
          const minRes = minFa % 60;
          etaTxt = oreInt > 0 ? ` (${oreInt}h ${minRes}m fa)` : ` (${minRes}m fa)`;
        }
        valRpzTaskCheckEl.textContent = `Ultimo controllo liste: ${rpzTaskRun.piu_recente}${etaTxt}`;
        valRpzTaskCheckEl.title = (rpzTaskRun.tasks || []).map(t => `${t.task}: ${t.ultimo_run} (${t.last_result})`).join(' | ');
      } else {
        valRpzTaskCheckEl.textContent = 'Ultimo controllo liste: N/D';
      }
    }

    let rpzGlobalScore = (d.rpz_freshness && typeof d.rpz_freshness.score_globale === 'number') ? d.rpz_freshness.score_globale : 100;
    const barRpzRulesEl = document.getElementById('barRpzRules');
    if (barRpzRulesEl) {
      barRpzRulesEl.style.width = (bf.total_rpz_rules > 0 ? 100 : 0) + '%';
      if (bf.total_rpz_rules > 0 && rpzGlobalScore >= 90) {
        barRpzRulesEl.style.background = 'linear-gradient(90deg, #196f3d 0%, #145a32 100%)';
      } else if (bf.total_rpz_rules > 0 && rpzGlobalScore >= 60) {
        barRpzRulesEl.style.background = 'linear-gradient(90deg, #d35400 0%, #f1c40f 100%)';
      } else {
        barRpzRulesEl.style.background = 'linear-gradient(90deg, #78281f 0%, #c0392b 100%)';
      }
    }
    let rpzDettaglio = bf.rpz_dettaglio || [];
    if (!Array.isArray(rpzDettaglio)) { rpzDettaglio = [rpzDettaglio]; }

    let freschezzaListe = (d.rpz_freshness && d.rpz_freshness.liste) || [];
    if (!Array.isArray(freschezzaListe)) { freschezzaListe = [freschezzaListe]; }
    const freschezzaByTag = {};
    freschezzaListe.forEach(f => { freschezzaByTag[f.tag] = f; });
    const labelEsito = { ok: 'AGGIORNATA', attenzione: 'DA VERIFICARE', scaduta: 'NON AGGIORNATA', mancante: 'FILE MANCANTE', sconosciuto: 'N/D' };
    const classeEsito = { ok: 'esito-ok', attenzione: 'esito-attenzione', scaduta: 'esito-warn', mancante: 'esito-warn', sconosciuto: 'esito-warn' };

    document.getElementById('rpzDettaglio').innerHTML = rpzDettaglio.map(r => {
      const fr = freschezzaByTag[r.tag];
      let rigaFreschezza = '';
      if (fr) {
        const cls = classeEsito[fr.esito] || 'esito-warn';
        const lbl = labelEsito[fr.esito] || fr.esito;
        const oreTxt = fr.eta_txt || ((typeof fr.ore_fa === 'number' && fr.ore_fa >= 0) ? `${fr.ore_fa} ore fa` : '--');
        rigaFreschezza = `<div style="display:flex; justify-content:space-between; font-size:0.92em; margin-top:1px;">
          <span class="${cls}">${lbl}</span>
          <span class="${cls}">(${oreTxt}) ${fr.ultimo_agg || 'N/D'}</span>
        </div>`;
      }
      return `<div style="border-bottom:1px solid rgba(255,255,255,0.05); padding:3px 0;">
        <div style="display:flex; justify-content:space-between;">
          <span>${r.emoji || '&#128737;'} ${r.nome || '-'}</span>
          <b style="color:var(--accent); text-align:right; margin-left:8px;">${fmt(r.regole || 0)}</b>
        </div>
        ${rigaFreschezza}
      </div>`;
    }).join('');

    const ramData = bf.unbound_ram_data || {};
    document.getElementById('valUnboundRam').textContent = (ramData.ws_mb || 0) + ' MB';
    let ramSysPct = ramData.pct_sys || 0;
    let ramEfficiency = Math.max(0, Math.min(100, 100 - ramSysPct));
    updateGradientBar('barUnboundRam', ramData.ws_mb > 0 ? ramEfficiency : 0);
    
    document.getElementById('ramDettaglio').innerHTML = `
      <div>&#129504; Processo PID: <b style="color:var(--accent);">${ramData.pid || '-'}</b></div>
      <div>&#128187; Incidenza RAM Sistema: <b style="color:var(--accent);">${ramData.pct_sys || 0}%</b> (su ${fmt(ramData.sys_ram_mb || 0)} MB)</div>
      <div>&#9881;&#65039; Profilo Hardware: <b style="color:var(--accent);">${d.hardware.profilo || 'N/D'}</b></div>
    `;

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

    const hardScore = bf.hardening_score || 0;
    document.getElementById('valHardening').innerHTML = hardScore + '% ' + (hardScore === 100 ? '<span class="esito-ok">[BLINDATO]</span>' : '<span class="esito-warn">[PARZIALE]</span>');
    updateGradientBar('barHardening', hardScore);
    let hardDettaglio = bf.hardening_dettaglio || [];
    if (!Array.isArray(hardDettaglio)) { hardDettaglio = [hardDettaglio]; }
    document.getElementById('hardeningDettaglio').innerHTML = hardDettaglio.map(h =>
      `<div>${h.ok ? '<span class="esito-ok">&#10004;</span>' : '<span class="esito-warn">&#10008;</span>'} ${h.nome || '-'}</div>`
    ).join('');

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

    const hlOk = (bf.hyperlocal && bf.hyperlocal.attivo);
    const hlDesc = (bf.hyperlocal && bf.hyperlocal.desc) || (hlOk ? 'Attivo' : 'Disattivato');
    document.getElementById('valHyperlocal').innerHTML = hlOk ? `<span class="esito-ok">${hlDesc}</span>` : `<span class="muted">${hlDesc}</span>`;
    updateGradientBar('barHyperlocal', hlOk ? 100 : 10);
    let hlDettaglio = (bf.hyperlocal && bf.hyperlocal.dettaglio) || [];
    if (!Array.isArray(hlDettaglio)) { hlDettaglio = [hlDettaglio]; }
    document.getElementById('hyperlocalDettaglio').innerHTML = hlDettaglio.map(h =>
      `<div>${h.ok ? '<span class="esito-ok">&#10004;</span>' : '<span class="esito-warn">&#10008;</span>'} ${h.nome || '-'}</div>`
    ).join('');

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

    const uptimeSec = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.uptime_secondi || 0) : 0;
    
    function formatUptimeSintetico(totalSec) {
      if (!totalSec || totalSec <= 0) return '0s';
      const y = Math.floor(totalSec / 31536000);
      const mo = Math.floor((totalSec % 31536000) / 2592000);
      const d = Math.floor((totalSec % 2592000) / 86400);
      const h = Math.floor((totalSec % 86400) / 3600);
      const m = Math.floor((totalSec % 3600) / 60);
      const s = Math.floor(totalSec % 60);

      let p = [];
      if (y > 0) p.push(`${y}a`);
      if (mo > 0) p.push(`${mo}M`);
      if (d > 0) p.push(`${d}g`);
      if (h > 0) p.push(`${h}h`);
      if (m > 0) p.push(`${m}m`);
      if (s > 0 || p.length === 0) p.push(`${s}s`);

      return p.join(' ');
    }
    
    const uptimeStr = formatUptimeSintetico(uptimeSec);
    document.getElementById('valUptime').textContent = uptimeSec > 0 ? uptimeStr : 'N/D';
    updateGradientBar('barUptime', uptimeSec > 3600 ? 100 : (uptimeSec > 0 ? 40 : 0));
    document.getElementById('uptimeDettaglio').innerHTML = `
      <div>&#128640; Data Ultimo Avvio: <b style="color:var(--accent);">${bf.engine_start_time || 'N/D'}</b></div>
      <div>&#9201;&#65039; Uptime Assoluto: <b style="color:var(--accent);">${uptimeStr}</b> <span class="muted">(${fmt(uptimeSec)} sec)</span></div>
    `;

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

    let rpzStatePct = (d.rpz_freshness && typeof d.rpz_freshness.score_globale === 'number') ? d.rpz_freshness.score_globale : 100;
    let listaCritica = (d.rpz_freshness && d.rpz_freshness.lista_critica) ? d.rpz_freshness.lista_critica : '';
    
    const bRpzState = document.createElement('span');
    let rpzStateStyle = 'ok';
    if (rpzStatePct <= 50) { rpzStateStyle = 'bad'; }
    else if (rpzStatePct < 100) { rpzStateStyle = 'net'; }
    bRpzState.className = 'badge ' + rpzStateStyle;
    bRpzState.innerHTML = '&#128737; STATO RPZ: <b>' + rpzStatePct + '%</b>';
    bRpzState.title = 'Stato aggiornamento liste RPZ (soglie dinamiche):\n- Malware (URLhaus/ThreatFox/TIF): 12h\n- Spamhaus: 48h\n- Liste Generiche (Pro Plus/DynDNS): 96h\n' + (listaCritica ? '- Lista che incide sul punteggio: ' + listaCritica : '');
    badges.appendChild(bRpzState);

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
    bCache.style.marginLeft = 'auto';
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

    const gainContainer = document.getElementById('bunkerGainContainer');
    if (gainContainer) {
      gainContainer.innerHTML = '';
      gainContainer.appendChild(bGain);
    }

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
        const tagHtml = r.tag || '-';
        const rc = r.ok ? rankColor(index, radar.length) : 'rgb(255, 92, 92)'; // --red-bright se irraggiungibile
        tr.style.background = `rgba(${rc.match(/\d+/g).join(', ')}, 0.20)`;
        tr.style.borderLeft = `4px solid ${rc}`;

        const stIcon = `<div class="status-dot-container"><span class="status-dot ${r.ok ? 'ok' : 'bad'}"></span></div>`;
        const stText = r.ok ? '<span class="esito-ok">PORTA 853 OK</span>' : '<span class="esito-warn">IRRAGGIUNGIBILE</span>';
        const msText = r.ok ? r.ms + ' ms' : 'TIMEOUT';

        tr.innerHTML = `<td>${stIcon}</td><td style="font-weight:bold;">${tagHtml}</td><td>${r.ip || '-'}:${r.port || '853'}</td><td class="latency" style="color:${rc}; font-weight:bold;">${msText}</td><td>${stText}</td>`;
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
        rootRadar.forEach((r, index) => {
          const tr = document.createElement('tr');
          const rc = r.ok ? rankColor(index, rootRadar.length) : 'rgb(255, 92, 92)'; // --red-bright se irraggiungibile
          tr.style.background = `rgba(${rc.match(/\d+/g).join(', ')}, 0.20)`;
          tr.style.borderLeft = `4px solid ${rc}`;

          const stIcon = `<div class="status-dot-container"><span class="status-dot ${r.ok ? 'ok' : 'bad'}"></span></div>`;
          const msText = r.ok ? `<span style="font-weight:bold; color:${rc};">${r.ms} ms</span>` : '<span class="esito-warn">IRRAGGIUNGIBILE</span>';

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

    renderStorico(d);
    renderAnomalie(d);
    renderRestartLog(d);
    renderBlocchiOrari(d);
    renderDnsFallbackLog(d);
    renderWinUpdate(d);
    renderPeriodicTasks(d);
    renderLiveLogFeed(d);
    renderLiveLogSummary(d);
    renderCerberoRuntime(d);

    const s = d.totale_sessione;
    const sessDiv = document.getElementById('statsSessione');
    if (s) {
      const oreCoperte = (typeof s.ore_coperte === 'number') ? s.ore_coperte : null;
      const coperturaTxt = oreCoperte !== null ? `${oreCoperte}h coperte` : (s.dal || '-');
      sessDiv.innerHTML = `
        <div class="stat"><div class="val">${fmt(s.query)}</div><div class="lbl">Query (ultime 24h)</div></div>
        <div class="stat"><div class="val">${fmt(s.blocchi)}</div><div class="lbl">Blocchi (ultime 24h)</div></div>
        <div class="stat"><div class="val muted" style="font-size:0.9em">${coperturaTxt}</div><div class="lbl">Finestra dati</div></div>
      `;
    } else {
      sessDiv.innerHTML = '<div class="muted">Nessun dato di sessione ancora disponibile</div>';
    }

    renderSaluteFasi(d);

    const tbodyRcode = document.querySelector('#tabellaLiveRcode tbody');
    if (tbodyRcode) {
      tbodyRcode.innerHTML = '';
      let feedRcode = d.live_rcode_feed || [];
      if (!Array.isArray(feedRcode)) { feedRcode = [feedRcode]; }

      if (feedRcode.length === 0) {
        tbodyRcode.innerHTML = '<tr><td colspan="5" class="muted">Nessun evento RCODE registrato di recente nel log</td></tr>';
      } else {
        const feedCronologico = feedRcode.slice().reverse();
        feedCronologico.forEach(f => {
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

if (new URLSearchParams(location.search).get('dashboard_updated') === '1') {
  history.replaceState(null, '', location.pathname);
  showUpdateToast();
}

// Prosecuzione del flusso "Aggiorna Componenti" dopo il riavvio della Dashboard
// (Passo 1 completato): il parametro in URL sopravvive al reload del processo,
// sessionStorage e' una controprova extra in caso di refresh manuale della pagina.
if (new URLSearchParams(location.search).get('components_update_step2') === '1') {
  history.replaceState(null, '', location.pathname);
  sessionStorage.removeItem('bunkerComponentsUpdateStep2');
  const btn = document.getElementById('btnUpdateComponents');
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Aggiornamento in corso...'; }
  runUpdateComponentsStep2();
}

refresh(true);
setInterval(refresh, 2000);
setInterval(() => {
  if (Date.now() - lastDataTs > 8000) setLiveStatus(false);
}, 1000);

refreshDnsToggleStatus();
setInterval(refreshDnsToggleStatus, 15000);
</script>
</body>
</html>
'@

# === RACCOLTA DATI IN BACKGROUND (runspace separato, thread indipendente) ===
function Start-BackgroundCollectorLoop {
    Write-DashLog "Ciclo di raccolta dati in background avviato (PID $PID)."
    while ($true) {
        try { Get-BunkerStatusJson | Out-Null } catch { Write-DashLog "Errore nel ciclo di raccolta background: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 1500
    }
}

function Start-BackgroundCollector {
    $script:BunkerSyncHash = [hashtable]::Synchronized(@{ Json = $null; Ts = [DateTime]::MinValue })

    $bgRunspace = [runspacefactory]::CreateRunspace()
    $bgRunspace.ApartmentState = "MTA"
    $bgRunspace.ThreadOptions  = "ReuseThread"
    $bgRunspace.Open()
    $bgRunspace.SessionStateProxy.SetVariable('BunkerSyncHash', $script:BunkerSyncHash)

    $bgPowerShell = [powershell]::Create()
    $bgPowerShell.Runspace = $bgRunspace
    [void]$bgPowerShell.AddScript({
        param($ScriptPath)
        $script:IsBackgroundCollector = $true
        . $ScriptPath
    }).AddArgument($script:CurrentScriptPath)

    $script:BgPowerShell = $bgPowerShell
    $script:BgRunspace   = $bgRunspace
    $script:BgHandle     = $bgPowerShell.BeginInvoke()

    Write-DashLog "Runspace di raccolta dati in background avviato (thread separato dal server HTTP)."
}

# === FIX5 HTTP LIFECYCLE SAFE ===
function Close-HttpResponseSafe {
    param(
        [System.Net.HttpListenerResponse]$Response
    )
    try {
        if ($null -ne $Response) {
            if ($null -ne $Response.OutputStream) {
                $Response.OutputStream.Close()
            }
            $Response.Close()
        }
    } catch {}
}

function Write-HttpResponseSafe {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [byte[]]$Buffer
    )

    if ($null -eq $Response -or $null -eq $Response.OutputStream) {
        return
    }

    try {
        $Response.KeepAlive = $false
        $Response.ContentLength64 = $Buffer.Length
        $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
    }
    catch [System.Net.HttpListenerException] {
        # Client/browser disconnesso durante la risposta.
        # Evento normale per refresh o riavvii della dashboard.
    }
    catch [System.ObjectDisposedException] {
        # Response gia' chiusa durante restart listener.
    }
    catch {
        Write-DashLog "Errore durante risposta HTTP: $($_.Exception.Message)"
    }
    finally {
        Close-HttpResponseSafe $Response
    }
}

# === SERVER HTTP LOCALE (LOOPBACK ONLY) ===
function Start-DashboardServer {
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
    try {
        $owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($owner) {
            $ownerProc = Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue
            Write-DashLog "Porta $Port gia' occupata da PID $($owner.OwningProcess) ($($ownerProc.ProcessName), avviato $($ownerProc.StartTime))."
        }
    } catch {}
    Write-DashLog "Impossibile avviare il listener su $Port dopo tutti i tentativi. Uscita immediata (nessun thread di raccolta avviato)."
    [Environment]::Exit(1)
}

Write-Host "[OK] Unbound Bunker DASHBOARD LIVE in ascolto su $Prefix (Ctrl+C per arrestare)"

Start-BackgroundCollector
Start-TrayIcon

try { [System.IO.File]::WriteAllText($PidFile, [string]$PID) } catch { Write-DashLog "Impossibile scrivere PID file: $($_.Exception.Message)" }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        try {
            if ($request.Url.AbsolutePath -eq "/api/status") {
                $forceVersions = $request.Url.Query -match '(\?|&)force=1(&|$)'
                if ($forceVersions) {
                    $json = Get-BunkerStatusJson -ForceVersions
                } elseif ($script:BunkerSyncHash -and $script:BunkerSyncHash.Json) {
                    $json = $script:BunkerSyncHash.Json
                } else {
                    $json = Get-BunkerStatusJson
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/restart") {
                Write-DashLog "Richiesta di riavvio ricevuta dall'interfaccia Web."
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"restarting"}')
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
                Close-HttpResponseSafe $response

                $targetScript = if ($script:CurrentScriptPath) { $script:CurrentScriptPath } else { Join-Path $UbDir "UnboundBunkerDashboard.ps1" }
                
                $restartCmd = "Start-Sleep -Seconds 1; " +
                              "Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue; " +
                              "for (`$i=0; `$i -lt 20; `$i++) { " +
                              "  `$conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue; " +
                              "  if (-not `$conn) { break }; " +
                              "  Start-Sleep -Milliseconds 500 " +
                              "}; " +
                              "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"$targetScript`"' -WindowStyle Hidden"

                Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$restartCmd`"" -WindowStyle Hidden
                break
            } elseif ($request.Url.AbsolutePath -eq "/api/restart-unbound" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di riavvio del servizio Unbound ricevuta dall'interfaccia Web."
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"status":"restarting"}')
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
                Close-HttpResponseSafe $response

                $restartUnboundCmd = "try { Restart-Service -Name 'unbound' -Force -ErrorAction Stop } catch { " +
                                      "try { Stop-Service -Name 'unbound' -Force -ErrorAction SilentlyContinue; " +
                                      "Start-Sleep -Seconds 2; Start-Service -Name 'unbound' -ErrorAction SilentlyContinue } catch {} }"

                Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$restartUnboundCmd`"" -WindowStyle Hidden
            } elseif ($request.Url.AbsolutePath -eq "/api/restart-manager" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di riavvio di UnboundBunkerManager.BAT (task Unbound_Bunker_Boot) ricevuta dall'interfaccia Web."

                # Stesso motivo del blocco RPZ qui sotto: si usa schtasks.exe
                # direttamente invece del modulo ScheduledTasks, gia' inaffidabile
                # su questa macchina.
                $managerTask = "Unbound_Bunker_Boot"
                $anyFailed = $false
                $taskResult = ""
                try {
                    $out = & schtasks.exe /run /tn $managerTask 2>&1 | Out-String
                    $ok  = ($LASTEXITCODE -eq 0)
                    if (-not $ok) { $anyFailed = $true }
                    $taskResult = "$managerTask -> $(if ($ok) { 'OK' } else { "FALLITO (exit $LASTEXITCODE)" }): $($out.Trim())"
                } catch {
                    $anyFailed = $true
                    $taskResult = "$managerTask -> ECCEZIONE: $($_.Exception.Message)"
                }
                Write-DashLog ("Esito avvio task manager: " + $taskResult)
                if ($anyFailed -and ($taskResult -match "(?i)access is denied|accesso negato|negata")) {
                    Write-DashLog "Il task $managerTask e' registrato per girare come SYSTEM/Amministratore: per avviarlo manualmente il processo Dashboard deve essere lui stesso elevato. Verificare con quale account/task e' partita l'istanza Dashboard attuale."
                }

                $esito  = if ($anyFailed) { "error" } else { "started" }
                $errMsg = if ($anyFailed) { $taskResult } else { $null }

                $respObj = [ordered]@{ status = $esito }
                if ($errMsg) { $respObj.error = $errMsg }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                if ($esito -eq "error") { $response.StatusCode = 500 }
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/run-phase" -and $request.HttpMethod -eq "POST") {
                # Avvia UNA sola fase del Manager .BAT (UnboundBunkerManager.BAT --fase <CODICE>).
                # Difese: header custom (impedisce POST cross-site da altre pagine web, che
                # richiederebbero un preflight CORS mai concesso), controllo Host/Origin
                # (anti DNS-rebinding), whitelist dei codici, una sola esecuzione alla volta.
                $phaseStatus = 500
                $phaseBody   = [ordered]@{ status = "error"; error = "errore interno" }
                try {
                    $faseReq = ([string]$request.QueryString["fase"]).ToUpperInvariant()
                    $hdrOk   = ([string]$request.Headers["X-Bunker-Fase"] -eq "1")
                    $hostOk  = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk  = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))

                    if (-not ($hdrOk -and $hostOk -and $origOk)) {
                        $phaseStatus = 403
                        $phaseBody   = [ordered]@{ status = "error"; error = "Richiesta non autorizzata (origine non valida)." }
                        Write-DashLog "Richiesta /api/run-phase rifiutata: header/host/origin non validi (Host=$($request.UserHostName) Origin=$origHdr)."
                    } elseif ($script:PhaseCodes -notcontains $faseReq) {
                        $phaseStatus = 400
                        $phaseBody   = [ordered]@{ status = "error"; error = "Codice fase non valido." }
                    } else {
                        $batPath = Join-Path $UbDir "UnboundBunkerManager.BAT"
                        $isAdmin = $false
                        try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
                        $script:PhaseRunCacheTime = [DateTime]::MinValue
                        $giaInCorso = Get-PhaseRunMarkers

                        if (-not (Test-Path -LiteralPath $batPath)) {
                            $phaseBody = [ordered]@{ status = "error"; error = "UnboundBunkerManager.BAT non trovato in $UbDir." }
                        } elseif (-not $isAdmin) {
                            $phaseBody = [ordered]@{ status = "error"; error = "La Dashboard non e' in esecuzione come Amministratore: impossibile avviare la fase." }
                        } elseif ($giaInCorso.Count -gt 0) {
                            $phaseStatus = 409
                            $phaseBody   = [ordered]@{ status = "error"; error = "Un'altra fase e' gia' in esecuzione: attendi che termini." }
                        } elseif (Test-ManagerBatRunning) {
                            $phaseStatus = 409
                            $phaseBody   = [ordered]@{ status = "error"; error = "Il Manager .BAT e' in esecuzione (avvio o aggiornamento pianificato): riprova al termine." }
                        } else {
                            $markPath = Join-Path $script:PhaseRunDir ("bunker_phase_" + $faseReq + ".run")
                            try {
                                [System.IO.File]::WriteAllText($markPath, (Get-Date).ToString("o"))
                                $script:PhaseRunCacheTime = [DateTime]::MinValue
                                $cmdArgs = '/c ""' + $batPath + '" --fase ' + $faseReq + '"'
                                Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -WorkingDirectory $UbDir -WindowStyle Hidden
                                Write-DashLog "Avviata la singola fase $faseReq del Manager .BAT su richiesta dell'interfaccia Web."
                                $phaseStatus = 200
                                $phaseBody   = [ordered]@{ status = "started"; fase = $faseReq }
                            } catch {
                                try { Remove-Item -LiteralPath $markPath -Force -ErrorAction SilentlyContinue } catch {}
                                $phaseBody = [ordered]@{ status = "error"; error = "Avvio della fase fallito: $($_.Exception.Message)" }
                                Write-DashLog "Errore nell'avvio della fase $faseReq : $($_.Exception.Message)"
                            }
                        }
                    }
                } catch {
                    Write-DashLog "Errore in /api/run-phase: $($_.Exception.Message)"
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($phaseBody | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $phaseStatus
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/force-rpz-update" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di aggiornamento forzato RPZ ricevuta dall'interfaccia Web."


                # [FIX] Start-ScheduledTask (modulo PowerShell ScheduledTasks) e' lo stesso
                # modulo gia' rivelatosi inaffidabile su questo tipo di macchina (vedi storico
                # in UnboundBunkerManager.BAT: Register-ScheduledTask abbandonato per errori
                # "Parametro non corretto" su qualunque principal/RunLevel). Si usa quindi
                # schtasks.exe direttamente, come gia' fatto nel BAT per la creazione dei task,
                # e si legge l'errorlevel/output reale invece di dare per scontato il successo
                # (prima con -ErrorAction SilentlyContinue un fallimento restava invisibile e
                # l'esito riportato era sempre "started").
                $rpzTasks = @("Unbound_Bunker_2h", "Unbound_Bunker_AbuseCh30m")
                $taskResults = @()
                $anyFailed = $false
                foreach ($rpzTask in $rpzTasks) {
                    try {
                        $out = & schtasks.exe /run /tn $rpzTask 2>&1 | Out-String
                        $ok  = ($LASTEXITCODE -eq 0)
                        if (-not $ok) { $anyFailed = $true }
                        $taskResults += "$rpzTask -> $(if ($ok) { 'OK' } else { "FALLITO (exit $LASTEXITCODE)" }): $($out.Trim())"
                    } catch {
                        $anyFailed = $true
                        $taskResults += "$rpzTask -> ECCEZIONE: $($_.Exception.Message)"
                    }
                }
                Write-DashLog ("Esito avvio task RPZ: " + ($taskResults -join " | "))
                if ($anyFailed -and (($taskResults -join " ") -match "(?i)access is denied|accesso negato|negata")) {
                    Write-DashLog "I task RPZ sono registrati per girare come SYSTEM: per avviarli manualmente il processo Dashboard deve essere lui stesso elevato (Amministratore/SYSTEM). Verificare con quale account/task e' partita l'istanza Dashboard attuale."
                }

                $esito  = if ($anyFailed) { "error" } else { "started" }
                $errMsg = if ($anyFailed) { ($taskResults -join " | ") } else { $null }

                $respObj = [ordered]@{ status = $esito }
                if ($errMsg) { $respObj.error = $errMsg }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                if ($esito -eq "error") { $response.StatusCode = 500 }
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/update-dashboard" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di auto-aggiornamento della dashboard ricevuta dall'interfaccia Web."

                $esito = "error"
                $errMsg = $null
                $needRestart = $false
                $targetScript = if ($script:CurrentScriptPath) { $script:CurrentScriptPath } else { Join-Path $UbDir "UnboundBunkerDashboard.ps1" }

                try {
                    $cloudUrl    = "https://raw.githubusercontent.com/UserH725/BiMaSoft/main/UnboundBunkerDashboard.ps1"
                    $cloudShaUrl = "https://raw.githubusercontent.com/UserH725/BiMaSoft/main/UnboundBunkerDashboard.sha256"
                    $tmpFile     = Join-Path $UbDir "UnboundBunkerDashboard_update.ps1.tmp"
                    $tmpSha      = Join-Path $UbDir "UnboundBunkerDashboard_update.sha256.tmp"
                    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $tmpSha  -Force -ErrorAction SilentlyContinue

                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                    $wc = New-Object System.Net.WebClient
                    $wc.DownloadFile($cloudUrl, $tmpFile)
                    $wc.DownloadFile($cloudShaUrl, $tmpSha)

                    if (-not (Test-Path -LiteralPath $tmpFile) -or -not (Test-Path -LiteralPath $tmpSha)) {
                        throw "Download del file o dell'hash SHA256 dal repository fallito."
                    }

                    $fileSize = (Get-Item -LiteralPath $tmpFile).Length
                    if ($fileSize -lt 20480) {
                        throw "File scaricato sospettosamente piccolo ($fileSize byte): aggiornamento annullato per sicurezza."
                    }

                    $expectedSha = ((Get-Content -LiteralPath $tmpSha -Raw) -split '\s+')[0].Trim()
                    $localSha    = (Get-FileHash -LiteralPath $tmpFile -Algorithm SHA256).Hash

                    if ($expectedSha -and $localSha -and ($localSha.ToUpper() -eq $expectedSha.ToUpper())) {
                        # Garantisce il BOM UTF-8 sul file installato, indipendentemente dal fatto
                        # che il file pubblicato sul repo GitHub lo contenga o meno (la verifica
                        # SHA256 sopra ha gia' controllato l'integrita' dei byte scaricati).
                        try {
                            $updBytes = [System.IO.File]::ReadAllBytes($tmpFile)
                            $updHasBom = ($updBytes.Length -ge 3) -and ($updBytes[0] -eq 0xEF) -and ($updBytes[1] -eq 0xBB) -and ($updBytes[2] -eq 0xBF)
                            if (-not $updHasBom) {
                                $updFixed = New-Object byte[] ($updBytes.Length + 3)
                                $updFixed[0] = 0xEF; $updFixed[1] = 0xBB; $updFixed[2] = 0xBF
                                [Array]::Copy($updBytes, 0, $updFixed, 3, $updBytes.Length)
                                [System.IO.File]::WriteAllBytes($tmpFile, $updFixed)
                                Write-DashLog "Auto-aggiornamento: BOM UTF-8 assente nel file scaricato dal repository, aggiunto prima dell'installazione."
                            }
                        } catch {
                            Write-DashLog "Impossibile verificare/riparare il BOM sul file di aggiornamento: $($_.Exception.Message)"
                        }

                        $stamp   = (Get-Date).ToString("yyyyMMdd_HHmmss")
                        $bakFile = Join-Path $UbDir "UnboundBunkerDashboard_$stamp.BKP"
                        Copy-Item -LiteralPath $targetScript -Destination $bakFile -Force
                        Move-Item -LiteralPath $tmpFile -Destination $targetScript -Force
                        Remove-Item -LiteralPath $tmpSha -Force -ErrorAction SilentlyContinue
                        Write-DashLog "Dashboard aggiornata dal repository GitHub. Backup salvato in: $bakFile"
                        $esito = "updated"
                        $needRestart = $true
                    } else {
                        throw "Verifica SHA256 fallita (atteso: $expectedSha, calcolato: $localSha): aggiornamento annullato per sicurezza."
                    }
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match '\(404\)') {
                        $errMsg = "$errMsg - il file non risulta ancora pubblicato sul repository all'URL atteso ($cloudUrl / $cloudShaUrl). Verifica che UnboundBunkerDashboard.ps1 e UnboundBunkerDashboard.sha256 siano presenti nel repo prima di riprovare."
                    }
                    Write-DashLog "Errore nell'auto-aggiornamento della dashboard: $errMsg"
                }

                $respObj = [ordered]@{ status = $esito }
                if ($errMsg) { $respObj.error = $errMsg }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                if ($esito -eq "error") { $response.StatusCode = 500 }
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer

                if ($needRestart) {
                    Close-HttpResponseSafe $response

                    $restartCmd = "Start-Sleep -Seconds 1; " +
                                  "Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue; " +
                                  "for (`$i=0; `$i -lt 20; `$i++) { " +
                                  "  `$conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue; " +
                                  "  if (-not `$conn) { break }; " +
                                  "  Start-Sleep -Milliseconds 500 " +
                                  "}; " +
                                  "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"$targetScript`"' -WindowStyle Hidden"
                    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$restartCmd`"" -WindowStyle Hidden
                    break
                }
            } elseif ($request.Url.AbsolutePath -eq "/api/dns-status") {
                $dnsStatus = Get-NicDnsStatus
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($dnsStatus | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/dns-toggle" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di toggle DNS scheda di rete ricevuta dall'interfaccia Web."
                $toggleResult = Invoke-NicDnsToggle
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($toggleResult | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                if ($toggleResult.status -eq "error") { $response.StatusCode = 500 }
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html") {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPage)
                $response.ContentType = "text/html; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } else {
                $response.StatusCode = 404
                $notFound = [System.Text.Encoding]::UTF8.GetBytes("Not found")
                Write-HttpResponseSafe $response $notFound
            }
        } catch {
            try {
                Write-DashLog "Errore durante la risposta HTTP: $($_.Exception.Message)"
                $errJson = [System.Text.Encoding]::UTF8.GetBytes('{"error":"internal_server_error"}')
                $response.StatusCode = 500
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $errJson.Length
                Write-HttpResponseSafe $response $errJson
            } catch {}
        } finally {
            try { Close-HttpResponseSafe $response } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    try { if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } } catch {}
}
}

# === ICONA SYSTEM TRAY (RUNSPACE STA SEPARATO) ===
function Start-TrayIcon {
    $trayRunspace = [runspacefactory]::CreateRunspace()
    $trayRunspace.ApartmentState = "STA" # Requisito fondamentale per Windows Forms / NotifyIcon
    $trayRunspace.ThreadOptions  = "ReuseThread"
    $trayRunspace.Open()

    # Passiamo l'URL della dashboard al Runspace
    $trayRunspace.SessionStateProxy.SetVariable('Prefix', $Prefix)
    
    $trayPowerShell = [powershell]::Create()
    $trayPowerShell.Runspace = $trayRunspace
    [void]$trayPowerShell.AddScript({
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $TrayIcon = New-Object System.Windows.Forms.NotifyIcon
        $TrayIcon.Text = "UNBOUND BUNKER`nProtezione Attiva - Clicca per aprire"
        
        # Stringa Base64 compatta di un'icona .ico (Scudo Verde di Sicurezza)
        $iconBase64 = "AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAQAABILAAATCwAAAAAAAAAAAAD/
        //8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A
        ////AP///wD///8A/wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP///wD///8A
        ////AP///wD/AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA////AP///wD///8A
        ////AP8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD///8A////AP///wD///8A
        /wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP///wD///8A////AP///wD/AAD/
        /wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD//wAA////AP///wD///8A////AP8AAP//AAD/
        /wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP//AAD///8A////AP///wD///8A/wAA//8AAP//AAD/
        /wAA//8AAP//AAD//wAA//8AAP//AAD//wAA//8AAP///wD///8A////AP///wD/AAD//wAA//8AAP//AAD/
        /wAA//8AAP//AAD//wAA//8AAP//AAD//wAA////AP///wD///8A////AP8AAP//AAD//wAA//8AAP//AAD/
        /wAA//8AAP//AAD//wAA//8AAP//AAD///8A////AP///wD///8A/wAA//8AAP//AAD//wAA//8AAP//AAD/
        /wAA//8AAP//AAD//wAA//8AAP///wD///8A////AP///wD///8A/wAA//8AAP//AAD//wAA//8AAP//AAD/
        /wAA//8AAP//AAD///8A////AP///wD///8A////AP///wD///8A/wAA//8AAP//AAD//wAA//8AAP//AAD/
        /wAA////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP8AAP//AAD//wAA//8AAP///wD/
        //8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD/AAD///8A////AP///wD/
        //8A////AP///wD///8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAA=="
        
        try {
            $iconBytes = [Convert]::FromBase64String(($iconBase64 -replace "\s", ""))
            $ms = New-Object System.IO.MemoryStream($iconBytes, 0, $iconBytes.Length)
            $TrayIcon.Icon = New-Object System.Drawing.Icon($ms)
            $ms.Dispose()
        } catch {
            # Fallback di sicurezza: se la stringa Base64 è corrotta, usa lo scudo di sistema
            $TrayIcon.Icon = [System.Drawing.SystemIcons]::Shield
        }

        # --- Menu Interattivo (Tasto Destro) ---
        $Menu = New-Object System.Windows.Forms.ContextMenu
        
        $MenuItemOpen = New-Object System.Windows.Forms.MenuItem("Apri Dashboard Live")
        $MenuItemOpen.DefaultItem = $true
        $MenuItemOpen.add_Click({ [System.Diagnostics.Process]::Start($Prefix) })
        
        $MenuItemRestart = New-Object System.Windows.Forms.MenuItem("Riavvia Motore Unbound")
        $MenuItemRestart.add_Click({
            try { Invoke-RestMethod -Uri "${Prefix}api/restart-unbound" -Method Post -TimeoutSec 2 } catch {}
        })

        $MenuItemExit = New-Object System.Windows.Forms.MenuItem("Nascondi Icona")
        $MenuItemExit.add_Click({ 
            $TrayIcon.Visible = $false
            [System.Windows.Forms.Application]::ExitThread()
        })
        
        $Menu.MenuItems.Add($MenuItemOpen)
        $Menu.MenuItems.Add("-")
        $Menu.MenuItems.Add($MenuItemRestart)
        $Menu.MenuItems.Add("-")
        $Menu.MenuItems.Add($MenuItemExit)
        
        $TrayIcon.ContextMenu = $Menu

        # Doppio click per aprire la dashboard
        $TrayIcon.add_DoubleClick({
            [System.Diagnostics.Process]::Start($Prefix)
        })

        # Pulizia in caso di chiusura del processo main
        $appDomain = [System.AppDomain]::CurrentDomain
        Register-ObjectEvent -InputObject $appDomain -EventName ProcessExit -Action {
            $TrayIcon.Visible = $false
            $TrayIcon.Dispose()
        } | Out-Null

        $TrayIcon.Visible = $true
        [System.Windows.Forms.Application]::Run()
    })

    $script:TrayHandle = $trayPowerShell.BeginInvoke()
    Write-DashLog "Runspace Tray Icon avviato (Scudo Verde)."
}


# === AVVIO ===
if ($script:IsBackgroundCollector) {
    Start-BackgroundCollectorLoop
} else {
    Start-DashboardServer
}
