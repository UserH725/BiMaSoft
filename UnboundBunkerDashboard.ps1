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

# Banda in tempo reale: differenza dei contatori byte delle schede fisiche attive tra due letture.
# Niente WMI/CIM (leggero anche a 1 letture/s), somma di tutte le schede reali (Ethernet + Wi-Fi) ed
# esclusione di quelle virtuali/VPN per non contare due volte lo stesso traffico. Valori in Mbps (1 Mbps = 1.000.000 bit/s).
$script:NetSw     = [System.Diagnostics.Stopwatch]::StartNew()
$script:NetPrev   = @{}
$script:NetPrevMs = $null
$script:NetLast   = @{ down_mbps = 0; up_mbps = 0; ok = $false }

function Get-NetworkSpeed {
    try {
        $nowMs = $script:NetSw.ElapsedMilliseconds
        # Chiamate ravvicinate (< 0,4 s): restituisce l'ultimo valore, il calcolo su un intervallo troppo corto sarebbe rumore
        if ($null -ne $script:NetPrevMs -and ($nowMs - $script:NetPrevMs) -lt 400) { return $script:NetLast }

        $cur = @{}
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus.ToString() -ne 'Up') { continue }
            $nt = $nic.NetworkInterfaceType.ToString()
            if ($nt -eq 'Loopback' -or $nt -eq 'Tunnel') { continue }
            if (($nic.Name + ' ' + $nic.Description) -match 'Virtual|vEthernet|VPN|Hyper-V|VMware|VirtualBox|Bluetooth|Pseudo|TAP-Windows|Wintun|WireGuard|Teredo|ISATAP|Loopback') { continue }
            $st = $nic.GetIPStatistics()
            $cur[$nic.Id] = @{ rx = [int64]$st.BytesReceived; tx = [int64]$st.BytesSent }
        }

        if ($null -eq $script:NetPrevMs) {
            $script:NetPrev   = $cur
            $script:NetPrevMs = $nowMs
            $script:NetLast   = @{ down_mbps = 0; up_mbps = 0; ok = ($cur.Count -gt 0) }
            return $script:NetLast
        }

        $dtSec = ($nowMs - $script:NetPrevMs) / 1000.0
        $rxD = [int64]0; $txD = [int64]0
        foreach ($k in $cur.Keys) {
            if ($script:NetPrev.ContainsKey($k)) {
                $d1 = $cur[$k].rx - $script:NetPrev[$k].rx
                $d2 = $cur[$k].tx - $script:NetPrev[$k].tx
                if ($d1 -gt 0) { $rxD += $d1 }
                if ($d2 -gt 0) { $txD += $d2 }
            }
        }
        $script:NetPrev   = $cur
        $script:NetPrevMs = $nowMs

        if ($cur.Count -eq 0 -or $dtSec -le 0) {
            $script:NetLast = @{ down_mbps = 0; up_mbps = 0; ok = $false }
        } else {
            $script:NetLast = @{
                down_mbps = [math]::Round(($rxD * 8) / $dtSec / 1000000, 1)
                up_mbps   = [math]::Round(($txD * 8) / $dtSec / 1000000, 1)
                ok        = $true
            }
        }
        return $script:NetLast
    } catch {}
    return @{ down_mbps = 0; up_mbps = 0; ok = $false }
}

# === POTENZIALE LINEA (v1106.3: test di velocita' reale abbinato al task Unbound_Bunker_AbuseCh30m) ===
#
# Il PC non conosce la capacita' della fibra: vede solo la scheda verso il router. Il "potenziale" e'
# quindi MISURATO: a fine esecuzione del task AbuseCh30m (transizione In esecuzione -> Inattivo) la
# Dashboard lancia in un runspace separato un test con 4 flussi curl.exe paralleli verso Cloudflare
# (prima il download, poi l'upload, mai insieme), ciascuno limitato a $script:LpTestSecs secondi.
# Il test parte solo se l'ultima misura ha piu' di $script:LpMinAgeMin minuti: con AbuseCh30m ogni 30
# minuti significa un test ogni 4 giri (circa 2 ore). Risultato in R:\line_potential.json (volatile
# come il resto di R:). Un lock su file (R:\line_test.run, creazione esclusiva) impedisce che due
# runspace della Dashboard (collector background + thread HTTP) lancino due test insieme.
# Finche' non c'e' la prima misura si mostra, come ripiego, la velocita' di collegamento della scheda.
$script:LpFile        = "R:\line_potential.json"
$script:LpLockFile    = "R:\line_test.run"
$script:LpTaskName    = 'Unbound_Bunker_AbuseCh30m'
$script:LpMinAgeMin   = 105
$script:LpTestSecs    = 6
$script:LpPrevRunning = $null
$script:LpAsync       = $null
$script:LpCache       = $null
$script:LpCacheTime   = [DateTime]::MinValue
$script:LpCheckTime   = [DateTime]::MinValue

function Get-NicLinkMbps {
    $best = 0.0
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus.ToString() -ne 'Up') { continue }
            $nt = $nic.NetworkInterfaceType.ToString()
            if ($nt -eq 'Loopback' -or $nt -eq 'Tunnel') { continue }
            if (($nic.Name + ' ' + $nic.Description) -match 'Virtual|vEthernet|VPN|Hyper-V|VMware|VirtualBox|Bluetooth|Pseudo|TAP-Windows|Wintun|WireGuard|Teredo|ISATAP|Loopback') { continue }
            if ([double]$nic.Speed -le 0 -or [double]$nic.Speed -eq 4294967295) { continue }
            $mb = [math]::Round([double]$nic.Speed / 1000000, 0)
            if ($mb -gt 400000) { continue }
            if ($mb -gt $best) { $best = $mb }
        }
    } catch {}
    return $best
}

function Start-LineSpeedTest {
    # Restituisce 'started' | 'busy' (test gia' in corso) | 'error'. DelaySec = pausa prima di misurare:
    # 20 s dopo il task AbuseCh30m (Unbound sta ricaricando le RPZ), 0 per la misura forzata dal pulsante.
    param([int]$DelaySec = 20)
    $old = $script:LpAsync
    if ($old -and $old.Handle.IsCompleted) {
        try { [void]$old.Ps.EndInvoke($old.Handle) } catch {}
        try { $old.Ps.Dispose() } catch {}
        $script:LpAsync = $null
    }
    # Lock esclusivo: CreateNew fallisce se il file esiste gia' (test in corso in un altro runspace)
    try {
        if (Test-Path -LiteralPath $script:LpLockFile) {
            $lockAge = ((Get-Date) - (Get-Item -LiteralPath $script:LpLockFile).LastWriteTime).TotalSeconds
            if ($lockAge -lt 180) { return 'busy' }
            Remove-Item -LiteralPath $script:LpLockFile -Force -ErrorAction SilentlyContinue
        }
        $fs = [System.IO.File]::Open($script:LpLockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Close()
    } catch { return 'busy' }

    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($OutFile, $LockFile, $Secs, $Delay)
            $ProgressPreference = 'SilentlyContinue'
            $tmpUp = $null
            $lpLog = 'R:\line_test.log'
            $lpW = { param($m) try { ('[' + (Get-Date).ToString('dd.MM.yyyy HH:mm:ss') + '] ' + $m) | Out-File -LiteralPath $lpLog -Append -Encoding utf8 } catch {} }
            try {
                & $lpW ('Avvio test linea (flussi=4, secondi=' + $Secs + ', ritardo=' + $Delay + ')')
                # Pausa iniziale: il task AbuseCh30m riavvia Unbound per ricaricare le RPZ e il DNS
                # potrebbe non essere ancora pronto appena il task risulta terminato.
                if ($Delay -gt 0) { Start-Sleep -Seconds $Delay }
                $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
                if (-not (Test-Path -LiteralPath $curl)) { & $lpW ('curl.exe non trovato in ' + $curl); return }
                $inv = [System.Globalization.CultureInfo]::InvariantCulture
                $flows = 4

                $runFlows = {
                    param($argLine, $n)
                    $procs = @()
                    for ($i = 0; $i -lt $n; $i++) {
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName               = $curl
                        $psi.Arguments              = $argLine
                        $psi.UseShellExecute        = $false
                        $psi.CreateNoWindow         = $true
                        $psi.RedirectStandardOutput = $true
                        $psi.RedirectStandardError  = $true
                        $procs += [System.Diagnostics.Process]::Start($psi)
                    }
                    $sum = 0.0
                    foreach ($pr in $procs) {
                        $errTask = $pr.StandardError.ReadToEndAsync()
                        $txt = $pr.StandardOutput.ReadToEnd()
                        [void]$pr.WaitForExit(15000)
                        $v = 0.0
                        $spdTxt = ($txt.Trim() -split '\|')[0].Replace(',', '.')
                        $okParse = [double]::TryParse($spdTxt, [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)
                        $httpCode = ''; $parts = $txt.Trim() -split '\|'; if ($parts.Count -gt 1) { $httpCode = $parts[1].Trim() }
                        if ($okParse -and $httpCode -match '^2\d\d$') { $sum += $v }
                        $ec = ''; try { $ec = [string]$pr.ExitCode } catch {}
                        $er = ''; try { $er = ([string]$errTask.Result).Trim() } catch {}
                        & $lpW ('  flusso: out=[' + $txt.Trim() + '] exit=' + $ec + $(if ($er) { ' err=[' + $er + ']' } else { '' }))
                        $pr.Dispose()
                    }
                    return $sum
                }

                # Download: prova in ordine piu' sorgenti, si ferma alla prima che produce una velocita' > 0
                $dlUrls = @(
                    'https://speed.cloudflare.com/__down?bytes=100000000',
                    'https://proof.ovh.net/files/100Mb.dat',
                    'https://speedtest.tele2.net/100MB.zip'
                )
                $dl = 0.0
                foreach ($u in $dlUrls) {
                    $argDown = '-s -L -A "Mozilla/5.0" -o NUL -w "%{speed_download}|%{http_code}" --max-time ' + $Secs + ' --connect-timeout 5 "' + $u + '"'
                    & $lpW ('Download da ' + $u)
                    $dl = & $runFlows $argDown $flows
                    if ($dl -gt 0) { break }
                }
                & $lpW ('Download totale (byte/s): ' + $dl)

                $tmpUp = Join-Path $env:TEMP 'ub_line_up.bin'
                $buf = New-Object byte[] 26214400
                (New-Object System.Random).NextBytes($buf)
                [System.IO.File]::WriteAllBytes($tmpUp, $buf)
                $argUp = '-s -L -A "Mozilla/5.0" -o NUL -w "%{speed_upload}|%{http_code}" --max-time ' + $Secs + ' --connect-timeout 5 -X POST -H "Content-Type: application/octet-stream" --data-binary "@' + $tmpUp + '" "https://speed.cloudflare.com/__up"'
                & $lpW 'Upload...'
                $ul = & $runFlows $argUp $flows
                & $lpW ('Upload totale (byte/s): ' + $ul)

                # Somma delle velocita' medie dei 4 flussi, in Mbps (bit/s / 1.000.000). Si salva solo
                # se entrambe le direzioni hanno prodotto un valore: altrimenti resta l'ultima misura.
                if ($dl -gt 0 -or $ul -gt 0) {
                    $pd = 0.0; $pu = 0.0
                    if (Test-Path -LiteralPath $OutFile) {
                        try { $pj = Get-Content -LiteralPath $OutFile -Raw -ErrorAction Stop | ConvertFrom-Json; $pd = [double]$pj.down_mbps; $pu = [double]$pj.up_mbps } catch {}
                    }
                    $nd = if ($dl -gt 0) { [math]::Round($dl * 8 / 1000000, 1) } else { $pd }
                    $nu = if ($ul -gt 0) { [math]::Round($ul * 8 / 1000000, 1) } else { $pu }
                    $o = [ordered]@{
                        down_mbps = $nd
                        up_mbps   = $nu
                        ts        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    }
                    $tmpJson = $OutFile + '.tmp'
                    [System.IO.File]::WriteAllText($tmpJson, ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
                    Move-Item -LiteralPath $tmpJson -Destination $OutFile -Force
                    & $lpW ('Misura salvata: down=' + $nd + ' Mbps, up=' + $nu + ' Mbps')
                } else {
                    & $lpW 'Nessuna velocita valida misurata (download e upload a 0): misura NON salvata, resta il ripiego scheda.'
                }
            } catch {
                & $lpW ('ERRORE test linea: ' + $_.Exception.Message)
            } finally {
                if ($tmpUp) { Remove-Item -LiteralPath $tmpUp -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            }
        }).AddArgument($script:LpFile).AddArgument($script:LpLockFile).AddArgument($script:LpTestSecs).AddArgument($DelaySec)
        $script:LpAsync = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
        return 'started'
    } catch {
        Remove-Item -LiteralPath $script:LpLockFile -Force -ErrorAction SilentlyContinue
        return 'error'
    }
}

function Get-LinePotential {
    try {
        $now = Get-Date

        # Pulizia del runspace del test concluso
        $a = $script:LpAsync
        if ($a -and $a.Handle.IsCompleted) {
            try { [void]$a.Ps.EndInvoke($a.Handle) } catch {}
            try { $a.Ps.Dispose() } catch {}
            $script:LpAsync     = $null
            $script:LpCacheTime = [DateTime]::MinValue
        }

        # Rilevamento della fine del task AbuseCh30m (controllo al massimo ogni 3 s)
        if (($now - $script:LpCheckTime).TotalSeconds -ge 3) {
            $script:LpCheckTime = $now
            $live    = Get-BunkerTasksLiveState
            $running = [bool]($live.ContainsKey($script:LpTaskName) -and $live[$script:LpTaskName])
            if ($script:LpPrevRunning -eq $true -and -not $running -and -not $script:LpAsync) {
                $ageMin = 99999.0
                if (Test-Path -LiteralPath $script:LpFile) {
                    $ageMin = ($now - (Get-Item -LiteralPath $script:LpFile).LastWriteTime).TotalMinutes
                }
                if ($ageMin -ge $script:LpMinAgeMin) { [void](Start-LineSpeedTest) }
            }
            $script:LpPrevRunning = $running
        }

        if ($script:LpCache -and ($now - $script:LpCacheTime).TotalSeconds -lt 5) { return $script:LpCache }

        $inCorso = [bool](Test-Path -LiteralPath $script:LpLockFile)
        $res = $null
        if (Test-Path -LiteralPath $script:LpFile) {
            try {
                $j = Get-Content -LiteralPath $script:LpFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ([double]$j.down_mbps -gt 0 -or [double]$j.up_mbps -gt 0) {
                    $quando = ([datetime]$j.ts).ToString('HH:mm')
                    $testo  = 'misurato alle ' + $quando
                    if ($inCorso) { $testo += ' · test in corso' }
                    $res = @{ ok = $true; down_mbps = [double]$j.down_mbps; up_mbps = [double]$j.up_mbps; fonte = 'misura'; testo = $testo; in_corso = $inCorso }
                }
            } catch {}
        }
        if (-not $res) {
            $nicMbps = Get-NicLinkMbps
            if ($nicMbps -gt 0) {
                $testo = if ($inCorso) { 'solo velocità scheda di rete (non è la linea) · test in corso' } else { 'solo velocità scheda di rete (non è la linea) · nessuna misura valida' }
                $res = @{ ok = $true; down_mbps = $nicMbps; up_mbps = $nicMbps; fonte = 'scheda'; testo = $testo; in_corso = $inCorso }
            } else {
                $res = @{ ok = $false; down_mbps = 0; up_mbps = 0; fonte = ''; testo = ''; in_corso = $inCorso }
            }
        }
        $script:LpCache     = $res
        $script:LpCacheTime = $now
        return $res
    } catch {}
    return @{ ok = $false; down_mbps = 0; up_mbps = 0; fonte = ''; testo = ''; in_corso = $false }
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

# === CARICO DEL PC (RAM + CPU) PER IL TITOLO DELLA SCHEDA PRO ===
# Raccolto solo nel JSON completo (Pro): la Light non lo usa e non ne paga il costo.
# CPU: contatore prestazioni aperto una sola volta (leggero) + media mobile degli ultimi 3 campioni
# (circa 5 s) per evitare pallini che lampeggiano sui picchi brevi.
# RAM: memoria fisica usata / totale dell'intero PC.
$script:SysLoadCounter    = $null
$script:SysLoadCpuSamples = New-Object System.Collections.Generic.List[double]
$script:SysLoadLast       = $null
$script:SysLoadLastTime   = [DateTime]::MinValue

function Get-SystemLoad {
    if ($script:SysLoadLast -and ((Get-Date) - $script:SysLoadLastTime).TotalMilliseconds -lt 1000) { return $script:SysLoadLast }
    $ramPct = $null; $ramUsedMb = 0; $ramTotMb = 0; $cpuPct = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.TotalVisibleMemorySize -gt 0) {
            $usedKb    = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
            $ramTotMb  = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
            $ramUsedMb = [math]::Round($usedKb / 1024, 0)
            $ramPct    = [math]::Round(($usedKb / $os.TotalVisibleMemorySize) * 100, 0)
        }
    } catch {}
    try {
        if (-not $script:SysLoadCounter) {
            $script:SysLoadCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
            [void]$script:SysLoadCounter.NextValue()   # il primo campione e' sempre 0: scartato
        } else {
            $v = [double]$script:SysLoadCounter.NextValue()
            [void]$script:SysLoadCpuSamples.Add([math]::Min(100, [math]::Max(0, $v)))
            while ($script:SysLoadCpuSamples.Count -gt 3) { $script:SysLoadCpuSamples.RemoveAt(0) }
        }
        if ($script:SysLoadCpuSamples.Count -gt 0) {
            $cpuPct = [math]::Round(($script:SysLoadCpuSamples | Measure-Object -Average).Average, 0)
        }
    } catch { $script:SysLoadCounter = $null }
    $script:SysLoadLast = @{ ram_pct = $ramPct; ram_used_mb = $ramUsedMb; ram_tot_mb = $ramTotMb; cpu_pct = $cpuPct }
    $script:SysLoadLastTime = Get-Date
    return $script:SysLoadLast
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
# Le richieste web verso i servizi di geolocalizzazione girano in un runspace separato (NON bloccante):
# eseguite nel ciclo di raccolta (1 s nella Light) a linea assente lo avrebbero bloccato fino a 4 s ad ogni giro.
# Aggiornamento ogni 60 s a linea ok, ogni 10 s finche' l'IP pubblico non e' disponibile.
$script:WanCacheTime = [DateTime]::MinValue
$script:WanCacheData = @{
    ipv4_wan    = "N/D"
    ipv4_wan_ok = $false
    ipv4_loc    = ""
    ipv6_wan    = "N/D"
    ipv6_wan_ok = $false
    ipv6_loc    = ""
}
$script:WanAsync     = $null
$script:WanFailCount = 0
$script:LanCacheTime = [DateTime]::MinValue
$script:LanCacheData = $null

function Start-WanRefreshAsync {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        $ProgressPreference = 'SilentlyContinue'
        $ip4Wan = "N/D"; $loc4 = ""
        $ip6Wan = "N/D"; $loc6 = ""

        try {
            $r4 = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,city,country,isp,query' -TimeoutSec 3 -ErrorAction Stop
            if ($r4.status -eq 'success') {
                $ip4Wan = $r4.query
                $city4  = if ($r4.city) { $r4.city } else { $r4.isp }
                $loc4   = @($city4, $r4.country) -join ', '
            }
        } catch {
            try {
                $r4 = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 3 -ErrorAction Stop
                if ($r4.ip) {
                    $ip4Wan = $r4.ip
                    $loc4   = @($r4.city, $r4.country) -join ', '
                }
            } catch {}
        }

        try {
            $r6 = Invoke-RestMethod -Uri 'https://ipapi.co/json/' -TimeoutSec 3 -ErrorAction Stop
            if ($r6.ip -match ':') {
                $ip6Wan = $r6.ip
                $city6  = if ($r6.city) { $r6.city } else { $r6.org }
                $loc6   = @($city6, $r6.country_code) -join ', '
            }
        } catch {
            try {
                $raw6 = (Invoke-WebRequest -Uri 'https://ipv6.icanhazip.com' -TimeoutSec 3 -UseBasicParsing).Content.Trim()
                if ($raw6 -match ':') {
                    $ip6Wan = $raw6
                    $loc6   = "Cloudflare WARP"
                }
            } catch {}
        }

        [pscustomobject]@{ ip4 = $ip4Wan; loc4 = $loc4; ip6 = $ip6Wan; loc6 = $loc6 }
    })
    $script:WanAsync = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date) }
}

function Update-WanCacheState {
    $a = $script:WanAsync
    if ($a) {
        if ($a.Handle.IsCompleted) {
            $res = $null
            try { $res = @($a.Ps.EndInvoke($a.Handle))[0] } catch {}
            try { $a.Ps.Dispose() } catch {}
            $script:WanAsync = $null
            if ($res -and ($res.ip4 -ne "N/D" -or $res.ip6 -ne "N/D")) {
                $script:WanFailCount = 0
                $script:WanCacheData = @{
                    ipv4_wan    = $res.ip4
                    ipv4_wan_ok = ($res.ip4 -ne "N/D")
                    ipv4_loc    = $res.loc4
                    ipv6_wan    = $res.ip6
                    ipv6_wan_ok = ($res.ip6 -ne "N/D")
                    ipv6_loc    = $res.loc6
                }
            } else {
                # Un solo giro a vuoto puo' essere un timeout isolato: si tiene l'ultimo valore; al secondo consecutivo si passa a N/D
                $script:WanFailCount++
                if ($script:WanFailCount -ge 2) {
                    $script:WanCacheData = @{
                        ipv4_wan = "N/D"; ipv4_wan_ok = $false; ipv4_loc = ""
                        ipv6_wan = "N/D"; ipv6_wan_ok = $false; ipv6_loc = ""
                    }
                }
            }
            $script:WanCacheTime = Get-Date
        }
        elseif (((Get-Date) - $a.Started).TotalSeconds -gt 20) {
            # Richiesta rimasta appesa: la si abbandona e si riprova al prossimo turno
            try { [void]$a.Ps.BeginStop($null, $null) } catch {}
            $script:WanAsync = $null
            $script:WanCacheTime = Get-Date
        }
        return
    }
    $everyS = if ($script:WanCacheData.ipv4_wan_ok -or $script:WanCacheData.ipv6_wan_ok) { 60 } else { 10 }
    if (((Get-Date) - $script:WanCacheTime).TotalSeconds -ge $everyS) {
        try { Start-WanRefreshAsync } catch { $script:WanCacheTime = Get-Date }
    }
}

function Get-IpConnectivityStatus {
    # Indirizzi locali riletti al massimo ogni 5 s (Get-NetIPAddress e' relativamente pesante e qui si chiama a ogni giro)
    if (-not $script:LanCacheData -or ((Get-Date) - $script:LanCacheTime).TotalSeconds -ge 5) {
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

        $script:LanCacheData = @{ ip4 = @($ip4LanList); ip6 = @($ip6LanList) }
        $script:LanCacheTime = Get-Date
    }
    $ip4LanList = @($script:LanCacheData.ip4)
    $ip6LanList = @($script:LanCacheData.ip6)

    try { Update-WanCacheState } catch {}

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
    $rpzAct = 0
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
                    if ($k -eq "total.num.prefetch" -or $k -eq "num.prefetch" -or $k -eq "num.query.prefetch") { $prefetch = $v }
                    if ($k -like "num.rpz.action.*")         { $rpzAct += $v }
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
            $base.rpz_azioni = $rpzAct   # risposte date dalle RPZ: Unbound le conta come cache hit
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

# === STORICO PAGINA LIGHT (dall'accensione) ===
# I due punteggi (Funzionamento Bunker, Miglioramento PC) sono calcolati dalla pagina Light e
# inviati qui con POST /api/light-sample: la fonte dei valori e' quindi SEMPRE la stessa delle
# lancette (nessuna formula duplicata lato server). Il buffer e' limitato a $LightHistMaxPts
# punti: al raggiungimento del limite le coppie adiacenti vengono fuse (media) e l'intervallo
# minimo tra due campioni raddoppia, cosi' lo storico copre TUTTA l'accensione con memoria
# costante. Salvataggio su R:\light_history.json (RAM disk volatile: sopravvive al riavvio
# della dashboard, si azzera allo spegnimento del PC). Unico scrittore: il thread HTTP.
# Passo base 1 s (v1106.1; dalla v1106.2 il grafico usa il buffer recente, vedi sotto): la pagina Light fa scorrere il grafico in continuo tra un campione
# e il successivo; con la fusione a coppie il passo diventa 1, 2, 4, 8... s (sempre potenza di 2).
$script:LightHistFile       = "R:\light_history.json"
$script:LightHistPts        = $null
$script:LightHistJson       = $null
$script:LightHistInterval   = 1
$script:LightHistMaxPts     = 1500
$script:LightHistStartMs    = 0.0
$script:LightHistLastSample = [DateTime]::MinValue
$script:LightHistLastSave   = [DateTime]::MinValue

function Build-LightHistoryJson {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"start":').Append($script:LightHistStartMs.ToString('0', $inv))
    [void]$sb.Append(',"interval":').Append([string]$script:LightHistInterval).Append(',"p":[')
    $n = $script:LightHistPts.Count
    for ($i = 0; $i -lt $n; $i++) {
        $pt = $script:LightHistPts[$i]
        if ($i -gt 0) { [void]$sb.Append(',') }
        [void]$sb.Append('[').Append($pt[0].ToString('0', $inv)).Append(',').Append($pt[1].ToString('0.####', $inv)).Append(',').Append($pt[2].ToString('0.####', $inv)).Append(']')
    }
    [void]$sb.Append(']}')
    $script:LightHistJson = $sb.ToString()
}

function Initialize-LightHistory {
    if ($null -ne $script:LightHistPts) { return }
    $script:LightHistPts     = New-Object System.Collections.Generic.List[double[]]
    $script:LightHistStartMs = [double]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
    try {
        if ([System.IO.File]::Exists($script:LightHistFile)) {
            $saved = [System.IO.File]::ReadAllText($script:LightHistFile) | ConvertFrom-Json
            # Con passo base 1 s gli intervalli validi sono potenze di 2 (1, 2, 4...). Un file salvato dal
            # vecchio passo base 5 s (5, 10, 20...) non lo e': si scarta e lo storico riparte pulito.
            $savedInt = 0
            if ($saved -and $saved.interval) { $savedInt = [int]$saved.interval }
            if ($saved -and $saved.p -and $savedInt -ge 1 -and (($savedInt -band ($savedInt - 1)) -eq 0)) {
                foreach ($row in $saved.p) {
                    [void]$script:LightHistPts.Add([double[]]@([double]$row[0], [double]$row[1], [double]$row[2]))
                }
                $script:LightHistInterval = $savedInt
                if ($saved.start)    { $script:LightHistStartMs  = [double]$saved.start }
            }
        }
    } catch {
        $script:LightHistPts.Clear()
        $script:LightHistInterval = 1
    }
    $script:LightHistJson = $null
}

function Get-LightHistoryJson {
    Initialize-LightHistory
    # JSON dello storico completo costruito solo quando serve (la pagina Light usa la finestra recente)
    if (-not $script:LightHistJson) { Build-LightHistoryJson }
    return $script:LightHistJson
}

# --- Finestra recente (v1106.2) ---
# Buffer a parte con UN campione al secondo (mai fuso): e' quello che disegna il grafico scorrevole
# della pagina Light (5 min / 10 min / 1 h). Lo storico completo sopra continua a esistere ma, fondendo
# le coppie, il passo diventa 2 s, 4 s, 8 s...: non adatto a un grafico che deve scorrere in modo fluido.
# Massimo $LightRecentMax campioni (~1 h): memoria costante. Salvataggio su R:\light_recent.json ogni 60 s.
$script:LightRecentFile       = "R:\light_recent.json"
$script:LightRecentPts        = $null
$script:LightRecentMax        = 3700
$script:LightRecentLastSample = [DateTime]::MinValue
$script:LightRecentLastSave   = [DateTime]::MinValue
$script:LightRecentCache      = @{}

function Initialize-LightRecent {
    if ($null -ne $script:LightRecentPts) { return }
    $script:LightRecentPts = New-Object System.Collections.Generic.List[double[]]
    try {
        if ([System.IO.File]::Exists($script:LightRecentFile)) {
            $saved = [System.IO.File]::ReadAllText($script:LightRecentFile) | ConvertFrom-Json
            $cut = [double]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds() - 3700000
            if ($saved -and $saved.p) {
                foreach ($row in $saved.p) {
                    if ([double]$row[0] -ge $cut) {
                        [void]$script:LightRecentPts.Add([double[]]@([double]$row[0], [double]$row[1], [double]$row[2]))
                    }
                }
            }
        }
    } catch {
        $script:LightRecentPts.Clear()
    }
}

function ConvertTo-LightRecentJson {
    param([int]$WinSec, [switch]$Full)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $pts = $script:LightRecentPts
    $n = $pts.Count
    $lastMs = 0.0
    if ($n -gt 0) { $lastMs = $pts[$n - 1][0] }
    # si parte da un paio di secondi PRIMA dell'inizio finestra: la linea entra nel riquadro senza buco a sinistra
    $from = $lastMs - ($WinSec * 1000.0) - 3000.0
    if ($Full) { $from = 0.0 }
    $i0 = $n
    for ($i = $n - 1; $i -ge 0; $i--) { if ($pts[$i][0] -lt $from) { break }; $i0 = $i }
    # sulla finestra da 1 h gli ultimi 5 minuti restano a 1 s e il resto a 1 ogni 5 s (campione = primo di
    # ogni intervallo di 5 s: scelta legata al tempo, quindi stabile mentre la finestra scorre)
    $decim = ((-not $Full) -and $WinSec -gt 600)
    $recentCut = $lastMs - 300000.0
    $lastBucket = -1.0
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"start":').Append($script:LightHistStartMs.ToString('0', $inv))
    [void]$sb.Append(',"interval":1,"win":').Append([string]$WinSec).Append(',"p":[')
    $first = $true
    for ($i = $i0; $i -lt $n; $i++) {
        $pt = $pts[$i]
        if ($decim -and $pt[0] -lt $recentCut) {
            $bk = [math]::Floor($pt[0] / 5000.0)
            if ($bk -eq $lastBucket) { continue }
            $lastBucket = $bk
        }
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        [void]$sb.Append('[').Append($pt[0].ToString('0', $inv)).Append(',').Append($pt[1].ToString('0.###', $inv)).Append(',').Append($pt[2].ToString('0.###', $inv)).Append(']')
    }
    [void]$sb.Append(']}')
    return $sb.ToString()
}

function Get-LightRecentJson {
    param([int]$WinSec)
    Initialize-LightRecent
    if ($WinSec -ne 300 -and $WinSec -ne 600 -and $WinSec -ne 3600) { $WinSec = 600 }
    $n = $script:LightRecentPts.Count
    $lastMs = 0.0
    if ($n -gt 0) { $lastMs = $script:LightRecentPts[$n - 1][0] }
    $c = $script:LightRecentCache[$WinSec]
    if ($c -and $c.last -eq $lastMs -and $c.n -eq $n) { return $c.json }
    $json = ConvertTo-LightRecentJson -WinSec $WinSec
    $script:LightRecentCache[$WinSec] = @{ last = $lastMs; n = $n; json = $json }
    return $json
}

function Add-LightRecentPoint {
    param([double]$Boost, [double]$Gain)
    Initialize-LightRecent
    $now = Get-Date
    if (($now - $script:LightRecentLastSample).TotalSeconds -lt 0.85) { return }
    $script:LightRecentLastSample = $now
    $nowMs = [double]([DateTimeOffset]$now).ToUnixTimeMilliseconds()
    [void]$script:LightRecentPts.Add([double[]]@($nowMs, [math]::Round($Boost, 3), [math]::Round($Gain, 3)))
    $over = $script:LightRecentPts.Count - $script:LightRecentMax
    if ($over -gt 0) { $script:LightRecentPts.RemoveRange(0, $over) }
    if (($now - $script:LightRecentLastSave).TotalSeconds -ge 60) {
        $script:LightRecentLastSave = $now
        try {
            $tmp = "$($script:LightRecentFile).tmp"
            [System.IO.File]::WriteAllText($tmp, (ConvertTo-LightRecentJson -WinSec 3600 -Full), (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $script:LightRecentFile -Force
        } catch {}
    }
}

function Add-LightHistoryPoint {
    param([double]$Boost, [double]$Gain)
    Initialize-LightHistory
    Add-LightRecentPoint -Boost $Boost -Gain $Gain

    $now = Get-Date
    # tolleranza 15%: i POST arrivano ogni ~1 s con un po' di jitter, senza margine ogni tanto se ne perderebbe uno
    if (($now - $script:LightHistLastSample).TotalSeconds -lt ($script:LightHistInterval * 0.85)) { return $false }
    $script:LightHistLastSample = $now

    $nowMs = [double]([DateTimeOffset]$now).ToUnixTimeMilliseconds()
    [void]$script:LightHistPts.Add([double[]]@($nowMs, [math]::Round($Boost, 4), [math]::Round($Gain, 4)))

    if ($script:LightHistPts.Count -ge $script:LightHistMaxPts) {
        $merged = New-Object System.Collections.Generic.List[double[]]
        $cnt = $script:LightHistPts.Count
        for ($i = 0; $i + 1 -lt $cnt; $i += 2) {
            $x = $script:LightHistPts[$i]; $y = $script:LightHistPts[$i + 1]
            # campione fermo (boost = 0) non va mediato con uno reale: si tiene quello reale
            if ($x[1] -le 0 -and $y[1] -gt 0) { [void]$merged.Add($y) }
            elseif ($y[1] -le 0 -and $x[1] -gt 0) { [void]$merged.Add($x) }
            else { [void]$merged.Add([double[]]@((($x[0] + $y[0]) / 2), (($x[1] + $y[1]) / 2), (($x[2] + $y[2]) / 2))) }
        }
        if (($cnt % 2) -eq 1) { [void]$merged.Add($script:LightHistPts[$cnt - 1]) }
        $script:LightHistPts      = $merged
        $script:LightHistInterval = $script:LightHistInterval * 2
    }

    $script:LightHistJson = $null

    if (($now - $script:LightHistLastSave).TotalSeconds -ge 60) {
        $script:LightHistLastSave = $now
        try {
            Build-LightHistoryJson
            $tmp = "$($script:LightHistFile).tmp"
            [System.IO.File]::WriteAllText($tmp, $script:LightHistJson, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $script:LightHistFile -Force
        } catch {}
    }
    return $true
}

function Reset-LightHistory {
    # Azzeramento completo dello storico della pagina Light: stato identico a quello della prima
    # accensione (buffer vuoto, intervallo base 1 s, nuovo orario di partenza, file su R:\ eliminato).
    # Unico scrittore: il thread HTTP (stesso di Add-LightHistoryPoint), quindi nessuna corsa.
    $script:LightHistPts        = New-Object System.Collections.Generic.List[double[]]
    $script:LightHistInterval   = 1
    $script:LightHistStartMs    = [double]([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds()
    $script:LightHistLastSample = [DateTime]::MinValue
    $script:LightHistLastSave   = [DateTime]::MinValue
    try {
        foreach ($lhf in @($script:LightHistFile, "$($script:LightHistFile).tmp")) {
            if ([System.IO.File]::Exists($lhf)) { [System.IO.File]::Delete($lhf) }
        }
    } catch {}
    Build-LightHistoryJson
    # finestra recente (v1106.2)
    $script:LightRecentPts        = New-Object System.Collections.Generic.List[double[]]
    $script:LightRecentLastSample = [DateTime]::MinValue
    $script:LightRecentLastSave   = [DateTime]::MinValue
    $script:LightRecentCache      = @{}
    try {
        foreach ($lrf in @($script:LightRecentFile, "$($script:LightRecentFile).tmp")) {
            if ([System.IO.File]::Exists($lrf)) { [System.IO.File]::Delete($lrf) }
        }
    } catch {}
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
    $linePot = Get-LinePotential
    $ipConn      = Get-IpConnectivityStatus
    $dnsFallback = Get-DnsFallbackLog
    $blocchiOrari = Get-BlocksHourlyDistribution
    $winUpdate   = Get-WindowsUpdateStatus

    $unboundRamData  = Get-UnboundWorkingSet
    $sysLoad         = Get-SystemLoad
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
        line_potential   = $linePot
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
            sys_load            = $sysLoad
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

# === MODALITA' LIGHT: RACCOLTA MINIMA ===
# La pagina Light usa solo: motore attivo, RAM disk, statistiche Unbound, radar upstream,
# punteggio salute. Tutto il resto (versioni, root radar ICMP, task pianificati, feed log,
# anomalie, hardening, NTP, Windows Update, ...) serve solo alla Pro e viene raccolto
# soltanto mentre la Pro e' aperta (e per $script:ProHoldSec secondi dopo l'ultima richiesta).
$script:ProHoldSec        = 180
$script:CachedLightJson   = $null
$script:LastLightJsonTime = [DateTime]::MinValue
$script:LightRamData      = $null
$script:LightRamTime      = [DateTime]::MinValue
$script:LightHealthData   = $null
$script:LightHealthTime   = [DateTime]::MinValue

function Set-ProActive {
    # Chiamata dal server a ogni richiesta della Pro: se la Pro era inattiva da piu' di
    # ProHoldSec inizia una nuova "sessione" (il JSON completo vecchio non va piu' servito).
    $sync = $script:BunkerSyncHash
    if (-not $sync) { return }
    $now = Get-Date
    if (($now - $sync.ProTs).TotalSeconds -gt $script:ProHoldSec) { $sync.ProSession = $now }
    $sync.ProTs = $now
}

function Get-BunkerStatusLightJson {
    # Cache interna 800 ms (non 1500): il ciclo del collector Light e' di 1 s, con 1500 ms ogni seconda
    # chiamata restituirebbe l'istantanea vecchia e i dati si rinnoverebbero solo ogni 2 s.
    if ($script:CachedLightJson -and ((Get-Date) - $script:LastLightJsonTime).TotalMilliseconds -lt 800) {
        return $script:CachedLightJson
    }

    # Con un ciclo da 1 s le letture che cambiano di rado NON vanno rifatte ad ogni giro: RAM disk (query CIM)
    # ogni 5 s, snapshot di salute (lettura+parsing JSON) ogni 3 s. Restano a ogni giro solo stato del
    # servizio e unbound-control stats, cioe' cio' che muove davvero le lancette.
    $nowC = Get-Date
    if (-not $script:LightRamData -or ($nowC - $script:LightRamTime).TotalSeconds -ge 5) {
        $script:LightRamData = Get-RamDiskGauge
        $script:LightRamTime = $nowC
    }
    if (($nowC - $script:LightHealthTime).TotalSeconds -ge 3) {
        $script:LightHealthData = Get-HealthSnapshot
        $script:LightHealthTime = $nowC
    }
    $ramDisk  = $script:LightRamData
    $engineOn = Get-EngineStatus
    $stats    = Get-LiveStats
    # Istante di campionamento dei contatori (ms epoch): la pagina Light lo usa per calcolare i QPS sul
    # tempo REALE tra due letture (e non sull'orario di arrivo), cosi' il jitter di rete/polling non li falsa
    $tsMs     = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $radar    = Get-UpstreamRadar
    $salute   = $script:LightHealthData
    # Riga di rete (banda + IP + DNS vincitore): letture leggere, la parte web dell'IP pubblico gira in un runspace separato
    $netSpeed = Get-NetworkSpeed
    $linePot = Get-LinePotential
    $ipConn   = Get-IpConnectivityStatus
    # Mantiene aggiornata la finestra 24h (campiona al massimo 1 volta/minuto, costo minimo)
    [void](Update-SessionHistory)

    # Registro riavvii Unbound (stessa logica della versione completa, serve solo l'uptime)
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

    # Blocchi: la Light usa gia' base.rpz_azioni (contatore Unbound); non serve rileggere il log RPZ
    $rpzAzioni = 0
    if ($stats.base.rpz_azioni) { $rpzAzioni = $stats.base.rpz_azioni }
    $pctBlocchi = 0
    if ($stats.base.query_totali -gt 0) {
        $pctBlocchi = [math]::Round(($rpzAzioni / $stats.base.query_totali) * 100, 1)
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
        ts_ms            = $tsMs
        host             = $env:COMPUTERNAME
        modalita         = "light"
        ram_disk         = $ramDisk
        engine_attivo    = $engineOn
        upstream_radar   = $radar
        net_speed        = $netSpeed
        line_potential   = $linePot
        connettivita_ip  = $ipConn
        statistiche_live = $stats
        dall_ultimo_report = [ordered]@{
            query_totali         = $stats.base.query_totali
            cache_hits           = $stats.base.cache_hits
            cache_efficienza_pct = $stats.base.cache_efficienza_pct
            uptime_secondi       = $stats.base.uptime_secondi
            blocchi_totali       = $rpzAzioni
            blocchi_pct          = $pctBlocchi
        }
        salute_sistema   = [ordered]@{ anomalie_rilevate = $anomalie; score = $saluteScore }
    }

    $script:CachedLightJson   = ($obj | ConvertTo-Json -Depth 8 -Compress)
    $script:LastLightJsonTime = Get-Date

    if ($script:BunkerSyncHash) {
        $script:BunkerSyncHash.JsonLight = $script:CachedLightJson
        $script:BunkerSyncHash.TsLight   = $script:LastLightJsonTime
    }

    return $script:CachedLightJson
}

# === INTERFACCIA WEB HTML5 / JS ===

# === PAGINA LIGHT (rotta / ): 2 indicatori a lancette in tempo reale + pulsante verso la versione Pro (/pro) ===
$HtmlPageLight = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UNBOUND BUNKER - Dashboard Light</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cpath d='M16 1.5 29 6v9.5c0 7.6-5.2 12.6-13 15C8.2 28.1 3 23.1 3 15.5V6z' fill='%231976d2' stroke='%23ffffff' stroke-width='1.6' stroke-linejoin='round'/%3E%3Cpath d='M9.5 16.2l4.6 4.6 8.4-9.6' fill='none' stroke='%23ffffff' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<style>
  :root {
    color-scheme: dark;
    --bg: #06090d; --panel: #0d1219; --panel-2: #111720;
    --border: rgba(255,255,255,0.07); --border-strong: rgba(255,255,255,0.12);
    --text: #dbe5ee; --dim: #8497ab; --accent: #4fb3ff;
    --green: #3ddc84; --amber: #ffb300; --red: #ff5c5c;
    --font-ui: "Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
    --font-mono: "Consolas", "Cascadia Mono", "Liberation Mono", monospace;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; min-height: 100%; }
  body {
    background: radial-gradient(1200px 600px at 50% -10%, #0f1a27 0%, var(--bg) 60%);
    color: var(--text); font-family: var(--font-ui); padding: 24px 20px 32px;
  }
  .wrap { max-width: 1360px; margin: 0 auto; }
  header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 22px; }
  h1 { margin: 0; font-size: 1.35em; color: var(--accent); letter-spacing: 0.02em; }
  .sub { color: var(--dim); font-size: 0.82em; margin-top: 4px; }
  .top-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .badge {
    display: inline-flex; align-items: center; gap: 8px; padding: 8px 14px; border-radius: 999px;
    font-size: 0.8em; font-weight: 700; letter-spacing: 0.04em; border: 1px solid var(--border-strong);
    background: var(--panel-2);
  }
  .badge .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--dim); }
  .badge.ok { color: var(--green); border-color: rgba(61,220,132,0.4); }
  .badge.ok .dot { background: var(--green); box-shadow: 0 0 8px var(--green); animation: pulse 1.6s infinite; }
  .badge.bad { color: var(--red); border-color: rgba(255,92,92,0.45); }
  .badge.bad .dot { background: var(--red); }
  .badge.wait { color: var(--dim); }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.35; } }
  .btn-pro {
    display: inline-flex; align-items: center; gap: 8px; padding: 10px 18px; border-radius: 10px;
    font-weight: 700; font-size: 0.88em; letter-spacing: 0.03em; text-decoration: none; color: #fff;
    background: linear-gradient(135deg, rgba(79,179,255,0.28), rgba(179,136,255,0.28));
    border: 1px solid rgba(79,179,255,0.55); box-shadow: 0 4px 14px rgba(0,0,0,0.35);
    transition: transform 0.2s ease, box-shadow 0.2s ease;
  }
  .btn-pro:hover { transform: translateY(-2px); box-shadow: 0 8px 20px rgba(79,179,255,0.25); }
  .btn-pro:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .btn-restart { cursor: pointer; font-family: inherit; background: rgba(255,179,0,0.14); border-color: rgba(255,179,0,0.55); }
  .btn-restart:hover:not(:disabled) { box-shadow: 0 8px 20px rgba(255,179,0,0.25); }
  .btn-restart:disabled { opacity: 0.6; cursor: wait; transform: none; }
  .btn-line { cursor: pointer; font-family: inherit; background: rgba(79,179,255,0.14); border-color: rgba(79,179,255,0.55); }
  .btn-line:hover:not(:disabled) { box-shadow: 0 8px 20px rgba(79,179,255,0.25); }
  .btn-line:disabled { opacity: 0.6; cursor: wait; transform: none; }
  .btn-reset { cursor: pointer; font-family: inherit; background: rgba(255,92,92,0.12); border-color: rgba(255,92,92,0.5); }
  .btn-reset:hover:not(:disabled) { box-shadow: 0 8px 20px rgba(255,92,92,0.25); }
  .btn-reset:disabled { opacity: 0.6; cursor: wait; transform: none; }

  /* ---------- Riga di rete: banda, IP, DNS del vincitore del radar ---------- */
  .netstrip { background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%); border: 1px solid var(--border-strong); border-radius: 14px; padding: 12px 16px; margin: 0 0 18px; text-align: left; font-family: var(--font-ui); transition: opacity 0.4s; }
  .netstrip.stale { opacity: 0.45; filter: grayscale(0.7); }
  .ns-meters { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
  .ns-pot { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin: 0 0 10px; padding: 8px 12px; font-size: 0.8em; border-radius: 10px; border: 1px solid rgba(79,179,255,0.30); background: linear-gradient(90deg, rgba(79,179,255,0.14) 0%, rgba(79,179,255,0.03) 100%); box-shadow: inset 3px 0 0 var(--accent); }
  .ns-pot.fb { border-color: var(--border-strong); background: rgba(255,255,255,0.03); box-shadow: inset 3px 0 0 var(--dim); }
  .ns-pot-l { font-size: 0.82em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-pot.run .ns-pot-l::after { content: ' \25CF'; color: #ffd600; animation: nsPotPulse 1.2s ease-in-out infinite; }
  .ns-pot-s { font-size: 0.82em; color: var(--dim); margin-top: 3px; line-height: 1.35; }
  .ns-pot-v { text-align: right; white-space: nowrap; }
  .ns-pot-v b { font-family: var(--font-mono); font-size: 2.1em; line-height: 1; color: var(--accent); letter-spacing: 0; }
  .ns-pot.fb .ns-pot-v b { color: var(--dim); }
  .ns-pot-v small { font-size: 0.8em; color: var(--dim); margin-left: 3px; }
  @keyframes nsPotPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }
  .ns-mh { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; font-size: 0.74em; color: var(--dim); margin-bottom: 5px; letter-spacing: 0.06em; text-transform: uppercase; }
  .ns-mh b { font-family: var(--font-mono); font-size: 1.7em; color: var(--text); letter-spacing: 0; }
  .ns-mh small { font-size: 0.9em; color: var(--dim); letter-spacing: 0; text-transform: none; font-weight: 400; }
  .ns-bar { display: grid; grid-template-columns: repeat(40, 1fr); gap: 2px; height: 12px; }
  .ns-bar i { border-radius: 2px; background: rgba(255,255,255,0.07); transition: background 0.25s; }
  .ns-sc { display: flex; justify-content: space-between; font-size: 0.7em; color: var(--dim); margin-top: 3px; font-family: var(--font-mono); }
  .ns-info { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--border); }
  .ns-c { background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 10px; padding: 8px 12px; min-width: 0; }
  .ns-c.win { border-color: rgba(61,220,132,0.45); }
  .ns-c.bad { border-color: rgba(255,92,92,0.45); }
  .ns-l { font-size: 0.68em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-v { font-family: var(--font-mono); font-size: 0.88em; font-weight: 700; color: var(--text); margin-top: 3px; word-break: break-all; line-height: 1.35; }
  .ns-s { font-size: 0.72em; color: var(--dim); margin-top: 2px; }
  .ns-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; background: var(--dim); }
  .ns-dot.ok { background: #3ddc84; box-shadow: 0 0 6px #3ddc84; }
  .ns-dot.bad { background: #ff5c5c; }
  @media (max-width: 900px) { .ns-info { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
  @media (max-width: 560px) { .ns-meters { grid-template-columns: 1fr; } }

  .gauges { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 20px; }
  .card {
    background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%);
    border: 1px solid var(--border-strong); border-radius: 16px; padding: 20px 20px 18px;
    box-shadow: 0 10px 30px rgba(0,0,0,0.4); text-align: center;
  }
  .card h2 { margin: 0 0 4px; font-size: 0.95em; letter-spacing: 0.08em; color: var(--dim); text-transform: uppercase; }
  .card svg { width: 100%; max-width: 380px; height: auto; display: block; margin: 0 auto; }
  .value { font-family: var(--font-mono); font-weight: 700; }
  /* Striscia delle ultime variazioni (a destra la piu' recente): scorre verso sinistra */
  .card svg.trail { max-width: 380px; margin: -4px auto 6px; overflow: visible; }
  .trail .ti { transition: transform 0.5s cubic-bezier(0.22, 0.8, 0.3, 1), opacity 0.5s ease; }
  @media (prefers-reduced-motion: reduce) { .trail .ti { transition: none; } }
  .detail { color: var(--dim); font-size: 0.82em; margin-top: 6px; min-height: 1.3em; font-family: var(--font-mono); }
  .stale { opacity: 0.45; filter: grayscale(0.7); transition: opacity 0.4s; }
  /* ---------- Componenti del punteggio (accanto alla lancetta su card larga, sotto su card stretta) ---------- */
  .card { container-type: inline-size; }
  .upper { display: block; }
  .gcol { min-width: 0; }
  .comps { margin-top: 12px; text-align: left; }
  .chead { display: flex; justify-content: space-between; gap: 8px; font-size: 0.72em; color: var(--dim); padding: 0 2px 5px; }
  .crow { display: grid; grid-template-columns: 14px minmax(0, 1fr) auto; align-items: center; gap: 8px; padding: 6px 2px; border-top: 1px solid var(--border); }
  .cdot { width: 11px; height: 11px; border-radius: 50%; background: var(--c); box-shadow: 0 0 7px var(--c); }
  .crow.soft .cdot { opacity: 0.55; box-shadow: none; }
  .crow.na .cdot { background: transparent; border: 1.5px solid var(--dim); box-shadow: none; }
  .cmain { display: flex; flex-direction: column; min-width: 0; }
  .cname { font-size: 0.86em; color: var(--text); }
  .crow.prio .cname { font-weight: 700; }
  .ctag { margin-left: 6px; font-size: 0.8em; font-style: italic; color: var(--dim); font-weight: 400; }
  .crow.prio .ctag { color: var(--c); font-style: normal; font-weight: 700; }
  .cval { font-size: 0.74em; color: var(--dim); font-family: var(--font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .cpts { font-family: var(--font-mono); font-size: 0.78em; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .cpts em { display: block; font-style: normal; font-size: 0.9em; color: var(--dim); }
  .crow.prio .cpts em { color: var(--c); font-weight: 700; }
  @container (min-width: 600px) {
    .upper { display: grid; grid-template-columns: 300px minmax(0, 1fr); gap: 22px; align-items: start; }
    .comps { margin-top: 0; }
  }
  /* ---------- Storico sotto le card ---------- */
  .hist { margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--border); text-align: left; }
  .hist-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; flex-wrap: wrap; margin-bottom: 6px; }
  .hist-title { font-size: 0.72em; letter-spacing: 0.09em; text-transform: uppercase; color: var(--dim); font-weight: 700; }
  .hist-win { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
  .hist-win button { background: transparent; color: var(--dim); border: 0; border-right: 1px solid var(--border); padding: 3px 10px; font-size: 0.68em; font-family: var(--font-mono); cursor: pointer; }
  .hist-win button:last-child { border-right: 0; }
  .hist-win button:hover { color: #e9f2fb; background: rgba(255,255,255,0.05); }
  .hist-win button.on { color: #e9f2fb; background: rgba(79,179,255,0.20); font-weight: 700; }
  .hist-range { font-size: 0.68em; color: var(--dim); font-family: var(--font-mono); }
  .hist-plot { position: relative; }
  .card .hist-plot svg { width: 100%; max-width: none; height: auto; margin: 0; display: block; touch-action: pan-y; cursor: crosshair; }
  .hist-tip {
    position: absolute; top: 4px; left: 0; pointer-events: none; opacity: 0; transition: opacity 0.12s;
    background: rgba(6,9,13,0.94); border: 1px solid var(--border-strong); border-radius: 8px;
    padding: 5px 9px; font-size: 0.72em; white-space: nowrap; box-shadow: 0 6px 18px rgba(0,0,0,0.5); z-index: 2;
  }
  .hist-tip .tt { color: var(--dim); font-family: var(--font-mono); font-size: 0.92em; }
  .hist-tip .tv { font-family: var(--font-mono); font-weight: 700; margin-top: 1px; }
  .hist-stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 10px; }
  .hist-stat { background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 8px; padding: 6px 4px; text-align: center; }
  .hist-stat span { display: block; font-size: 0.6em; letter-spacing: 0.09em; text-transform: uppercase; color: var(--dim); }
  .hist-stat b { display: block; font-family: var(--font-mono); font-size: 0.78em; margin-top: 2px; font-variant-numeric: tabular-nums; }
  footer { color: var(--dim); font-size: 0.75em; text-align: center; margin-top: 22px; }
  /* ---------- Overlay riavvio Dashboard (stesso aspetto della versione Pro) ---------- */
  .restart-overlay {
    display: none; position: fixed; inset: 0;
    background: rgba(6,9,13,0.94);
    z-index: 9999; align-items: center; justify-content: center;
  }
  .restart-overlay.active { display: flex; animation: overlayIn 0.25s ease both; }
  .restart-overlay.active .restart-overlay-box { animation: boxIn 0.4s cubic-bezier(0.22, 0.8, 0.3, 1) both; }
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
  /* Overlay automatico (connessione persa / riavvio dall'esterno): barra indeterminata, nessuna percentuale */
  .restart-overlay.auto .restart-progress-fill { width: 100% !important; }
  .restart-overlay.auto .restart-progress-pct { display: none; }
  @keyframes restart-stripes { from { background-position: 0 0; } to { background-position: 34px 0; } }
  @keyframes overlayIn { from { opacity: 0; } to { opacity: 1; } }
  @keyframes boxIn { from { opacity: 0; transform: translateY(14px) scale(0.97); } to { opacity: 1; transform: none; } }
  .restart-progress-pct { margin-top: 10px; font-size: 0.85em; color: var(--dim); letter-spacing: 0.5px; font-variant-numeric: tabular-nums; }
  @media (prefers-reduced-motion: reduce) { .restart-progress-fill, .restart-overlay.active, .restart-overlay.active .restart-overlay-box { animation: none; } }
</style>
</head>
<body>
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
<div class="wrap">
  <header>
    <div>
      <h1>&#128737; UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1106.3 - by Mauro Bigoni</h1>
      <div class="sub" id="sub">Connessione al Bunker in corso...</div>
    </div>
    <div class="top-actions">
      <span class="badge wait" id="engBadge"><span class="dot"></span><span id="engText">IN ATTESA</span></span>
      <button type="button" class="btn-pro btn-reset" id="btnResetLight" title="Svuota lo storico dei due indicatori e riparte da zero, come alla prima accensione">&#128465;&#65039; Azzera storico</button>
      <button type="button" class="btn-pro btn-line" id="btnForceLine" title="Avvia subito il test di velocit&agrave; reale della linea (download, poi upload: circa 15 secondi, occupa tutta la banda)">&#128225; Misura linea ora</button>
      <button type="button" class="btn-pro btn-restart" id="btnRestartLight" title="Riavvia la Dashboard (la pagina si ricarica da sola)">&#128260; Riavvia Dashboard</button>
      <a class="btn-pro" href="/pro" title="Apri la dashboard completa">&#128295; Versione Pro &rarr;</a>
    </div>
  </header>

<div class="netstrip" id="netStrip">
  <div class="ns-meters">
    <div>
      <div class="ns-pot fb" id="nsPotDc" title="Potenziale velocit&agrave; della connessione internet: massimo misurato con un test reale a fine task AbuseCh30m (circa ogni 2 ore). Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11015;</div><div class="ns-pot-s" id="nsPotDs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotD">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span>&#11015; Download</span><span><b id="nsDv">--</b> <small>Mbps</small></span></div>
      <div class="ns-bar" id="nsDb"></div>
      <div class="ns-sc"><span>0</span><span id="nsDpk">picco 0 Mbps</span><span id="nsDmx">10</span></div>
    </div>
    <div>
      <div class="ns-pot fb" id="nsPotUc" title="Potenziale velocit&agrave; della connessione internet: massimo misurato con un test reale a fine task AbuseCh30m (circa ogni 2 ore). Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11014;</div><div class="ns-pot-s" id="nsPotUs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotU">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span>&#11014; Upload</span><span><b id="nsUv">--</b> <small>Mbps</small></span></div>
      <div class="ns-bar" id="nsUb"></div>
      <div class="ns-sc"><span>0</span><span id="nsUpk">picco 0 Mbps</span><span id="nsUmx">10</span></div>
    </div>
  </div>
  <div class="ns-info">
    <div class="ns-c"><div class="ns-l">IP pubblico</div><div class="ns-v" id="nsPub">N/D</div><div class="ns-s" id="nsPubS">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv4</div><div class="ns-v" id="nsV4">N/D</div><div class="ns-s" id="nsV4S">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv6</div><div class="ns-v" id="nsV6">N/D</div><div class="ns-s" id="nsV6S">&nbsp;</div></div>
    <div class="ns-c" id="nsDnsC"><div class="ns-l">DNS in uso</div><div class="ns-v" id="nsDns">N/D</div><div class="ns-s" id="nsDnsS">&nbsp;</div></div>
  </div>
</div>

  <div class="gauges" id="gauges">
    <div class="card">
      <h2>Funzionamento Bunker</h2>
      <div class="upper">
      <div class="gcol">
      <svg id="g1" viewBox="0 0 300 190" role="img" aria-label="Funzionamento del bunker in percentuale"></svg>
      <svg class="trail" id="t1" viewBox="0 0 300 26" role="img" aria-label="Ultime variazioni: a destra la piu' recente"></svg>
      <div class="detail" id="d1">--</div>
      </div>
      <div class="comps" id="c1"></div>
      </div>
      <div class="hist" id="hist1">
        <div class="hist-head"><span class="hist-title">Storico recente</span><span class="hist-win" role="group" aria-label="Finestra temporale del grafico"><button type="button" data-w="300">5 min</button><button type="button" data-w="600">10 min</button><button type="button" data-w="3600">1 h</button></span><span class="hist-range" id="hr1">--</span></div>
        <div class="hist-plot"><svg viewBox="0 0 480 190" role="img" aria-label="Storico del funzionamento del bunker"></svg><div class="hist-tip"></div></div>
        <div class="hist-stats">
          <div class="hist-stat"><span>Min</span><b id="h1min">--</b></div>
          <div class="hist-stat"><span>Media</span><b id="h1avg">--</b></div>
          <div class="hist-stat"><span>Max</span><b id="h1max">--</b></div>
          <div class="hist-stat"><span>Ora</span><b id="h1now">--</b></div>
        </div>
      </div>
    </div>
    <div class="card">
      <h2>Miglioramento Applicato al PC</h2>
      <div class="upper">
      <div class="gcol">
      <svg id="g2" viewBox="0 0 300 190" role="img" aria-label="Indice di miglioramento applicato al PC"></svg>
      <svg class="trail" id="t2" viewBox="0 0 300 26" role="img" aria-label="Ultime variazioni: a destra la piu' recente"></svg>
      <div class="detail" id="d2">--</div>
      </div>
      <div class="comps" id="c2"></div>
      </div>
      <div class="hist" id="hist2">
        <div class="hist-head"><span class="hist-title">Storico recente</span><span class="hist-win" role="group" aria-label="Finestra temporale del grafico"><button type="button" data-w="300">5 min</button><button type="button" data-w="600">10 min</button><button type="button" data-w="3600">1 h</button></span><span class="hist-range" id="hr2">--</span></div>
        <div class="hist-plot"><svg viewBox="0 0 480 190" role="img" aria-label="Storico del miglioramento applicato al PC"></svg><div class="hist-tip"></div></div>
        <div class="hist-stats">
          <div class="hist-stat"><span>Min</span><b id="h2min">--</b></div>
          <div class="hist-stat"><span>Media</span><b id="h2avg">--</b></div>
          <div class="hist-stat"><span>Max</span><b id="h2max">--</b></div>
          <div class="hist-stat"><span>Ora</span><b id="h2now">--</b></div>
        </div>
      </div>
    </div>
  </div>
  <footer id="foot">Aggiornamento in tempo reale ogni secondo</footer>
</div>

<script>
(function () {
  var CX = 150, CY = 150, R = 108, NS = 'http://www.w3.org/2000/svg';
  var COL = { red: '#ff5c5c', amber: '#ffb300', green: '#3ddc84' };

  function fmtPct(v) { return Number(v).toFixed(5).replace('.', ',') + '%'; }
  function fmtTitlePct(v) { return Number(v).toFixed(2).replace('.', ',') + '%'; }
  // Scala colore CONTINUA (rosso -> arancio -> ambra -> verde): la stessa sfumatura alimenta arco,
  // numero, indicatore di punta, pallini del titolo e icona della scheda, cosi' i colori coincidono sempre.
  var STOPS = [[0, [255, 77, 77]], [30, [255, 122, 47]], [55, [255, 179, 0]], [80, [155, 224, 74]], [100, [61, 220, 132]]];
  function hex2(n) { n = Math.round(n); return (n < 16 ? '0' : '') + n.toString(16); }
  function colorFor(p) {
    p = Math.max(0, Math.min(100, Number(p) || 0));
    for (var i = 1; i < STOPS.length; i++) {
      if (p <= STOPS[i][0]) {
        var a = STOPS[i - 1], b = STOPS[i], t = (p - a[0]) / (b[0] - a[0]);
        t = t * t * (3 - 2 * t);   // raccordo morbido tra un colore e il successivo
        return '#' + hex2(a[1][0] + (b[1][0] - a[1][0]) * t) + hex2(a[1][1] + (b[1][1] - a[1][1]) * t) + hex2(a[1][2] + (b[1][2] - a[1][2]) * t);
      }
    }
    return '#3ddc84';
  }
  // pallino colorato per il titolo della scheda: 4 livelli (verde da 66%, giallo da 55%, arancio da 30%, rosso sotto); soglie volutamente piu' larghe di quelle dell'arco
  function dotFor(p) { return p >= 66 ? '\u{1F7E2}' : (p >= 55 ? '\u{1F7E1}' : (p >= 30 ? '\u{1F7E0}' : '\u{1F534}')); }
  // Icona della scheda: due barre affiancate (sinistra = 1a lancetta, destra = 2a). L'altezza segue il valore, il colore
  // segue le soglie del titolo (verde da 66%) con verde scuro da 75% in su
  function favColor(p) { return p >= 75 ? '#1e8e4e' : (p >= 66 ? '#3ddc84' : (p >= 55 ? '#f2d34b' : (p >= 30 ? '#ff8a2a' : '#ff5c5c'))); }
  function favRect(x, px, py, w, h, r, fill) {
    if (h <= 0) return;
    r = Math.min(r, h / 2, w / 2);
    x.beginPath(); x.moveTo(px + r, py); x.lineTo(px + w - r, py); x.arcTo(px + w, py, px + w, py + r, r);
    x.lineTo(px + w, py + h - r); x.arcTo(px + w, py + h, px + w - r, py + h, r); x.lineTo(px + r, py + h);
    x.arcTo(px, py + h, px, py + h - r, r); x.lineTo(px, py + r); x.arcTo(px, py, px + r, py, r); x.closePath();
    x.fillStyle = fill; x.fill();
  }
  var favKey = '';
  function updateFavicon(a, b) {
    try {
      var pa = Math.max(0, Math.min(100, +a || 0)), pb = Math.max(0, Math.min(100, +b || 0));
      var ca = favColor(pa), cb = favColor(pb);
      var ha = pa > 0 ? Math.max(2, Math.round(pa / 100 * 44)) : 0, hb = pb > 0 ? Math.max(2, Math.round(pb / 100 * 44)) : 0;
      var key = ca + ha + cb + hb;
      if (key === favKey) return;
      favKey = key;
      var cv = document.createElement('canvas'); cv.width = 64; cv.height = 64;
      var x = cv.getContext('2d'); if (!x) return;
      favRect(x, 4, 4, 56, 56, 10, '#0d1219');
      favRect(x, 10, 10, 20, 44, 3, 'rgba(255,255,255,0.15)');
      favRect(x, 34, 10, 20, 44, 3, 'rgba(255,255,255,0.15)');
      favRect(x, 10, 54 - ha, 20, ha, 3, ca);
      favRect(x, 34, 54 - hb, 20, hb, 3, cb);
      var old = document.querySelector('link[rel~="icon"]');
      var l = document.createElement('link'); l.rel = 'icon'; l.type = 'image/png'; l.href = cv.toDataURL('image/png');
      if (old && old.parentNode) old.parentNode.removeChild(old);
      document.head.appendChild(l);
    } catch (e) { /* icona dinamica non disponibile: resta quella precedente */ }
  }
  // 0% = sinistra (180 gradi), 100% = destra (0 gradi)
  function pt(p, r) {
    var a = Math.PI * (1 - p / 100);
    return [CX + r * Math.cos(a), CY - r * Math.sin(a)];
  }
  function arc(p0, p1, r) {
    var a = pt(p0, r), b = pt(p1, r);
    return 'M' + a[0].toFixed(2) + ' ' + a[1].toFixed(2) + ' A' + r + ' ' + r + ' 0 0 1 ' + b[0].toFixed(2) + ' ' + b[1].toFixed(2);
  }
  function el(name, attrs, parent) {
    var e = document.createElementNS(NS, name);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }

  function buildGauge(svgId) {
    var svg = document.getElementById(svgId);
    el('path', { d: arc(0, 100, R), fill: 'none', stroke: 'rgba(255,255,255,0.06)', 'stroke-width': 18, 'stroke-linecap': 'round' }, svg);
    // Arco sfumato continuo: 120 tratti contigui (con minima sovrapposizione, niente fessure), ognuno del colore
    // esatto del suo punto. Lo stesso arco e' disegnato due volte: attenuato (scala completa) e acceso, ritagliato
    // da un settore che arriva fino al valore corrente, cosi' si vede quanto e' "pieno" lo strumento.
    var defs = el('defs', {}, svg);
    var clip = el('clipPath', { id: svgId + '-clip' }, defs);
    var clipPath = el('path', { d: 'M0 0' }, clip);
    var glow = el('filter', { id: svgId + '-glow', x: '-150%', y: '-150%', width: '400%', height: '400%' }, defs);
    el('feGaussianBlur', { stdDeviation: 3.5 }, glow);
    var dim = el('g', { opacity: 0.2 }, svg);
    var lit = el('g', { 'clip-path': 'url(#' + svgId + '-clip)' }, svg);
    var SEG = 120, STEP = 100 / SEG;
    [dim, lit].forEach(function (grp) {
      for (var i = 0; i < SEG; i++) {
        var q0 = i * STEP, q1 = Math.min(100, (i + 1) * STEP + 0.35);
        el('path', { d: arc(q0, q1, R), fill: 'none', stroke: colorFor(q0 + STEP / 2), 'stroke-width': 12 }, grp);
      }
      var e0 = pt(0, R), e1 = pt(100, R);
      el('circle', { cx: e0[0].toFixed(2), cy: e0[1].toFixed(2), r: 6, fill: colorFor(0) }, grp);
      el('circle', { cx: e1[0].toFixed(2), cy: e1[1].toFixed(2), r: 6, fill: colorFor(100) }, grp);
    });
    var tipGlow = el('circle', { cx: pt(0, R)[0], cy: pt(0, R)[1], r: 9, fill: colorFor(0), opacity: 0.85, filter: 'url(#' + svgId + '-glow)' }, svg);
    var tip = el('circle', { cx: pt(0, R)[0], cy: pt(0, R)[1], r: 5.5, fill: colorFor(0), stroke: '#e9f2fb', 'stroke-width': 2 }, svg);
    for (var t = 0; t <= 100; t += 10) {
      var major = (t % 50 === 0);
      var a = pt(t, R - 13), b = pt(t, R - (major ? 25 : 20));
      el('line', { x1: a[0], y1: a[1], x2: b[0], y2: b[1], stroke: 'rgba(219,229,238,0.55)', 'stroke-width': major ? 2 : 1 }, svg);
      if (major) {
        var l = pt(t, R - 38);
        var tx = el('text', { x: l[0], y: l[1] + 4, 'text-anchor': 'middle', fill: '#8497ab', 'font-size': 11 }, svg);
        tx.textContent = t;
      }
    }
    var needle = el('g', {}, svg);
    el('polygon', { points: (CX - 4) + ',' + CY + ' ' + (CX + 4) + ',' + CY + ' ' + CX + ',' + (CY - R + 18), fill: '#e9f2fb' }, needle);
    el('circle', { cx: CX, cy: CY, r: 9, fill: '#111720', stroke: '#e9f2fb', 'stroke-width': 3 }, svg);
    var val = el('text', { x: CX, y: CY + 32, 'text-anchor': 'middle', 'font-size': 28, 'font-weight': 700, fill: '#8497ab', 'font-family': 'Consolas, monospace' }, svg);
    val.textContent = '--';
    // Freccia di tendenza (a destra del valore): grigia '-' finche' non c'e' una variazione significativa
    var arr = el('text', { x: CX + 92, y: CY + 31, 'text-anchor': 'middle', 'font-size': 22, 'font-weight': 700, fill: '#8497ab' }, svg);
    arr.textContent = '\u2013';
    var arrTip = el('title', {}, arr);
    var tsvg = document.getElementById('t' + svgId.slice(1));
    var trail = tsvg ? el('g', {}, tsvg) : null;
    return { trail: trail, trailItems: [], needle: needle, clipPath: clipPath, tip: tip, tipGlow: tipGlow, val: val, arr: arr, arrTip: arrTip, lastV: null, cur: 0, tgt: 0, vel: 0, run: false, col: '', txt: '' };
  }

  var G = [buildGauge('g1'), buildGauge('g2')];
  function setNeedle(g, p) {
    g.needle.setAttribute('transform', 'rotate(' + (-90 + 1.8 * p).toFixed(2) + ' ' + CX + ' ' + CY + ')');
    // settore di ritaglio dell'arco acceso: dal punto 0 al valore corrente
    var rr = R + 16, s0 = pt(0, rr), s1 = pt(Math.min(p, 99.999), rr);
    g.clipPath.setAttribute('d', p <= 0.0001 ? 'M0 0' :
      'M' + CX + ' ' + CY + ' L' + s0[0].toFixed(2) + ' ' + s0[1].toFixed(2) + ' A' + rr + ' ' + rr + ' 0 ' + (p > 50 ? 1 : 0) + ' 1 ' + s1[0].toFixed(2) + ' ' + s1[1].toFixed(2) + ' Z');
    // indicatore luminoso sulla punta dell'arco, nel colore esatto del valore
    var tp = pt(p, R), c = colorFor(p);
    g.tip.setAttribute('cx', tp[0].toFixed(2)); g.tip.setAttribute('cy', tp[1].toFixed(2)); g.tip.setAttribute('fill', c);
    g.tipGlow.setAttribute('cx', tp[0].toFixed(2)); g.tipGlow.setAttribute('cy', tp[1].toFixed(2)); g.tipGlow.setAttribute('fill', c);
  }
  G.forEach(function (g) { setNeedle(g, 0); });

  // Lancette fluide (v1105.7): la lancetta INSEGUE il valore reale con una molla critica e la
  // velocita' si conserva quando arriva un nuovo campione, quindi niente stop-and-go tra un
  // aggiornamento e l'altro. Il valore reale resta sempre il target: nessun dato inventato,
  // nessun overshoot oltre 0..100. A lancetta ferma il ciclo si spegne (zero CPU a riposo).
  var FOLLOW_W = 9;   // rad/s: piu' alto = piu' reattiva (9 = circa 94% del salto in 0,5 s)
  var rafId = 0, lastFrame = 0;

  function frame(now) {
    rafId = 0;
    var dt = lastFrame ? Math.min(0.25, Math.max(0.001, (now - lastFrame) / 1000)) : 0.016;
    lastFrame = now;
    var busy = false;
    for (var i = 0; i < G.length; i++) {
      var g = G[i];
      if (!g.run) continue;
      var dlt = g.cur - g.tgt;
      var tmp = (g.vel + FOLLOW_W * dlt) * dt;
      var ex = Math.exp(-FOLLOW_W * dt);
      g.cur = g.tgt + (dlt + tmp) * ex;
      g.vel = (g.vel - FOLLOW_W * tmp) * ex;
      if (Math.abs(g.cur - g.tgt) < 0.000005 && Math.abs(g.vel) < 0.0005) {
        // arrivata: aggancio esatto al valore reale e stop
        g.cur = g.tgt; g.vel = 0; g.run = false;
        g.val.textContent = g.txt;
      } else {
        g.cur = Math.max(0, Math.min(100, g.cur));
        g.val.textContent = fmtPct(g.cur);
        busy = true;
      }
      setNeedle(g, g.cur);
      var c = colorFor(g.cur);
      if (c !== g.col) { g.col = c; g.val.setAttribute('fill', c); }
    }
    if (busy) rafId = requestAnimationFrame(frame); else lastFrame = 0;
  }

  // Tendenza rispetto al valore precedente: ▲ verde = migliorato, ▼ rossa = peggiorato (per entrambe le
  // lancette piu' alto = meglio). Si confronta il valore REALE (non la posizione animata). Il riferimento
  // avanza solo quando la variazione supera ARROW_EPS: il rumore sui 5 decimali non fa lampeggiare la
  // freccia e una deriva lenta viene comunque rilevata. Tra due variazioni la freccia resta quella dell'ultima.
  // Striscia storica delle variazioni: una freccetta per ogni variazione significativa (stessa soglia della
  // freccia accanto al numero). A destra la piu' recente; a ogni nuova variazione la fila scivola a sinistra,
  // le piu' vecchie diventano piu' piccole e sfumate, la piu' recente e' leggermente luminosa.
  var TRAIL_N = 18, TRAIL_SP = 14, TRAIL_Y = 13;
  function trailPlace(it, g) {
    var N = TRAIL_N, slot = it.slot, out = slot < 0;
    var f = out ? 0 : slot / (N - 1);
    var sc = out ? 0.3 : 0.5 + 0.5 * f;
    var x = CX - (N - 1) * TRAIL_SP / 2 + slot * TRAIL_SP;
    it.el.style.transform = 'translate(' + x.toFixed(1) + 'px,' + TRAIL_Y + 'px) scale(' + sc.toFixed(3) + ')';
    it.el.style.opacity = out ? 0 : (0.16 + 0.84 * Math.pow(f, 1.2)).toFixed(3);
    it.el.style.filter = (slot === N - 1) ? 'drop-shadow(0 0 3px ' + it.col + ')' : 'none';
  }
  function pushTrail(g, up, diff) {
    if (!g.trail) return;
    var col = up ? COL.green : COL.red;
    var items = g.trailItems;
    items.forEach(function (it) { it.slot--; });
    var e = el('g', { 'class': 'ti' }, g.trail);
    el('path', { d: up ? 'M0 -5 L5.5 4 L-5.5 4 Z' : 'M0 5 L5.5 -4 L-5.5 -4 Z', fill: col, stroke: col, 'stroke-width': 1.6, 'stroke-linejoin': 'round' }, e);
    var tt = el('title', {}, e);
    tt.textContent = hhmmss(Date.now()) + '  ' + (up ? '+' : '-') + Math.abs(diff).toFixed(5).replace('.', ',') + ' punti';
    var it = { el: e, slot: TRAIL_N - 1, col: col };
    // posizione di partenza (piccola e trasparente, a destra) senza transizione, poi si anima verso quella finale
    e.style.transition = 'none';
    e.style.opacity = 0;
    e.style.transform = 'translate(' + (CX - (TRAIL_N - 1) * TRAIL_SP / 2 + TRAIL_N * TRAIL_SP).toFixed(1) + 'px,' + TRAIL_Y + 'px) scale(0.2)';
    void e.getBoundingClientRect();
    e.style.transition = '';
    items.push(it);
    items.forEach(function (x) { trailPlace(x, g); });
    var gone = items.filter(function (x) { return x.slot < 0; });
    if (gone.length) {
      g.trailItems = items.filter(function (x) { return x.slot >= 0; });
      setTimeout(function () { gone.forEach(function (x) { if (x.el.parentNode) x.el.parentNode.removeChild(x.el); }); }, 700);
    }
  }
  var ARROW_EPS = 0.001;   // punti percentuali: da tarare sul rumore reale dei dati
  function setTrend(g, v) {
    if (g.lastV === null) { g.lastV = v; return; }
    var diff = v - g.lastV;
    if (Math.abs(diff) < ARROW_EPS) return;
    var up = diff > 0;
    g.arr.textContent = up ? '\u25B2' : '\u25BC';
    g.arr.setAttribute('fill', up ? COL.green : COL.red);
    pushTrail(g, up, diff);
    g.arrTip.textContent = (up ? '+' : '-') + Math.abs(diff).toFixed(5).replace('.', ',') + ' punti rispetto al valore precedente';
    g.lastV = v;
  }

  function setGauge(g, pct, text) {
    g.tgt = Math.max(0, Math.min(100, pct));
    setTrend(g, g.tgt);
    g.txt = text;
    g.run = true;
    if (!rafId) rafId = requestAnimationFrame(frame);
  }

  // ---- Calcolo punteggi: stessa logica della dashboard Pro ----
  var prevQueries = 0, prevTime = 0, maxLatSeen = 0, isRefreshing = false, lastDataTs = 0, lastSnap = '';

  // ---- Riferimenti realistici per il 100% (stessi valori e stessa logica della pagina Pro: tenerli allineati) ----
  // Cache: nessun resolver arriva al 100% di hit (domini nuovi, TTL scaduti): BNK_CACHE_TARGET_PCT di hit = punteggio pieno.
  // Latenza: il 100% e' relativo alla linea. RTT di riferimento = mediana, su finestra mobile, del tempo di connessione
  // TCP verso gli upstream online misurato dall'Upstream Radar. Con DoT una risoluzione non costa meno di circa 4 RTT (handshake TLS + query + risoluzione dell'upstream).
  var BNK_CACHE_TARGET_PCT = 80, BNK_LAT_FULL_RATIO = 4, BNK_RTT_FALLBACK_MS = 25, BNK_RTT_MIN_MS = 5, BNK_RTT_WINDOW = 120;
  var bnkRttHist = [];
  function bnkMedian(a) {
    var q = a.slice().sort(function (x, y) { return x - y; }), n = q.length;
    return n ? (n % 2 ? q[(n - 1) / 2] : (q[n / 2 - 1] + q[n / 2]) / 2) : 0;
  }
  function bnkLineRtt(radar) {
    var ms = radar.filter(function (r) { return r && r.ok && Number(r.ms) > 0 && Number(r.ms) < 400; }).map(function (r) { return Number(r.ms); });
    if (ms.length) { bnkRttHist.push(bnkMedian(ms)); if (bnkRttHist.length > BNK_RTT_WINDOW) bnkRttHist.shift(); }
    return bnkRttHist.length ? Math.max(BNK_RTT_MIN_MS, bnkMedian(bnkRttHist)) : BNK_RTT_FALLBACK_MS;
  }
  // Punteggio latenza = tempo medio di ricorsione / RTT: fino a 4x RTT 100%, 80% a 8x, 50% a 16x, minimo 15% a 32x (interpolazione lineare; i multipli scalano con BNK_LAT_FULL_RATIO).
  function bnkLatScore(recMs, rtt) {
    var r = rtt > 0 ? recMs / rtt : 0, F = BNK_LAT_FULL_RATIO, P = [[F, 100], [2 * F, 80], [4 * F, 50], [8 * F, 15]];
    if (r <= P[0][0]) return 100;
    for (var i = 1; i < P.length; i++) {
      if (r <= P[i][0]) return Math.round((P[i - 1][1] + (P[i][1] - P[i - 1][1]) * (r - P[i - 1][0]) / (P[i][0] - P[i - 1][0])) * 100000) / 100000;
    }
    return P[P.length - 1][1];
  }

  function compute(d) {
    var base = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base : {};
    var qTot = base.query_totali || 0;
    var latMs = base.latenza_ms || 0;
    var qpsAvg = base.qps_medio || 0;
    var now = d.ts_ms ? Number(d.ts_ms) : Date.now(), liveQPS;   // tempo di campionamento del server: QPS esatti anche col polling irregolare
    if (prevQueries > 0 && now > prevTime) {
      liveQPS = Math.max(0, qTot - prevQueries) / ((now - prevTime) / 1000);
    } else { liveQPS = qpsAvg; }
    prevQueries = qTot; prevTime = now;

    var radar = d.upstream_radar || [];
    if (!Array.isArray(radar)) radar = [radar];
    var upOk = radar.filter(function (r) { return r.ok; }).length;

    var cachePct = base.cache_efficienza_pct;
    if (typeof cachePct !== 'number' || isNaN(cachePct)) cachePct = 0;
    // Precisione piena: il server arrotonda a 1 decimale, qui ricalcolo dai contatori grezzi
    if (qTot > 0 && typeof base.cache_hits === 'number') cachePct = Math.max(0, Math.min(100, (base.cache_hits / qTot) * 100));
    // Unbound conta come cache hit anche le risposte date dalle RPZ (blocchi): non sono cache.
    // Cache reale = hit al netto dei blocchi, sulle sole query risolvibili (stessa finestra dei contatori).
    var repE = d.dall_ultimo_report || {};
    var blockedN = (typeof base.rpz_azioni === 'number' && base.rpz_azioni > 0) ? base.rpz_azioni : ((typeof repE.blocchi_totali === 'number') ? repE.blocchi_totali : 0);
    if (qTot > 0 && typeof base.cache_hits === 'number') {
      blockedN = Math.max(0, Math.min(qTot, blockedN));
      var resolvN = qTot - blockedN;
      cachePct = resolvN > 0 ? Math.max(0, Math.min(100, (Math.max(0, base.cache_hits - blockedN) / resolvN) * 100)) : 0;
    }

    // latMs = total.recursion.time.avg di Unbound: tempo medio delle SOLE query risolte
    // in ricorsione (cache miss). Le risposte da cache (~0 ms) non sono incluse, quindi la
    // latenza media percepita dall'utente e' recLat * (1 - cache%).
    var recLat = latMs;
    var latFromRadar = false;
    if (qTot === 0 && (!recLat || recLat <= 0) && radar.length > 0) {
      var okR = radar.filter(function (r) { return r.ok; });
      if (okR.length > 0) { recLat = Math.round(okR.reduce(function (a, r) { return a + r.ms; }, 0) / okR.length); latFromRadar = true; }
    }
    if (!recLat || recLat < 0) recLat = 0;
    var cacheFrac = Math.max(0, Math.min(1, cachePct / 100));
    var lat = latFromRadar ? recLat : Math.round(recLat * (1 - cacheFrac) * 10) / 10;
    var latRaw = latFromRadar ? recLat : recLat * (1 - cacheFrac);   // non arrotondata: serve ai punteggi

    // Punteggi con 1 decimale (r1) per rendere visibili anche le oscillazioni minime.
    var r1 = function (v) { return Math.round(v * 10) / 10; };
    var r5 = function (v) { return Math.round(v * 100000) / 100000; };   // 5 decimali (diecimillesimi)
    // Latenza: relativa alla linea (RTT misurato dal radar); cache: relativa all'obiettivo realistico (BNK_CACHE_TARGET_PCT)
    var refRtt = bnkLineRtt(radar);
    var latScore = bnkLatScore(recLat, refRtt);
    var cacheScore = Math.min(100, r5(cachePct / BNK_CACHE_TARGET_PCT * 100));

    var upstreamScore = radar.length > 0 ? r5((upOk / radar.length) * 100) : 100;
    // DNSSEC misurato dai contatori Unbound (nessun traffico extra): la validazione e' provata funzionante
    // se c'e' almeno una risposta validata (secure) o respinta perche' non valida (bogus: il validatore
    // sta proteggendo). Senza nessuna delle due dopo 100+ query risolvibili = validazione non attiva (rosso).
    // Con poche query ancora 'in attesa' (nessuna penalita'): dopo un riavvio i contatori ripartono da 0.
    var dsx = (d.statistiche_live && d.statistiche_live.dnssec) ? d.statistiche_live.dnssec : {};
    var dsSec = Number(dsx.secure) || 0, dsBog = Number(dsx.bogus) || 0;
    var resolvQ = Math.max(0, qTot - Math.max(0, Math.min(qTot, blockedN)));
    var dnssecState = (dsSec + dsBog > 0) ? 'ok' : (resolvQ >= 100 ? 'fail' : 'wait');
    var dnssecPct = dnssecState === 'fail' ? 0 : 100;
    var qpsHeadroom = Math.max(0, Math.min(100, r5(100 - (liveQPS / 5))));
    var health = (d.salute_sistema && d.salute_sistema.score !== undefined) ? d.salute_sistema.score : 100;

    var boost = r5(cacheScore * 0.30 + latScore * 0.25 + upstreamScore * 0.15 + dnssecPct * 0.15 + qpsHeadroom * 0.05 + health * 0.10);

    var prefetch = (d.statistiche_live && d.statistiche_live.prefetch) ? d.statistiche_live.prefetch : 0;
    // Baseline = latenza che avrebbe ogni query SENZA cache (tutte in ricorsione), mai sotto cio' che la linea
    // consente (BNK_LAT_FULL_RATIO x RTT). Punteggio pieno (40 pt) quando il risparmio raggiunge quello della
    // cache obiettivo (BNK_CACHE_TARGET_PCT del baseline).
    var baseline = Math.max(refRtt * BNK_LAT_FULL_RATIO, recLat);
    var msSavedRaw = Math.max(0, baseline - latRaw);
    var msSaved = r1(msSavedRaw);
    var latGain = Math.min(40, r5((msSavedRaw / (baseline * BNK_CACHE_TARGET_PCT / 100)) * 40));
    var blkPct = base.blocchi_pct || 0;
    if (qTot > 0) blkPct = Math.max(0, (blockedN / qTot) * 100);
    var rpzGain = Math.min(20, r5(blkPct * 0.8));
    var ramGain = (d.ram_disk && d.ram_disk.attivo) ? 10 : 2;
    // upstream proporzionale agli upstream online; prefetch a 0 non e' un difetto se la cache e' gia' efficace
    var dotGain = (radar.length > 0 ? 5 * upOk / radar.length : 0) + ((prefetch > 0 || cachePct >= 50) ? 5 : 2);
    var gainPt = r5(latGain + rpzGain + ramGain + dotGain);
    if (gainPt > 80) gainPt = 80;
    var gainIdx = r5((gainPt / 80) * 100);

    // ---- Componenti dei due punteggi, tutte nell'unita' della lancetta (punti percentuali): la somma dei "got" = valore della lancetta ----
    var nUp = radar.length, ramOn = !!(d.ram_disk && d.ram_disk.attivo), k80 = 100 / 80;
    var comps1 = [
      mkComp('Cache', f2(cachePct) + '% (esclusi i blocchi) \u00b7 obiettivo ' + BNK_CACHE_TARGET_PCT + '%', cacheScore * 0.30, 30),
      mkComp('Latenza', f1(lat) + ' ms percepita \u00b7 linea ' + f1(refRtt) + ' ms', latScore * 0.25, 25),
      mkComp('Upstream online', upOk + ' su ' + nUp, upstreamScore * 0.15, 15),
      mkComp('DNSSEC', dnssecState === 'ok' ? (dsSec + ' validate' + (dsBog > 0 ? ' \u00b7 ' + dsBog + ' respinte' : '')) : (dnssecState === 'fail' ? 'nessuna risposta validata su ' + resolvQ + ' query' : 'in attesa di risposte validate'), dnssecPct * 0.15, 15, dnssecState === 'wait' ? 'wait' : ''),
      mkComp('Salute sistema', f1(health) + ' su 100', health * 0.10, 10),
      mkComp('Margine QPS', f1(liveQPS) + ' query/s', qpsHeadroom * 0.05, 5, 'traffic')
    ];
    var comps2 = [
      mkComp('Latenza risparmiata', f1(msSaved) + ' ms sul baseline', latGain * k80, 40 * k80),
      mkComp('Blocchi RPZ', f1(blkPct) + '% delle query', rpzGain * k80, 20 * k80, 'traffic'),
      mkComp('RAM disk', ramOn ? 'attivo' : 'non attivo', ramGain * k80, 10 * k80),
      mkComp('Upstream e prefetch', upOk + ' su ' + nUp + ' upstream', dotGain * k80, 10 * k80)
    ];

    return { boost: boost, gainPt: gainPt, gainIdx: gainIdx, cachePct: cachePct, lat: lat, recLat: recLat, refRtt: refRtt, upOk: upOk, upTot: radar.length, msSaved: msSaved, blkPct: blkPct, comps1: comps1, comps2: comps2 };
  }

  // ---- Componenti del punteggio: colore in base a quanto la singola voce raggiunge del proprio massimo ----
  function f1(v) { return (Math.round(Number(v) * 10) / 10).toFixed(1).replace('.', ','); }
  function f2(v) { return Number(v).toFixed(2).replace('.', ','); }
  function lvlColor(p) { return p >= 80 ? '#3ddc84' : (p >= 55 ? '#f2d34b' : (p >= 30 ? '#ff8a2a' : '#ff5c5c')); }
  function mkComp(name, val, got, max, kind) {
    return { name: name, val: val, got: got, max: max, pct: max > 0 ? Math.max(0, Math.min(100, got / max * 100)) : 0, kind: kind || '' };
  }
  var compLast = {};
  function renderComps(id, list, engineOn) {
    var host = document.getElementById(id), html = '';
    if (!host) return;
    if (!engineOn) {
      html = '<div class="chead"><span>Componenti del punteggio</span></div><div class="cval" style="padding:6px 2px">Motore Unbound fermo: punteggio non calcolabile</div>';
    } else {
      // voce da migliorare per prima = quella che fa perdere piu' punti alla lancetta (escluse non misurate e dipendenti dal traffico)
      var top = -1, topLost = 1;
      list.forEach(function (c, i) { if (!c.kind && (c.max - c.got) > topLost) { topLost = c.max - c.got; top = i; } });
      html = '<div class="chead"><span>Componenti del punteggio</span><span>punti / max \u00b7 persi</span></div>';
      list.forEach(function (c, i) {
        var lost = Math.max(0, c.max - c.got);
        var cls = 'crow' + ((c.kind === 'na' || c.kind === 'wait') ? ' na' : '') + (c.kind === 'traffic' ? ' soft' : '') + (i === top ? ' prio' : '');
        var tip = c.kind === 'traffic' ? 'Dipende dal traffico: un valore basso non indica un problema da correggere'
                : (c.kind === 'wait' ? 'Dopo un riavvio di Unbound i contatori ripartono da zero: nessuna penalit\u00e0 finch\u00e9 non ci sono abbastanza query' : (c.kind === 'na' ? 'Nel calcolo vale sempre il massimo: non viene misurato' : (i === top ? 'La voce che fa perdere pi\u00f9 punti a questa lancetta' : '')));
        var tag = c.kind === 'traffic' ? '<span class="ctag">dipende dal traffico</span>' : (i === top ? '<span class="ctag">priorit\u00e0</span>' : '');
        html += '<div class="' + cls + '" style="--c:' + lvlColor(c.pct) + '"' + (tip ? ' title="' + tip + '"' : '') + '>' +
                '<span class="cdot"></span>' +
                '<span class="cmain"><span class="cname">' + c.name + tag + '</span><span class="cval">' + c.val + '</span></span>' +
                '<span class="cpts">' + f1(c.got) + ' / ' + f1(c.max) + '<em>' + (c.kind === 'na' ? 'fisso' : (c.kind === 'wait' ? 'in attesa' : (lost >= 0.05 ? '\u2212' + f1(lost) : '0'))) + '</em></span></div>';
      });
    }
    if (compLast[id] !== html) { compLast[id] = html; host.innerHTML = html; }
  }

  function setEngine(state, text) {
    var b = document.getElementById('engBadge');
    b.className = 'badge ' + state;
    document.getElementById('engText').textContent = text;
  }

  /* ---------- Riga di rete: banda (autoscala), IP, DNS del vincitore del radar ---------- */
  var NSN = 40, nsPkD = 0, nsPkU = 0, nsRingD = [], nsRingU = [];
  function nsNice(v) { var st = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]; for (var i = 0; i < st.length; i++) { if (v <= st[i]) return st[i]; } return Math.ceil(v / 1000) * 1000; }
  function nsFmt(v) { return (Math.round(v * 10) / 10).toFixed(1).replace('.', ','); }
  function nsEsc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function nsPaint(id, v, mx) {
    var b = document.getElementById(id); if (!b) return;
    if (!b.children.length) { for (var i = 0; i < NSN; i++) b.appendChild(document.createElement('i')); }
    var on = Math.round(Math.min(v / mx, 1) * NSN);
    for (var j = 0; j < NSN; j++) {
      var f = j / NSN;
      b.children[j].style.background = j < on ? (f < 0.6 ? '#3ddc84' : (f < 0.85 ? '#ffb300' : '#ff5c5c')) : '';
    }
  }
  function nsSet(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
  function nsMeter(v, ring, ids, pk) {
    ring.push(v); if (ring.length > 60) ring.shift();
    var mx = nsNice(Math.max.apply(null, ring) * 1.15);
    nsPaint(ids[0], v, mx);
    document.getElementById(ids[1]).textContent = nsFmt(v);
    document.getElementById(ids[2]).textContent = 'picco ' + Math.round(pk) + ' Mbps';
    document.getElementById(ids[3]).textContent = mx;
  }
  var nsLineHold = 0;
  async function forceLineTest() {
    var btn = document.getElementById('btnForceLine'), st = document.getElementById('forceLineStatus');
    if (btn && btn.disabled) return;
    if (!confirm('Avviare subito il test di velocit\u00e0 della linea?\n\nDura circa 15 secondi: prima il download, poi l\'upload, e per qualche secondo occupa tutta la banda.')) return;
    nsLineHold = Date.now() + 8000;
    if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Avvio...'; }
    try {
      var res = await fetch('/api/force-line-test', { method: 'POST', cache: 'no-store' });
      var data = await res.json().catch(function () { return {}; });
      if (st) st.textContent = data.status === 'started' ? 'Test avviato alle ' + new Date().toLocaleTimeString('it-IT') + '.' : (data.status === 'busy' ? 'Un test \u00e8 gi\u00e0 in corso.' : 'Errore: ' + (data.error || 'sconosciuto'));
      if (data.status === 'error') nsLineHold = 0;
    } catch (e) {
      nsLineHold = 0;
      if (st) st.textContent = 'Errore di rete durante la richiesta.';
    }
    if (st) setTimeout(function () { st.textContent = ''; }, 30000);
  }
  (function () { var b = document.getElementById('btnForceLine'); if (b) b.addEventListener('click', forceLineTest); })();
  function nsPotUpdate(d) {
    var p = d.line_potential, n = d.net_speed;
    var cfg = [['nsPotDc', 'nsPotD', 'nsPotDs', 'down_mbps'], ['nsPotUc', 'nsPotU', 'nsPotUs', 'up_mbps']];
    for (var i = 0; i < cfg.length; i++) {
      var c = document.getElementById(cfg[i][0]), v = document.getElementById(cfg[i][1]), s = document.getElementById(cfg[i][2]);
      if (!c || !v || !s) continue;
      if (p && p.ok && p[cfg[i][3]] > 0) {
        var pot = p[cfg[i][3]];
        v.textContent = pot >= 100 ? String(Math.round(pot)) : nsFmt(pot);
        var sub = nsEsc(p.testo);
        if (n && n.ok) sub += ' &middot; in uso ' + Math.round(Math.min(n[cfg[i][3]] / pot, 9.99) * 100) + '%';
        s.innerHTML = sub;
        c.className = 'ns-pot' + (p.fonte === 'scheda' ? ' fb' : '') + (p.in_corso ? ' run' : '');
      } else {
        v.textContent = 'N/D'; s.innerHTML = '&nbsp;'; c.className = 'ns-pot fb';
      }
    }
    var fb = document.getElementById('btnForceLine');
    if (fb) {
      var busy = !!(p && p.in_corso) || Date.now() < nsLineHold;
      fb.disabled = busy;
      fb.innerHTML = busy ? '&#9203; Test in corso...' : '&#128225; Misura linea ora';
    }
  }
  function nsUpdate(d) {
    nsPotUpdate(d);
    var n = d.net_speed;
    if (n && n.ok) {
      nsPkD = Math.max(nsPkD, n.down_mbps); nsPkU = Math.max(nsPkU, n.up_mbps);
      nsMeter(n.down_mbps, nsRingD, ['nsDb', 'nsDv', 'nsDpk', 'nsDmx'], nsPkD);
      nsMeter(n.up_mbps, nsRingU, ['nsUb', 'nsUv', 'nsUpk', 'nsUmx'], nsPkU);
    } else {
      document.getElementById('nsDv').textContent = 'N/D';
      document.getElementById('nsUv').textContent = 'N/D';
      nsPaint('nsDb', 0, 10); nsPaint('nsUb', 0, 10);
    }
    var ip = d.connettivita_ip;
    if (ip) {
      nsSet('nsPub', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_wan) : 'N/D');
      nsSet('nsPubS', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_loc || '') || '&nbsp;' : 'non disponibile');
      var l4 = ip.ipv4_lan_ok ? String(ip.ipv4_lan).split(', ') : [];
      nsSet('nsV4', l4.length ? nsEsc(l4[0]) : 'N/D');
      nsSet('nsV4S', '<span class="ns-dot ' + (l4.length ? 'ok' : 'bad') + '"></span>' + (l4.length ? 'rete locale' + (l4.length > 1 ? ' (+' + (l4.length - 1) + ')' : '') : 'offline'));
      var l6 = ip.ipv6_lan_ok ? String(ip.ipv6_lan).split(', ') : [];
      if (ip.ipv6_wan_ok) { nsSet('nsV6', nsEsc(ip.ipv6_wan)); nsSet('nsV6S', '<span class="ns-dot ok"></span>pubblico'); }
      else if (l6.length) { nsSet('nsV6', nsEsc(l6[0])); nsSet('nsV6S', '<span class="ns-dot ok"></span>solo locale'); }
      else { nsSet('nsV6', 'N/D'); nsSet('nsV6S', '<span class="ns-dot bad"></span>non disponibile'); }
    }
    var rad = d.upstream_radar; if (rad && !Array.isArray(rad)) rad = [rad];
    rad = rad || [];
    var win = null, okN = 0;
    rad.forEach(function (r) { if (r && r.ok) { okN++; if (!win || r.ms < win.ms) win = r; } });
    var c = document.getElementById('nsDnsC');
    if (win) {
      c.className = 'ns-c win';
      nsSet('nsDns', nsEsc(win.tag || 'Upstream') + ' ' + nsEsc(win.ip));
      nsSet('nsDnsS', '<span class="ns-dot ok"></span>vincitore radar \u00b7 ' + Math.round(win.ms) + ' ms \u00b7 ' + okN + '/' + rad.length);
    } else {
      c.className = rad.length ? 'ns-c bad' : 'ns-c';
      nsSet('nsDns', rad.length ? 'Nessun resolver raggiungibile' : 'N/D');
      nsSet('nsDnsS', rad.length ? '<span class="ns-dot bad"></span>radar 0/' + rad.length : '&nbsp;');
    }
  }

  async function refresh() {
    if (isRefreshing) return;
    isRefreshing = true;
    try {
      var res = await fetch('/api/status?mode=light', { cache: 'no-store' });
      if (!res.ok) return;
      var txt = await res.text();
      if (!txt || !txt.trim()) return;
      var d = JSON.parse(txt);
      lastDataTs = Date.now();
      if (autoOverlay) {   // la Dashboard e' tornata: via il messaggio di riavvio
        autoOverlay = false;
        hideRestartOverlay();
        document.getElementById('restartOverlay').classList.remove('auto');
      }
      document.getElementById('gauges').classList.remove('stale');
      document.getElementById('netStrip').classList.remove('stale');
      // Con il polling a 1 s la stessa istantanea del server arriva piu' volte: la si elabora una
      // sola volta (altrimenti i QPS risulterebbero a dente di sega: 0, picco, 0, picco...)
      var snap = d.ts_ms || d.generato_il || '';   // ts_ms (ms) distingue istantanee nello stesso secondo; il JSON della Pro non lo ha
      if (snap && snap === lastSnap) return;
      lastSnap = snap;
      try { nsUpdate(d); } catch (e) { /* la riga di rete non deve mai bloccare le lancette */ }

      var engineOn = !!d.engine_attivo;
      setEngine(engineOn ? 'ok' : 'bad', engineOn ? 'UNBOUND ATTIVO' : 'UNBOUND FERMO');
      document.getElementById('sub').textContent = 'Host: ' + (d.host || 'N/D') + ' | Aggiornato: ' + (d.generato_il || '--');

      var s = compute(d);
      var boostShown = engineOn ? s.boost : 0;
      setGauge(G[0], boostShown, fmtPct(boostShown));
      document.getElementById('d1').textContent = engineOn
        ? 'Latenza percepita ' + s.lat + ' ms (in ricorsione ' + s.recLat + ' ms) \u00b7 RTT linea ' + f1(s.refRtt) + ' ms'
        : 'Motore Unbound fermo';

      setGauge(G[1], s.gainIdx, fmtPct(s.gainIdx));
      if (window.__postLightSample) window.__postLightSample(boostShown, engineOn ? s.gainIdx : 0);
      // Percentuali nel titolo della scheda (2 decimali per leggibilita'): monitoraggio anche da altra tab
      document.title = dotFor(boostShown) + ' \u{1F510} ' + fmtTitlePct(boostShown) + '  ' + dotFor(s.gainIdx) + ' \u{1F5A5}\uFE0F ' + fmtTitlePct(s.gainIdx);
      updateFavicon(boostShown, engineOn ? s.gainIdx : 0);
      document.getElementById('d2').textContent = 'Guadagno ' + s.gainPt.toFixed(1) + ' / 80 pt \u00b7 ' + s.msSaved.toFixed(1) + ' ms risparmiati sul baseline';
      renderComps('c1', s.comps1, engineOn);
      renderComps('c2', s.comps2, engineOn);
    } catch (e) {
      /* dati non disponibili: gestito dal controllo di inattivita' */
    } finally {
      isRefreshing = false;
    }
  }

  // ---- Storico recente: grafici sotto le card (finestra fissa 5 min / 10 min / 1 h) ----
  // v1106.2: la finestra ha larghezza FISSA e scorre a velocita' costante (nessuna compressione col passare
  // del tempo). I dati vengono dal buffer recente del server (1 campione al secondo, /api/light-history?win=).
  // Scorrimento fluido (v1106.1). Un campione al secondo (server: intervallo base 1 s). Il grafico
  // non si ridisegna piu' a scatti a ogni campione: il tracciato viene costruito UNA volta per
  // campione (x in secondi dall'accensione) e la finestra scorre in continuo cambiando solo la scala
  // orizzontale (attributo transform, ~30 fps). Il punto in testa segue la poligonale reale:
  // l'orologio del grafico resta indietro di circa un campione, cosi' il punto sta sempre tra due
  // campioni VERI e si muove per interpolazione lineare (la stessa retta che disegna la linea):
  // nessun dato inventato, nessuna estrapolazione. Con il puntatore sopra il grafico il disegno si
  // ferma (per poter leggere i valori) e riparte da solo all'uscita.
  var HW = 480, HH = 190, PL = 48, PR = 12, PT = 12, PB = 24;
  var HPW = HW - PL - PR, HPH = HH - PT - PB;
  var HC = [
    { id: 'hist1', n: 1, idx: 1, color: '#4fb3ff', svg: null, box: null, geo: null, g: null, data: null, last: null, y: null, easing: false, hover: false, dirty: false },
    { id: 'hist2', n: 2, idx: 2, color: '#b388ff', svg: null, box: null, geo: null, g: null, data: null, last: null, y: null, easing: false, hover: false, dirty: false }
  ];
  function p2(n) { return (n < 10 ? '0' : '') + n; }
  function hhmm(ms) { var d = new Date(ms); return p2(d.getHours()) + ':' + p2(d.getMinutes()); }
  function hhmmss(ms) { var d = new Date(ms); return p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds()); }
  function dmhm(ms) { var d = new Date(ms); return p2(d.getDate()) + '/' + p2(d.getMonth() + 1) + ' ' + hhmm(ms); }
  function fmtInterval(s) { return s >= 60 ? (s / 60).toFixed(s % 60 ? 1 : 0) + ' min' : s + ' s'; }

  // Orologio del grafico (condiviso dai due grafici: hanno gli stessi campioni). tR = istante dello
  // storico mostrato in testa al grafico; avanza in tempo reale (performance.now, quindi indipendente
  // dall'orologio del PC server) ma non supera mai l'ultimo campione ricevuto. Un piccolo controllo
  // proporzionale ne regola la velocita' (0,5x..2x) per tenere sempre circa un campione di margine.
  var histWin = 600;   // secondi mostrati (predefinito 10 min)
  try { var sw = parseInt(localStorage.getItem('bunkerHistWin'), 10); if (sw === 300 || sw === 600 || sw === 3600) histWin = sw; } catch (e) { }
  var WIN_LABEL = { 300: '5 min', 600: '10 min', 3600: 'ultima ora' };
  var hv = { ready: false, tR: 0, tLast: 0, I: 1000, perf: 0 };
  var hRaf = 0, hLastPaint = 0;
  function histAdvance(now) {
    if (!hv.ready) return;
    var dt = now - hv.perf;
    hv.perf = now;
    if (dt <= 0) return;
    var L = Math.min(hv.I, 2000);
    var rate = Math.max(0.9, Math.min(1.1, 1 + ((hv.tLast - hv.tR) - L) / (8 * L)));   // velocita' quasi costante: solo +-10% per assorbire il jitter
    hv.tR = Math.min(hv.tLast, hv.tR + dt * rate);
  }
  function histSync(h) {
    var last = -1, i;
    for (i = h.p.length - 1; i >= 0; i--) { if (h.p[i][1] > 0) { last = h.p[i][0]; break; } }
    if (last < 0) { hv.ready = false; return; }
    var now = performance.now();
    var I = Math.max(1, h.interval || 1) * 1000, L = Math.min(I, 2000);
    if (!hv.ready) { hv.tR = last - L; hv.ready = true; hv.perf = now; }
    else histAdvance(now);
    hv.tLast = last; hv.I = I;
    if (hv.tR > last) hv.tR = last;                          // dopo una fusione dei campioni l'ultimo puo' arretrare
    if (hv.tR < last - (2 * L + 1500)) hv.tR = last - (2 * L + 1500);   // troppo indietro (scheda in background): si riallinea
    kickHist();
  }
  function kickHist() { if (!hRaf && hv.ready && !document.hidden) hRaf = requestAnimationFrame(histFrame); }
  function histFrame() {
    hRaf = 0;
    if (!hv.ready || document.hidden) return;
    var now = performance.now();
    histAdvance(now);
    var more = hv.tR < hv.tLast || HC.some(function (c) { return c.easing && !c.hover; });   // fermo quando tutto e' arrivato
    var pdt = now - hLastPaint;
    if (!more || pdt >= 30) {                                // ~30 fps bastano: lo spostamento per fotogramma e' minimo
      hLastPaint = now;
      HC.forEach(function (cfg) { paintHist(cfg, false, pdt); });
    }
    if (more) hRaf = requestAnimationFrame(histFrame);
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) kickHist(); });

  // Scheletro SVG creato una sola volta: sfondo/etichette Y (si rifanno a ogni campione), tick X
  // (testo aggiornato in continuo), gruppo dati ritagliato (path in secondi, scalato con transform),
  // punto in testa e mirino.
  function buildHistSkeleton(cfg) {
    var svg = cfg.svg, n = cfg.n, i, c = {};
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var defs = el('defs', {}, svg);
    var lg = c.grad = el('linearGradient', { id: 'gr' + n, gradientUnits: 'userSpaceOnUse', x1: 0, y1: PT, x2: 0, y2: PT + HPH }, defs);
    el('stop', { offset: 0, 'stop-color': cfg.color, 'stop-opacity': 0.38 }, lg);
    el('stop', { offset: 1, 'stop-color': cfg.color, 'stop-opacity': 0.02 }, lg);
    var cp = el('clipPath', { id: 'hclip' + n }, defs);
    el('rect', { x: PL, y: PT - 4, width: HPW, height: HPH + 4 }, cp);
    c.empty = el('text', { x: HW / 2, y: HH / 2, 'text-anchor': 'middle', fill: '#8497ab', 'font-size': 12 }, svg);
    c.empty.textContent = 'Raccolta dati in corso\u2026';
    c.stat = el('g', {}, svg);
    // griglia verticale MOBILE: linee e orari a minuti tondi che scorrono verso sinistra insieme al grafico
    // (la griglia in movimento rende visibile lo scorrimento anche con pochi pixel al secondo)
    c.vg = el('g', {}, svg);
    c.vl = []; c.vt = []; c.vs = []; c.vv = []; c.vk = '';
    for (i = 0; i < 8; i++) {
      c.vl.push(el('line', { y1: PT, y2: PT + HPH + 4, stroke: 'rgba(255,255,255,0.07)', 'stroke-width': 1 }, c.vg));
      c.vt.push(el('text', { y: HH - 6, 'text-anchor': 'middle', fill: '#8497ab', 'font-size': 10, 'font-family': 'Consolas, monospace' }, c.vg));
      c.vs.push(''); c.vv.push(true);
    }
    c.clipG = el('g', { 'clip-path': 'url(#hclip' + n + ')' }, svg);
    c.data = el('g', { transform: 'translate(' + PL + ' 0)' }, c.clipG);
    c.area = el('path', { fill: 'url(#gr' + n + ')' }, c.data);
    c.line = el('path', { fill: 'none', stroke: cfg.color, 'stroke-width': 1.8, 'stroke-linejoin': 'round', 'stroke-linecap': 'round', 'vector-effect': 'non-scaling-stroke' }, c.data);
    c.halo = el('circle', { r: 6, fill: cfg.color, opacity: 0.18 }, svg);
    c.dot = el('circle', { r: 3.2, fill: cfg.color, stroke: '#0d1219', 'stroke-width': 1.2 }, svg);
    c.hxl = el('line', { y1: PT, y2: PT + HPH, stroke: 'rgba(233,242,251,0.45)', 'stroke-width': 1, visibility: 'hidden' }, svg);
    c.hxd = el('circle', { r: 4, fill: cfg.color, stroke: '#e9f2fb', 'stroke-width': 1.5, visibility: 'hidden' }, svg);
    cfg.g = c;
  }
  function showHist(cfg, on) {
    var c = cfg.g, parts = [c.stat, c.vg, c.clipG, c.halo, c.dot], k;
    for (k = 0; k < parts.length; k++) { if (on) parts[k].removeAttribute('display'); else parts[k].setAttribute('display', 'none'); }
    if (on) c.empty.setAttribute('display', 'none'); else c.empty.removeAttribute('display');
    if (!on) { c.hxl.setAttribute('visibility', 'hidden'); c.hxd.setAttribute('visibility', 'hidden'); }
  }

  // Griglia orizzontale, etichette asse Y e soglie colore (50% / 75%) per la scala mostrata (lo..hi).
  function gridHtml(lo, hi) {
    var s = '', i;
    function Y(v) { return PT + (1 - (v - lo) / (hi - lo)) * HPH; }
    var dec = (hi - lo) < 1 ? 2 : ((hi - lo) < 10 ? 1 : 0);
    for (i = 0; i < 4; i++) {
      var gv = lo + (hi - lo) * i / 3, gy = Y(gv).toFixed(1);
      s += '<line x1="' + PL + '" y1="' + gy + '" x2="' + (HW - PR) + '" y2="' + gy + '" stroke="rgba(255,255,255,0.07)" stroke-width="1"/>';
      s += '<text x="' + (PL - 6) + '" y="' + (Number(gy) + 3.5) + '" text-anchor="end" fill="#8497ab" font-size="10" font-family="Consolas, monospace">' + gv.toFixed(dec) + '</text>';
    }
    [[50, COL.amber], [75, COL.green]].forEach(function (th) {
      if (th[0] > lo && th[0] < hi) {
        var ty = Y(th[0]).toFixed(1);
        s += '<line x1="' + PL + '" y1="' + ty + '" x2="' + (HW - PR) + '" y2="' + ty + '" stroke="' + th[1] + '" stroke-width="1" stroke-dasharray="4 4" opacity="0.45"/>';
        s += '<text x="' + (HW - PR - 3) + '" y="' + (Number(ty) - 3) + '" text-anchor="end" fill="' + th[1] + '" font-size="9" opacity="0.8">' + th[0] + '%</text>';
      }
    });
    return s;
  }

  // Parte "per campione": path di area e linea (x in secondi dall'inizio, y gia' in unita' viewBox sulla
  // scala obiettivo lo..hi). La scala verticale MOSTRATA (cfg.y.dLo/dHi) parte da quella precedente e
  // raggiunge l'obiettivo con una transizione dolce: un nuovo minimo/massimo non fa piu' scattare il grafico.
  function buildHist(cfg) {
    var D = cfg.data, g = cfg.g, i;
    function Y(v) { return PT + (1 - (v - D.lo) / (D.hi - D.lo)) * HPH; }
    if (!cfg.y) cfg.y = { dLo: D.lo, dHi: D.hi, bLo: D.lo, bHi: D.hi };
    cfg.y.bLo = D.lo; cfg.y.bHi = D.hi; cfg.y.tLo = D.lo; cfg.y.tHi = D.hi;

    // area + linea: la linea si interrompe nei buchi (pagina chiusa / Unbound fermo): nessun dato inventato
    var pts = D.pts, vals = D.vals, n = D.n, t0 = D.t0, base = PT + HPH, far = base + 100000;
    function XS(t) { return ((t - t0) / 1000).toFixed(3); }
    function segArea(a, z) {
      var q = 'M' + XS(pts[a][0]) + ' ' + far;     // base lontanissima: il ritaglio taglia al bordo inferiore, anche se la scala si sta muovendo
      for (var m = a; m <= z; m++) q += 'L' + XS(pts[m][0]) + ' ' + Y(vals[m]).toFixed(1);
      return q + 'L' + XS(pts[z][0]) + ' ' + far + 'Z';
    }
    var d = '', ar = '', segS = 0;
    for (i = 0; i < n; i++) {
      var brk = (i === 0) || (pts[i][0] - pts[i - 1][0] > D.gapMs);
      d += (brk ? 'M' : 'L') + XS(pts[i][0]) + ' ' + Y(vals[i]).toFixed(1);
      if (brk && i > 0) { ar += segArea(segS, i - 1); segS = i; }
    }
    ar += segArea(segS, n - 1);
    g.area.setAttribute('d', ar);
    g.line.setAttribute('d', d);
    // sfumatura dell'area: dal punto piu' alto della linea fino al fondo del riquadro (come prima)
    g.grad.setAttribute('y1', Y(D.mx).toFixed(1)); g.grad.setAttribute('y2', base);
    // il tratto non scala con gli assi (vector-effect): spessore in pixel di schermo = 1,8 unita' viewBox
    var rw = cfg.svg.getBoundingClientRect().width;
    g.line.setAttribute('stroke-width', (1.8 * (rw ? rw / HW : 1)).toFixed(2));
    paintHist(cfg, true, 0);
  }

  // Parte "per fotogramma": scala orizzontale COSTANTE (finestra fissa), traslazione in base all'istante tR,
  // punto in testa (sempre sul bordo destro), griglia e orari. Se nulla si e' mosso di almeno 0,05 px il DOM
  // non viene toccato.
  function paintHist(cfg, force, dtMs) {
    var D = cfg.data;
    if (!D || cfg.hover || !hv.ready || !cfg.y) return;
    var g = cfg.g, pts = D.pts, n = D.n, i, Yc = cfg.y, gridDirty = !!force;
    // transizione dolce della scala verticale verso l'obiettivo (costante di tempo ~0,18 s)
    if (Yc.dLo !== Yc.tLo || Yc.dHi !== Yc.tHi) {
      var kk = dtMs > 0 ? 1 - Math.exp(-dtMs / 180) : 0;
      Yc.dLo += (Yc.tLo - Yc.dLo) * kk; Yc.dHi += (Yc.tHi - Yc.dHi) * kk;
      if (Math.abs(Yc.dLo - Yc.tLo) < 0.0005 && Math.abs(Yc.dHi - Yc.tHi) < 0.0005) { Yc.dLo = Yc.tLo; Yc.dHi = Yc.tHi; cfg.easing = false; }
      else cfg.easing = true;
      gridDirty = true;
    } else { cfg.easing = false; }
    var dLo = Yc.dLo, dHi = Yc.dHi, R = dHi - dLo;

    var W = D.win * 1000;
    var tR = Math.min(hv.tR, D.t1);
    var tL = tR - W;
    // campione reale subito prima di tR e interpolazione lineare verso il successivo
    var tI = Math.max(tR, pts[0][0]);
    var a = 0, b = n - 1;
    while (b - a > 1) { var mm = (a + b) >> 1; if (pts[mm][0] <= tI) a = mm; else b = mm; }
    if (pts[b][0] <= tI) a = b;
    var yv = D.vals[a];
    if (a < n - 1) {
      var dtp = pts[a + 1][0] - pts[a][0];
      if (dtp > 0 && dtp <= D.gapMs) yv += (D.vals[a + 1] - D.vals[a]) * (tI - pts[a][0]) / dtp;
    }
    var y = PT + (1 - (yv - dLo) / R) * HPH;
    var L = cfg.last;
    if (!force && !gridDirty && L && Math.abs(tR - L.tR) * HPW / W < 0.05 && Math.abs(y - L.y) < 0.05) return;
    cfg.last = { tR: tR, y: y };

    // trasformazione affine dei path (x in secondi dall'inizio dei dati, y sulla scala obiettivo)
    var A = (Yc.bHi - Yc.bLo) / R;
    var B = PT + HPH - HPH * (Yc.bLo - dLo) / R - A * HPH - A * PT;
    var sx = HPW * 1000 / W;                       // pixel (unita' viewBox) per secondo: COSTANTE
    var tx = PL + HPW * (D.t0 - tL) / W;
    g.data.setAttribute('transform', 'translate(' + tx.toFixed(3) + ' ' + B.toFixed(3) + ') scale(' + sx.toPrecision(7) + ' ' + A.toPrecision(7) + ')');
    if (gridDirty) g.stat.innerHTML = gridHtml(dLo, dHi);
    var cx = (PL + HPW).toFixed(2), cy = y.toFixed(2);
    g.dot.setAttribute('cx', cx); g.dot.setAttribute('cy', cy);
    g.halo.setAttribute('cx', cx); g.halo.setAttribute('cy', cy);

    // griglia verticale mobile a minuti tondi (ora locale): 5 min -> ogni 1 min, 10 min -> ogni 2 min, 1 h -> ogni 10 min
    var stepS = D.win <= 300 ? 60 : (D.win <= 600 ? 120 : 600), S = stepS * 1000;
    var off = new Date(tR).getTimezoneOffset() * 60000;
    var m0 = Math.ceil((tL - off) / S) * S + off;
    var gx = PL + HPW * (m0 - tL) / W, pitch = HPW * S / W;
    if (g.vk !== String(D.win)) {
      g.vk = String(D.win);
      for (i = 0; i < 8; i++) { g.vl[i].setAttribute('x1', (i * pitch).toFixed(2)); g.vl[i].setAttribute('x2', (i * pitch).toFixed(2)); g.vt[i].setAttribute('x', (i * pitch).toFixed(2)); }
    }
    g.vg.setAttribute('transform', 'translate(' + gx.toFixed(2) + ' 0)');
    for (i = 0; i < 8; i++) {
      var tm = m0 + i * S, xm = gx + i * pitch, vis = (tm <= tR + 1 && xm <= PL + HPW + 0.5);
      var lblOk = vis && xm >= PL + 8 && xm <= HW - 14;
      var str = hhmm(tm);
      if (str !== g.vs[i]) { g.vs[i] = str; g.vt[i].textContent = str; }
      if (vis !== g.vv[i]) { g.vv[i] = vis; g.vl[i].setAttribute('visibility', vis ? 'visible' : 'hidden'); }
      g.vt[i].setAttribute('visibility', lblOk ? 'visible' : 'hidden');
    }
    cfg.geo = { pts: pts, m: a, t0: tL, tSpan: W, lo: dLo, hi: dHi };
  }

  function drawHist(cfg, hist) {
    var allPts = hist.p;
    var pts = allPts.filter(function (q) { return q[1] > 0; });   // esclude i campioni a Unbound fermo (0)
    var n = pts.length, fermoN = allPts.length - n;
    if (n < 2) {
      cfg.data = null; cfg.geo = null; cfg.last = null; cfg.y = null; cfg.easing = false; cfg.dirty = false;
      showHist(cfg, false);
      hv.ready = false;
      document.getElementById('hr' + cfg.n).textContent = 'in attesa dei primi campioni';
      return;
    }
    var vals = [], i, mn = Infinity, mx = -Infinity, sum = 0;
    for (i = 0; i < n; i++) { var v = pts[i][cfg.idx]; vals.push(v); if (v < mn) mn = v; if (v > mx) mx = v; sum += v; }
    var span = mx - mn, pad = Math.max(span * 0.18, 0.3);
    var lo = Math.max(0, mn - pad), hi = Math.min(100, mx + pad);
    if (hi - lo < 0.6) { var c = (hi + lo) / 2; lo = Math.max(0, c - 0.3); hi = Math.min(100, c + 0.3); }
    var t0 = pts[0][0], t1 = pts[n - 1][0];
    cfg.data = { pts: pts, vals: vals, n: n, t0: t0, t1: t1, lo: lo, hi: hi, mn: mn, mx: mx, win: hist.win || histWin, gapMs: Math.max(150000, (hist.interval || 1) * 3000) };
    showHist(cfg, true);

    var avg = sum / n, last = vals[n - 1];
    document.getElementById('h' + cfg.n + 'min').textContent = fmtPct(mn);
    document.getElementById('h' + cfg.n + 'avg').textContent = fmtPct(avg);
    document.getElementById('h' + cfg.n + 'max').textContent = fmtPct(mx);
    var nowEl = document.getElementById('h' + cfg.n + 'now');
    nowEl.textContent = fmtPct(last);
    nowEl.style.color = colorFor(last);
    document.getElementById('hr' + cfg.n).textContent =
      WIN_LABEL[cfg.data.win] + ' \u00b7 ' + n + ' campioni' +
      (fermoN > 0 ? ' \u00b7 Unbound fermo: ' + fermoN + ' campioni (' + (fermoN * 100 / allPts.length).toFixed(1).replace('.', ',') + '%)' : '');

    if (cfg.hover) { cfg.dirty = true; return; }   // puntatore sul grafico: disegno fermo, si aggiorna all'uscita
    buildHist(cfg);
  }

  function histHover(cfg, ev) {
    var g = cfg.geo;
    if (!g) return;
    var r = cfg.svg.getBoundingClientRect();
    if (!r.width) return;
    cfg.hover = true;
    var vx = (ev.clientX - r.left) / r.width * HW;
    var f = Math.max(0, Math.min(1, (vx - PL) / HPW));
    var tt = g.t0 + f * g.tSpan;
    var a = 0, b = g.m;
    while (b - a > 1) { var m = (a + b) >> 1; if (g.pts[m][0] < tt) a = m; else b = m; }
    var j = (Math.abs(g.pts[a][0] - tt) <= Math.abs(g.pts[b][0] - tt)) ? a : b;
    var p = g.pts[j], val = p[cfg.idx];
    if (p[0] < g.t0) return;     // punto fuori finestra (a sinistra del riquadro)
    var px = PL + ((p[0] - g.t0) / g.tSpan) * HPW;
    var py = PT + (1 - (val - g.lo) / (g.hi - g.lo)) * HPH;
    var ln = cfg.g.hxl, dt = cfg.g.hxd;
    ln.setAttribute('x1', px); ln.setAttribute('x2', px); ln.setAttribute('visibility', 'visible');
    dt.setAttribute('cx', px); dt.setAttribute('cy', py); dt.setAttribute('visibility', 'visible');
    var tip = cfg.box.querySelector('.hist-tip');
    tip.innerHTML = '<div class="tt">' + hhmmss(p[0]) + '</div><div class="tv" style="color:' + colorFor(val) + '">' + fmtPct(val) + '</div>';
    var pxCss = px / HW * r.width, tw = tip.offsetWidth || 110;
    var left = pxCss + 12;
    if (left + tw > r.width) left = pxCss - tw - 12;
    tip.style.left = Math.max(0, left) + 'px';
    tip.style.opacity = 1;
  }
  function histLeave(cfg) {
    cfg.hover = false;
    if (cfg.g) { cfg.g.hxl.setAttribute('visibility', 'hidden'); cfg.g.hxd.setAttribute('visibility', 'hidden'); }
    cfg.box.querySelector('.hist-tip').style.opacity = 0;
    if (cfg.data) {
      if (cfg.dirty) { cfg.dirty = false; buildHist(cfg); } else { paintHist(cfg, true, 0); }
    }
    kickHist();
  }
  HC.forEach(function (cfg) {
    cfg.box = document.getElementById(cfg.id);
    cfg.svg = cfg.box.querySelector('svg');
    buildHistSkeleton(cfg);
    cfg.svg.addEventListener('pointermove', function (ev) { histHover(cfg, ev); });
    cfg.svg.addEventListener('pointerleave', function () { histLeave(cfg); });
    cfg.svg.addEventListener('pointercancel', function () { histLeave(cfg); });
    drawHist(cfg, { p: [] });
  });

  var histBusy = false, histGen = 0;
  async function refreshHist() {
    if (histBusy) return;
    histBusy = true;
    var gen = histGen, wReq = histWin;
    try {
      var r = await fetch('/api/light-history?win=' + wReq, { cache: 'no-store' });
      if (!r.ok) return;
      var h = JSON.parse(await r.text());
      if (!h || !Array.isArray(h.p)) return;
      if (gen !== histGen) return;   // azzeramento avvenuto mentre la richiesta era in volo: dati vecchi, si scartano
      if (wReq !== histWin) return;  // finestra cambiata mentre la richiesta era in volo: se ne rifa' una nuova
      histSync(h);
      HC.forEach(function (cfg) { drawHist(cfg, h); });
    } catch (e) { /* storico non disponibile: riprova al prossimo giro */ }
    finally { histBusy = false; if (wReq !== histWin) refreshHist(); }
  }
  // Selettore finestra 5 min / 10 min / 1 h (stesso valore per i due grafici)
  function markWinButtons() {
    var bs = document.querySelectorAll('.hist-win button'), q;
    for (q = 0; q < bs.length; q++) { if (parseInt(bs[q].getAttribute('data-w'), 10) === histWin) bs[q].classList.add('on'); else bs[q].classList.remove('on'); }
  }
  (function () {
    var bs = document.querySelectorAll('.hist-win button'), q;
    for (q = 0; q < bs.length; q++) {
      bs[q].addEventListener('click', function () {
        var w = parseInt(this.getAttribute('data-w'), 10);
        if (w === histWin) return;
        histWin = w;
        try { localStorage.setItem('bunkerHistWin', String(w)); } catch (e) { }
        markWinButtons();
        HC.forEach(function (c) { c.last = null; });
        refreshHist();
      });
    }
    markWinButtons();
  })();
  // Invio del campione alla dashboard: gli stessi valori mostrati dalle lancette (1 al secondo).
  // Soglia 0,8 s e non 1 s: l'istantanea arriva ogni secondo con un po' di jitter del polling a 500 ms,
  // con 1 s netto ogni tanto un campione verrebbe saltato.
  var lastPost = 0;
  function postSample(b, g) {
    var now = Date.now();
    if (now - lastPost < 800) return;
    lastPost = now;
    fetch('/api/light-sample', {
      method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json', 'X-Bunker-Light': '1' },
      body: JSON.stringify({ b: b, g: g })
    }).then(refreshHist).catch(function () {});
  }
  window.__postLightSample = postSample;

  refreshHist();
  setInterval(refreshHist, 5000);

  // ---- Riavvia Dashboard: stessa rotta /api/restart della versione Pro ----
  // Durante il riavvio compare in sovraimpressione la barra di avanzamento in percentuale,
  // identica a quella della versione Pro (stima su tentativi / timeout massimo).
  function showRestartOverlay(icon, title, sub) {
    document.getElementById('restartOverlayIcon').innerHTML = icon;
    document.getElementById('restartOverlayTitle').textContent = title;
    document.getElementById('restartOverlaySub').textContent = sub;
    updateRestartProgress(0);
    document.getElementById('restartOverlay').classList.add('active');
  }
  function updateRestartProgress(pct) {
    var p = Math.min(100, Math.max(0, pct));
    var fill = document.getElementById('restartProgressFill');
    var label = document.getElementById('restartProgressPct');
    if (fill) fill.style.width = p + '%';
    if (label) label.textContent = Math.round(p) + '%';
  }
  function hideRestartOverlay() {
    document.getElementById('restartOverlay').classList.remove('active');
  }

  var restarting = false;
  var autoOverlay = false;   // overlay mostrato in automatico quando la connessione alla Dashboard cade (riavvio da fuori o da altra tab)
  document.getElementById('btnRestartLight').addEventListener('click', async function () {
    if (restarting) return;
    if (!confirm('Sei sicuro di voler riavviare la Dashboard?\n\nLa pagina si ricarica da sola appena la Dashboard e\' di nuovo attiva.')) return;
    restarting = true;
    var btn = this;
    btn.disabled = true;
    btn.innerHTML = '&#9203; Riavvio in corso...';
    setEngine('wait', 'RIAVVIO IN CORSO');
    try { await fetch('/api/restart', { method: 'POST', cache: 'no-store' }); } catch (e) {}
    showRestartOverlay('&#128472;&#65039;', 'Riavvio della Dashboard in corso...', 'Rilascio e verifica della porta ' + location.port + ' in esecuzione...');
    var tries = 0, sawDown = false;
    var SOFT_LIMIT = 35, HARD_LIMIT = 90;
    var iv = setInterval(async function () {
      tries++;
      updateRestartProgress((tries / HARD_LIMIT) * 95);
      try {
        var r = await fetch('/api/status?mode=light', { cache: 'no-store' });
        if (r.ok) {
          // ricarica solo dopo aver visto il vecchio processo cadere (o, in ogni caso, dopo 8 s)
          if (sawDown || tries > 8) {
            clearInterval(iv);
            updateRestartProgress(100);
            setTimeout(function () { location.reload(); }, 500);
            return;
          }
        } else { sawDown = true; }
      } catch (e) { sawDown = true; }
      if (tries === SOFT_LIMIT) {
        document.getElementById('restartOverlaySub').textContent =
          'Sta impiegando pi\u00f9 del previsto (possibile scansione antivirus del processo appena avviato)... continuo ad attendere.';
      }
      if (tries > HARD_LIMIT) {
        clearInterval(iv);
        restarting = false;
        hideRestartOverlay();
        btn.disabled = false;
        btn.innerHTML = '&#128260; Riavvia Dashboard';
        alert('Il riavvio non e\' ancora completato dopo ' + HARD_LIMIT + ' secondi. Ricarica la pagina tra qualche secondo.');
      }
    }, 1000);
  });

  // ---- Azzera storico: svuota lo storico dei 2 indicatori e riparte da zero, come alla prima accensione ----
  // Server: buffer campioni, intervallo, orario di partenza e file su R:\ (POST /api/light-reset).
  // Pagina: grafici, min/media/max/ora, strisce e frecce di tendenza, riferimento dei QPS live.
  // Le lancette non si toccano: continuano a mostrare il valore reale.
  function resetTrail(g) {
    if (g.trail) { while (g.trail.firstChild) g.trail.removeChild(g.trail.firstChild); }
    g.trailItems = [];
    g.lastV = null;
    g.arr.textContent = '\u2013';
    g.arr.setAttribute('fill', '#8497ab');
    g.arrTip.textContent = '';
  }
  function resetHistView(cfg) {
    histLeave(cfg);
    drawHist(cfg, { p: [] });
    ['min', 'avg', 'max', 'now'].forEach(function (k) {
      var e = document.getElementById('h' + cfg.n + k);
      e.textContent = '--';
      e.style.color = '';
    });
  }
  var resetting = false;
  document.getElementById('btnResetLight').addEventListener('click', async function () {
    if (resetting) return;
    if (!confirm('Vuoi svuotare lo storico dei due indicatori e ripartire da zero?\n\nSi azzerano grafici, minimo/media/massimo, frecce di tendenza e campioni raccolti. Le lancette continuano a mostrare i valori reali.')) return;
    resetting = true;
    var btn = this, label = btn.innerHTML;
    btn.disabled = true;
    try {
      var rr = await fetch('/api/light-reset', { method: 'POST', cache: 'no-store', headers: { 'X-Bunker-Light': '1' } });
      if (!rr.ok) throw new Error('HTTP ' + rr.status);
      histGen++;                       // scarta eventuali risposte di storico ancora in volo
      HC.forEach(resetHistView);
      G.forEach(resetTrail);
      prevQueries = 0; prevTime = 0;   // la prima lettura riparte senza riferimento precedente (QPS)
      lastSnap = ''; lastPost = 0;     // la prossima istantanea viene rielaborata e il primo campione parte subito
      btn.innerHTML = '&#9989; Storico azzerato';
      setTimeout(function () { btn.innerHTML = label; }, 1800);
    } catch (e) {
      alert('Impossibile azzerare lo storico: ' + e.message);
    } finally {
      resetting = false;
      btn.disabled = false;
    }
  });

  refresh();
  setInterval(refresh, 500);   // il server produce 1 istantanea/s: polling a 500 ms per non perderne nessuna e ridurre il ritardo
  setInterval(function () {
    if (lastLive() > 8000) {
      document.getElementById('gauges').classList.add('stale');
      document.getElementById('netStrip').classList.add('stale');
      setEngine('wait', 'CONNESSIONE PERSA');
      if (!restarting && !autoOverlay) {
        autoOverlay = true;
        document.getElementById('restartOverlay').classList.add('auto');
        showRestartOverlay('&#128472;&#65039;', 'Riavvio dashboard in corso...', 'In attesa che la Dashboard torni attiva: la pagina riprende da sola.');
      }
    }
  }, 1000);
  function lastLive() { return lastDataTs ? Date.now() - lastDataTs : 0; }
})();
</script>
</body>
</html>
'@

# === PAGINA PRO (rotta /pro): dashboard completa ===
$HtmlPage = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1106.3 - by Mauro Bigoni</title>
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

  /* ---------- Riga di rete: banda, IP, DNS del vincitore del radar ---------- */
  .netstrip { background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%); border: 1px solid var(--border-strong); border-radius: 14px; padding: 12px 16px; margin: 0 0 18px; text-align: left; font-family: var(--font-ui); transition: opacity 0.4s; }
  .netstrip.stale { opacity: 0.45; filter: grayscale(0.7); }
  .ns-meters { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
  .ns-pot { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin: 0 0 10px; padding: 8px 12px; font-size: 0.8em; border-radius: 10px; border: 1px solid rgba(79,179,255,0.30); background: linear-gradient(90deg, rgba(79,179,255,0.14) 0%, rgba(79,179,255,0.03) 100%); box-shadow: inset 3px 0 0 var(--accent); }
  .ns-pot.fb { border-color: var(--border-strong); background: rgba(255,255,255,0.03); box-shadow: inset 3px 0 0 var(--dim); }
  .ns-pot-l { font-size: 0.82em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-pot.run .ns-pot-l::after { content: ' \25CF'; color: #ffd600; animation: nsPotPulse 1.2s ease-in-out infinite; }
  .ns-pot-s { font-size: 0.82em; color: var(--dim); margin-top: 3px; line-height: 1.35; }
  .ns-pot-v { text-align: right; white-space: nowrap; }
  .ns-pot-v b { font-family: var(--font-mono); font-size: 2.1em; line-height: 1; color: var(--accent); letter-spacing: 0; }
  .ns-pot.fb .ns-pot-v b { color: var(--dim); }
  .ns-pot-v small { font-size: 0.8em; color: var(--dim); margin-left: 3px; }
  @keyframes nsPotPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }
  .ns-mh { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; font-size: 0.74em; color: var(--dim); margin-bottom: 5px; letter-spacing: 0.06em; text-transform: uppercase; }
  .ns-mh b { font-family: var(--font-mono); font-size: 1.7em; color: var(--text); letter-spacing: 0; }
  .ns-mh small { font-size: 0.9em; color: var(--dim); letter-spacing: 0; text-transform: none; font-weight: 400; }
  .ns-bar { display: grid; grid-template-columns: repeat(40, 1fr); gap: 2px; height: 12px; }
  .ns-bar i { border-radius: 2px; background: rgba(255,255,255,0.07); transition: background 0.25s; }
  .ns-sc { display: flex; justify-content: space-between; font-size: 0.7em; color: var(--dim); margin-top: 3px; font-family: var(--font-mono); }
  .ns-info { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--border); }
  .ns-c { background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 10px; padding: 8px 12px; min-width: 0; }
  .ns-c.win { border-color: rgba(61,220,132,0.45); }
  .ns-c.bad { border-color: rgba(255,92,92,0.45); }
  .ns-l { font-size: 0.68em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-v { font-family: var(--font-mono); font-size: 0.88em; font-weight: 700; color: var(--text); margin-top: 3px; word-break: break-all; line-height: 1.35; }
  .ns-s { font-size: 0.72em; color: var(--dim); margin-top: 2px; }
  .ns-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; background: var(--dim); }
  .ns-dot.ok { background: #3ddc84; box-shadow: 0 0 6px #3ddc84; }
  .ns-dot.bad { background: #ff5c5c; }
  @media (max-width: 900px) { .ns-info { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
  @media (max-width: 560px) { .ns-meters { grid-template-columns: 1fr; } }

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

  /* =====================================================================
     LAYER "PRO v2" - card raffinate e movimento fluido.
     Animazioni solo su transform/opacity (compositor), nessun repaint continuo.
     Ultimo blocco del foglio di stile: sovrascrive le regole precedenti.
     ===================================================================== */
  :root { --ease-out: cubic-bezier(0.22, 1, 0.36, 1); --ring: rgba(255,255,255,0.075); }

  /* Sfondo su layer fisso dedicato: niente repaint dello sfondo durante lo scroll */
  body { background: var(--bg); background-attachment: scroll; }
  body::before {
    content: ''; position: fixed; inset: 0; z-index: -1; pointer-events: none;
    background:
      radial-gradient(1200px 600px at 15% -10%, rgba(79,179,255,0.07), transparent 60%),
      radial-gradient(1000px 500px at 100% 0%, rgba(179,136,255,0.05), transparent 60%);
  }

  /* Titolo statico (lo shimmer ridisegnava il testo a ogni frame) */
  h1 { animation: none; background-size: 100% auto; background-position: 0 0; }

  /* ---------- Pannelli ---------- */
  .panel {
    position: relative; border-radius: 14px;
    background: linear-gradient(180deg, rgba(255,255,255,0.03) 0%, rgba(255,255,255,0) 45%), var(--panel);
    box-shadow: 0 1px 0 rgba(255,255,255,0.05) inset, 0 12px 32px -14px rgba(0,0,0,0.75);
    transition: border-color 0.35s var(--ease-out), box-shadow 0.35s var(--ease-out);
  }
  .panel:hover { border-color: rgba(79,179,255,0.2); box-shadow: 0 1px 0 rgba(255,255,255,0.06) inset, 0 18px 40px -16px rgba(0,0,0,0.8); }
  .panel-versioni:hover { border-color: rgba(79,179,255,0.4) !important; }
  .panel h2::before { width: 4px; height: 15px; background: linear-gradient(180deg, var(--accent), var(--purple)); box-shadow: 0 0 10px rgba(79,179,255,0.45); }

  /* ---------- Card metriche ---------- */
  .boost-item, .stat, .stat-card, .stat-ver, .periodic-task-chip {
    background: linear-gradient(160deg, rgba(255,255,255,0.045) 0%, rgba(255,255,255,0.012) 65%);
    border: 1px solid var(--ring);
    box-shadow: 0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 16px -9px rgba(0,0,0,0.7);
    transition: transform 0.3s var(--ease-out), border-color 0.3s var(--ease-out), box-shadow 0.3s var(--ease-out);
  }
  .boost-item { border-radius: 12px; padding: 13px 16px; }
  .boost-item:hover, .stat:hover, .stat-card:hover {
    transform: translateY(-2px); border-color: rgba(79,179,255,0.32);
    background: linear-gradient(160deg, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0.018) 65%);
    box-shadow: 0 1px 0 rgba(255,255,255,0.06) inset, 0 14px 26px -12px rgba(0,0,0,0.85), 0 0 0 1px rgba(79,179,255,0.06);
  }
  .stat-ver:hover, .periodic-task-chip:hover { border-color: rgba(79,179,255,0.35); }
  .stat-card:hover { transform: translateY(-2px); }
  .boost-item-header { letter-spacing: 0.06em; }
  .boost-item-val, .stat .val, .stat-card .sc-val { font-variant-numeric: tabular-nums; }

  /* ---------- Barre di avanzamento ---------- */
  .g-bar-bg { height: 8px; background: rgba(0,0,0,0.4); box-shadow: inset 0 1px 2px rgba(0,0,0,0.6); contain: layout paint; }
  .g-bar-fill { position: relative; transition: width 0.9s var(--ease-out), background 0.6s ease, background-color 0.6s ease; }
  .g-bar-fill::after { content: ''; position: absolute; inset: 0; border-radius: inherit; background: linear-gradient(180deg, rgba(255,255,255,0.24) 0%, rgba(255,255,255,0) 60%); pointer-events: none; }
  .bar-fill { transition: width 0.6s var(--ease-out); }

  /* ---------- Badge ---------- */
  .badge { transition: transform 0.25s var(--ease-out), box-shadow 0.3s var(--ease-out); box-shadow: 0 4px 12px -6px rgba(0,0,0,0.65), 0 1px 0 rgba(255,255,255,0.05) inset; }
  .badge:hover { transform: translateY(-1px); }
  .gain-highlight { transition: transform 0.25s var(--ease-out), box-shadow 0.4s ease; }

  /* ---------- Pulsanti: sfumatura e riflesso su opacity/transform ---------- */
  .btn-amber { --c: 255,179,0; } .btn-blue { --c: 79,179,255; } .btn-purple { --c: 179,136,255; }
  .btn-green { --c: 61,220,132; } .btn-red { --c: 255,92,92; } .btn-teal { --c: 45,212,191; } .btn-cyan { --c: 34,211,238; }
  .btn-action {
    position: relative; overflow: hidden; isolation: isolate; will-change: transform;
    backdrop-filter: none; -webkit-backdrop-filter: none;
    background: linear-gradient(180deg, rgba(var(--c),0.16) 0%, rgba(var(--c),0.05) 100%);
    border: 1px solid rgba(var(--c),0.28); border-top-color: rgba(var(--c),0.5);
    color: rgb(var(--c));
    box-shadow: 0 4px 14px -6px rgba(0,0,0,0.65), inset 0 1px 0 rgba(255,255,255,0.06);
    transition: transform 0.28s var(--ease-out), box-shadow 0.35s var(--ease-out), border-color 0.3s var(--ease-out), color 0.25s ease;
  }
  .btn-action::before { content: ''; position: absolute; inset: 0; z-index: -1; background: rgba(var(--c),0.16); opacity: 0; transition: opacity 0.3s var(--ease-out); }
  .btn-action::after { content: ''; position: absolute; top: 0; bottom: 0; left: 0; width: 55%; z-index: -1; opacity: 0; pointer-events: none;
    background: linear-gradient(100deg, transparent, rgba(255,255,255,0.15), transparent); transform: translateX(-130%) skewX(-18deg); }
  .btn-action:hover:not(:disabled) {
    transform: translateY(-2px);
    background: linear-gradient(180deg, rgba(var(--c),0.16) 0%, rgba(var(--c),0.05) 100%);
    border-color: rgba(var(--c),0.55); color: #ffffff;
    box-shadow: 0 10px 24px -8px rgba(var(--c),0.45), inset 0 1px 0 rgba(255,255,255,0.14);
  }
  .btn-action:hover:not(:disabled)::before { opacity: 1; }
  .btn-action:hover:not(:disabled)::after { opacity: 1; animation: btnSheen 0.85s var(--ease-out) 1; }
  .btn-action:active:not(:disabled) { transform: translateY(0) scale(0.985); transition-duration: 0.08s; box-shadow: 0 2px 8px -4px rgba(0,0,0,0.7); }
  @keyframes btnSheen { from { transform: translateX(-130%) skewX(-18deg); } to { transform: translateX(300%) skewX(-18deg); } }
  .btn-fase { transition: transform 0.2s var(--ease-out), background-color 0.2s ease, border-color 0.2s ease; }

  /* ---------- Overlay riavvio: senza blur (costoso con la barra animata) ---------- */
  .restart-overlay { backdrop-filter: none; -webkit-backdrop-filter: none; background: rgba(6,9,13,0.94); }
  .restart-overlay.active { animation: overlayIn 0.25s ease both; }
  .restart-overlay.active .restart-overlay-box { animation: boxIn 0.4s var(--ease-out) both; }
  @keyframes overlayIn { from { opacity: 0; } to { opacity: 1; } }
  @keyframes boxIn { from { opacity: 0; transform: translateY(14px) scale(0.97); } to { opacity: 1; transform: none; } }

  /* ---------- Tabelle ---------- */
  .table-scroll th { backdrop-filter: none; -webkit-backdrop-filter: none; background: var(--panel-2); }
  tbody tr { transition: background-color 0.2s ease; }

  /* ---------- Prestazioni: niente lavoro fuori schermo ---------- */
  .grid-three-columns ~ .panel { content-visibility: auto; contain-intrinsic-size: auto 340px; }
  .live-log-feed { contain: layout paint style; overscroll-behavior: contain; }
  .live-log-line { content-visibility: auto; contain-intrinsic-size: auto 26.5px; transition: background-color 0.2s ease; }

  /* ---------- Ingresso morbido, una sola volta al caricamento ---------- */
  @keyframes cardIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
  .button-row, .live-indicator, .badges-panel, .live-log-left > *, .live-log-panel, .bunker-rpz-panel, .boost-item { animation: cardIn 0.55s var(--ease-out) backwards; }
  .boost-item:nth-child(2) { animation-delay: 0.04s; } .boost-item:nth-child(3) { animation-delay: 0.08s; }
  .boost-item:nth-child(4) { animation-delay: 0.12s; } .boost-item:nth-child(5) { animation-delay: 0.16s; }
  .boost-item:nth-child(6) { animation-delay: 0.2s; }  .boost-item:nth-child(7) { animation-delay: 0.24s; }
  .boost-item:nth-child(8) { animation-delay: 0.28s; } .boost-item:nth-child(9) { animation-delay: 0.32s; }
  .boost-item:nth-child(10) { animation-delay: 0.36s; } .boost-item:nth-child(n+11) { animation-delay: 0.4s; }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation-duration: 0.001ms !important; animation-iteration-count: 1 !important; transition-duration: 0.001ms !important; }
  }
  /* ---------- Archi indicatore: stessa scala colori, valore, freccia di tendenza e storico della pagina Light ---------- */
  .g-arc { --p: 0; --tc: #8497ab; position: relative; width: 116px; height: 82px; margin: 4px auto 0; }
  .ga-clip { position: absolute; left: 0; top: 0; width: 116px; height: 58px; overflow: hidden; }
  .ga-dim, .ga-lit { position: absolute; left: 0; top: 0; width: 116px; height: 116px; border-radius: 50%; background: var(--arc-grad, #3ddc84); }
  .ga-dim { opacity: 0.2; -webkit-mask: radial-gradient(circle closest-side, transparent calc(100% - 10px), #000 calc(100% - 9.5px)); mask: radial-gradient(circle closest-side, transparent calc(100% - 10px), #000 calc(100% - 9.5px)); }
  .ga-lit {
    -webkit-mask-image: radial-gradient(circle closest-side, transparent calc(100% - 10px), #000 calc(100% - 9.5px)), conic-gradient(from -90deg, #000 calc(var(--p) * 1.8deg), transparent 0); -webkit-mask-composite: source-in;
    mask-image: radial-gradient(circle closest-side, transparent calc(100% - 10px), #000 calc(100% - 9.5px)), conic-gradient(from -90deg, #000 calc(var(--p) * 1.8deg), transparent 0); mask-composite: intersect;
  }
  .ga-c { position: absolute; top: 53px; width: 10px; height: 10px; border-radius: 50%; clip-path: inset(5px 0 0 0); }
  .ga-dl, .ga-ll { left: 0; background: #ff4d4d; }
  .ga-dr, .ga-lr { left: 106px; background: #3ddc84; }
  .ga-dl, .ga-dr { opacity: 0.2; }
  .ga-ll, .ga-lr { opacity: 0; }
  .g-arc.on-l .ga-ll, .g-arc.on-r .ga-lr { opacity: 1; }
  .ga-tip { position: absolute; left: 58px; top: 58px; width: 0; height: 0; transform: rotate(calc(-90deg + var(--p) * 1.8deg)); }
  .ga-tip::before {
    content: ''; position: absolute; left: -6px; top: -59px; width: 12px; height: 12px; box-sizing: border-box; border-radius: 50%;
    background: var(--tc); border: 2px solid #e9f2fb; box-shadow: 0 0 9px var(--tc);
  }
  .ga-val { position: absolute; left: 0; top: 33px; width: 116px; text-align: center; font-family: var(--font-mono); font-size: 17px; font-weight: 700; line-height: 1; color: #8497ab; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .ga-arr { position: absolute; left: 100%; top: 32px; margin-left: 8px; font-size: 15px; font-weight: 700; line-height: 1; color: #8497ab; cursor: default; }
  .ga-trail { position: absolute; left: 58px; top: 72px; width: 0; height: 0; }
  .ga-ti { position: absolute; left: -6px; top: -6px; width: 12px; height: 12px; transition: transform 0.5s cubic-bezier(0.22, 0.8, 0.3, 1), opacity 0.5s ease; }
  .ga-ti svg { display: block; width: 12px; height: 12px; overflow: visible; }
  @media (prefers-reduced-motion: reduce) { .ga-ti { transition: none; } }
</style>
</head>
<body>

<div class="status-banner sb-ok" id="statusBanner">
  <span class="sb-icon" id="statusBannerIcon">&#9989;</span>
  <span id="statusBannerText">ESECUZIONE REGOLARE</span>
</div>

<div class="header-container">
  <div>
    <h1>&#128737; UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1106.3 - by Mauro Bigoni</h1>
    <div class="sub" id="subheader">Connessione al Bunker in corso...</div>
  </div>
  <div class="clock-box">
    <div class="clock-time" id="clockTime">--:--:--</div>
    <div class="clock-date" id="clockDate">-----------------</div>
  </div>
</div>

<div class="button-row" id="buttonRow">
  <a href="/" id="btnGoLight" class="btn-action btn-blue" style="text-decoration:none; color:inherit;" title="Torna alla versione Light con i due indicatori">
    &#8592; Versione Light
  </a>
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
  <button id="btnForceLine" class="btn-action btn-blue" title="Avvia subito il test di velocit&agrave; reale della linea (download, poi upload: circa 15 secondi, occupa tutta la banda)">
    &#128225; Misura linea ora
  </button>
  <span id="forceLineStatus" class="muted button-row-status"></span>
  <button id="btnUpdateDash" onclick="confirmUpdateDashboard()" class="btn-action btn-red" title="Scarica dal repository GitHub l'ultima versione della dashboard e riavvia">
    &#11015;&#65039; Aggiorna Dashboard da GitHub
  </button>
  <span id="updateDashStatus" class="muted button-row-status"></span>
  <button id="btnUpdateComponents" onclick="confirmUpdateComponents()" class="btn-action btn-teal" title="Aggiorna tutti i componenti del Bunker: Dashboard (GitHub, con verifica SHA256) poi Unbound Engine + BAT + service.conf (rilanciando UnboundBunkerManager.BAT)">
    &#129513; Aggiorna Componenti
  </button>
  <span id="updateComponentsStatus" class="muted button-row-status"></span>
  <div id="bunkerGainContainer" style="margin-left: auto; display: flex; align-items: center;"></div>
</div>

<div class="netstrip" id="netStrip" style="margin-top:14px;">
  <div class="ns-meters">
    <div>
      <div class="ns-pot fb" id="nsPotDc" title="Potenziale velocit&agrave; della connessione internet: massimo misurato con un test reale a fine task AbuseCh30m (circa ogni 2 ore). Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11015;</div><div class="ns-pot-s" id="nsPotDs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotD">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span>&#11015; Download</span><span><b id="nsDv">--</b> <small>Mbps</small></span></div>
      <div class="ns-bar" id="nsDb"></div>
      <div class="ns-sc"><span>0</span><span id="nsDpk">picco 0 Mbps</span><span id="nsDmx">10</span></div>
    </div>
    <div>
      <div class="ns-pot fb" id="nsPotUc" title="Potenziale velocit&agrave; della connessione internet: massimo misurato con un test reale a fine task AbuseCh30m (circa ogni 2 ore). Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11014;</div><div class="ns-pot-s" id="nsPotUs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotU">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span>&#11014; Upload</span><span><b id="nsUv">--</b> <small>Mbps</small></span></div>
      <div class="ns-bar" id="nsUb"></div>
      <div class="ns-sc"><span>0</span><span id="nsUpk">picco 0 Mbps</span><span id="nsUmx">10</span></div>
    </div>
  </div>
  <div class="ns-info">
    <div class="ns-c"><div class="ns-l">IP pubblico</div><div class="ns-v" id="nsPub">N/D</div><div class="ns-s" id="nsPubS">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv4</div><div class="ns-v" id="nsV4">N/D</div><div class="ns-s" id="nsV4S">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv6</div><div class="ns-v" id="nsV6">N/D</div><div class="ns-s" id="nsV6S">&nbsp;</div></div>
    <div class="ns-c" id="nsDnsC"><div class="ns-l">DNS in uso</div><div class="ns-v" id="nsDns">N/D</div><div class="ns-s" id="nsDnsS">&nbsp;</div></div>
  </div>
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
/* ===== PRO v2: rendering senza sprechi (solo ASCII) ===== */
// 1) innerHTML: se il contenuto e' identico e il DOM non e' stato toccato da altro codice, non ricostruisce
//    (niente scatti, niente perdita di hover/scroll/details aperti).
(function () {
  var desc = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML');
  if (!desc || !desc.get || !desc.set) return;
  Object.defineProperty(Element.prototype, 'innerHTML', {
    configurable: true, enumerable: desc.enumerable,
    get: function () { return desc.get.call(this); },
    set: function (v) {
      var s = (v === null || v === undefined) ? '' : String(v);
      var c = this.__ih;
      if (c && c.h === s && c.n === this.childNodes.length && c.f === this.firstChild && c.l === this.lastChild) return;
      desc.set.call(this, v);
      this.__ih = { h: s, n: this.childNodes.length, f: this.firstChild, l: this.lastChild };
    }
  });
})();

// 2) Sostituisce i figli di target con quelli di src solo se il markup e' cambiato
function swapIfChanged(target, src) {
  var sig = src.innerHTML;
  if (target.__sw === sig) return;
  target.__sw = sig;
  target.replaceChildren.apply(target, Array.prototype.slice.call(src.childNodes));
}

// 3) Micro-animazione (Web Animations, compositor) quando cambia il valore di una card metrica
(function () {
  if (!window.MutationObserver || !Element.prototype.animate) return;
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var last = new WeakMap();
  var obs = new MutationObserver(function (recs) {
    var seen = new Set();
    recs.forEach(function (r) {
      var n = r.target.nodeType === 1 ? r.target : r.target.parentElement;
      var el = n && n.closest ? n.closest('.boost-item-val') : null;
      if (el) seen.add(el);
    });
    seen.forEach(function (el) {
      var t = el.textContent;
      var had = last.has(el);
      if (last.get(el) === t) return;
      last.set(el, t);
      if (!had || reduce) return;
      el.animate([{ opacity: 0.35, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }],
                 { duration: 450, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' });
    });
  });
  document.querySelectorAll('.boost-item-val').forEach(function (el) {
    last.set(el, el.textContent);
    obs.observe(el, { childList: true, characterData: true, subtree: true });
  });
})();

let prevQueries = 0;
let prevTime = Date.now();
let liveQPS = 0;
let maxQPS = 0;
let maxLatSeen = 0;
let isRefreshing = false;
let lastDataTs = 0;
let liveState = true;
const baseTitle = document.title;
let lastLoadTitle = null;

// Pallino di carico per il titolo della scheda (logica invertita rispetto alla Light: piu' alto = peggio)
// RAM: verde < 60, giallo 60-84, rosso >= 85 | CPU: verde < 50, giallo 50-79, rosso >= 80
function loadDot(p, warn, crit) {
  if (p === null || p === undefined || isNaN(p)) return '\u26AA';
  return p >= crit ? '\u{1F534}' : (p >= warn ? '\u{1F7E1}' : '\u{1F7E2}');
}
function loadTxt(p) { return (p === null || p === undefined || isNaN(p)) ? '--%' : Math.round(p) + '%'; }
function updateLoadTitle(sl) {
  if (!sl) return;
  lastLoadTitle = loadDot(sl.ram_pct, 60, 85) + ' \u{1F4B3} RAM ' + loadTxt(sl.ram_pct) + '  ' +
                  loadDot(sl.cpu_pct, 50, 80) + ' \u2699\uFE0F CPU ' + loadTxt(sl.cpu_pct);
  document.title = lastLoadTitle;
}
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
    document.title = lastLoadTitle || ('\u{1F7E2} ' + baseTitle);
  } else {
    dot.classList.remove('ok'); dot.classList.add('bad');
    badge.classList.remove('on'); badge.classList.add('off');
    label.textContent = 'DASHBOARD OFFLINE - Nessun dato da Unbound';
    track.classList.add('offline');
    document.title = '\u{1F534} OFFLINE - UNBOUND BUNKER CERBERO';
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

// === ARCHI INDICATORE: stessa scala colori, stesso valore, stessa freccia di tendenza e stesso storico della pagina Light ===
// Ogni barra "g-bar-fill" viene trasformata in un arco a semicerchio: arco intero attenuato + parte accesa fino al
// valore + pallino di punta + percentuale al centro (nel colore esatto del punto) + freccia ▲/▼ + striscia delle ultime
// variazioni. Disegno in CSS (sfumatura conica); il movimento usa la stessa molla critica della Light, in un unico
// ciclo condiviso a ~30 fps che si spegne quando tutti gli archi sono fermi (zero CPU a riposo).
const ARC_STOPS = [[0, [255, 77, 77]], [30, [255, 122, 47]], [55, [255, 179, 0]], [80, [155, 224, 74]], [100, [61, 220, 132]]];
const ARC_EPS = 0.05;          // punti percentuali: variazione minima per far comparire una freccia (1 decimale mostrato)
const ARC_TN = 14, ARC_TSP = 10;   // storico: numero di freccette e distanza tra l'una e l'altra
const ARC_FOLLOW_W = 9;        // rad/s: stessa reattivita' della Light
const ARC_REDUCED = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
function arcHex2(n) { n = Math.round(n); return (n < 16 ? '0' : '') + n.toString(16); }
function arcNum(v, d) { return Number(v).toFixed(d).replace('.', ','); }
function arcColor(p) {
  p = Math.max(0, Math.min(100, Number(p) || 0));
  for (let i = 1; i < ARC_STOPS.length; i++) {
    if (p <= ARC_STOPS[i][0]) {
      const a = ARC_STOPS[i - 1], b = ARC_STOPS[i];
      let t = (p - a[0]) / (b[0] - a[0]);
      t = t * t * (3 - 2 * t);   // raccordo morbido tra un colore e il successivo
      return '#' + arcHex2(a[1][0] + (b[1][0] - a[1][0]) * t) + arcHex2(a[1][1] + (b[1][1] - a[1][1]) * t) + arcHex2(a[1][2] + (b[1][2] - a[1][2]) * t);
    }
  }
  return '#3ddc84';
}
let arcStyleReady = false;
function arcInitStyle() {
  if (arcStyleReady) return;
  arcStyleReady = true;
  const st = [];
  for (let i = 0; i <= 40; i++) { const q = i * 2.5; st.push(arcColor(q) + ' ' + (q * 1.8).toFixed(2) + 'deg'); }
  document.documentElement.style.setProperty('--arc-grad', 'conic-gradient(from -90deg, ' + st.join(', ') + ')');
}

// ---- Storico delle variazioni: a destra la piu' recente, a ogni nuova variazione la fila scivola a sinistra ----
function arcTrailPlace(it) {
  const N = ARC_TN, slot = it.slot, out = slot < 0, f = out ? 0 : slot / (N - 1);
  const sc = out ? 0.3 : 0.5 + 0.5 * f;
  const x = -(N - 1) * ARC_TSP / 2 + slot * ARC_TSP;
  it.el.style.transform = 'translate(' + x.toFixed(1) + 'px,0) scale(' + sc.toFixed(3) + ')';
  it.el.style.opacity = out ? 0 : (0.16 + 0.84 * Math.pow(f, 1.2)).toFixed(3);
  it.el.style.filter = (slot === N - 1) ? 'drop-shadow(0 0 3px ' + it.col + ')' : 'none';
}
function arcPushTrail(a, up, diff, col) {
  const items = a.items;
  items.forEach(it => { it.slot--; });
  const e = document.createElement('span');
  e.className = 'ga-ti';
  e.innerHTML = '<svg viewBox="-6 -6 12 12"><path d="' + (up ? 'M0 -5 L5.5 4 L-5.5 4 Z' : 'M0 5 L5.5 -4 L-5.5 -4 Z') +
    '" fill="' + col + '" stroke="' + col + '" stroke-width="1.6" stroke-linejoin="round"/></svg>';
  e.title = new Date().toLocaleTimeString('it-IT') + '  ' + (up ? '+' : '-') + arcNum(Math.abs(diff), 2) + ' punti';
  const it = { el: e, slot: ARC_TN - 1, col: col };
  // posizione di partenza (piccola e trasparente, a destra) senza transizione, poi si anima verso quella finale
  e.style.transition = 'none';
  e.style.opacity = 0;
  e.style.transform = 'translate(' + (-(ARC_TN - 1) * ARC_TSP / 2 + ARC_TN * ARC_TSP).toFixed(1) + 'px,0) scale(0.2)';
  a.trail.appendChild(e);
  void e.getBoundingClientRect();
  e.style.transition = '';
  items.push(it);
  items.forEach(arcTrailPlace);
  const gone = items.filter(x => x.slot < 0);
  if (gone.length) {
    a.items = items.filter(x => x.slot >= 0);
    setTimeout(() => { gone.forEach(x => { if (x.el.parentNode) x.el.parentNode.removeChild(x.el); }); }, 700);
  }
}
// Tendenza rispetto al valore reale precedente (non alla posizione animata): ▲ verde = salito, ▼ rossa = sceso.
// La prima misura non genera frecce; tra due variazioni la freccia resta quella dell'ultima.
function arcTrend(a, v) {
  if (a.lastV === null) { a.lastV = v; return; }
  const diff = v - a.lastV;
  if (Math.abs(diff) < ARC_EPS) return;
  const up = diff > 0, col = up ? '#3ddc84' : '#ff5c5c';
  a.arr.textContent = up ? '\u25B2' : '\u25BC';
  a.arr.style.color = col;
  a.arr.title = (up ? '+' : '-') + arcNum(Math.abs(diff), 2) + ' punti rispetto al valore precedente';
  arcPushTrail(a, up, diff, col);
  a.lastV = v;
}

// ---- Disegno e animazione ----
function arcDraw(host) {
  const a = host._a, p = a.cur, c = arcColor(p);
  host.style.setProperty('--p', p.toFixed(2));
  host.style.setProperty('--tc', c);
  a.val.textContent = arcNum(p, 1) + '%';
  if (c !== a.col) { a.col = c; a.val.style.color = c; }
  host.classList.toggle('on-l', p > 0.2);
  host.classList.toggle('on-r', p >= 99.8);
}
const arcLive = new Set();
let arcRaf = 0, arcLast = 0;
function arcFrame(now) {
  arcRaf = 0;
  if (arcLast && now - arcLast < 28) { arcRaf = requestAnimationFrame(arcFrame); return; }   // ~30 fps bastano per archi piccoli
  const dt = arcLast ? Math.min(0.25, Math.max(0.001, (now - arcLast) / 1000)) : 0.033;
  arcLast = now;
  arcLive.forEach(host => {
    const a = host._a, dlt = a.cur - a.tgt, tmp = (a.vel + ARC_FOLLOW_W * dlt) * dt, ex = Math.exp(-ARC_FOLLOW_W * dt);
    a.cur = a.tgt + (dlt + tmp) * ex;
    a.vel = (a.vel - ARC_FOLLOW_W * tmp) * ex;
    if (Math.abs(a.cur - a.tgt) < 0.005 && Math.abs(a.vel) < 0.05) { a.cur = a.tgt; a.vel = 0; arcLive.delete(host); }
    else a.cur = Math.max(0, Math.min(100, a.cur));
    arcDraw(host);
  });
  if (arcLive.size) arcRaf = requestAnimationFrame(arcFrame); else arcLast = 0;
}
function arcSet(host, pct) {
  const a = host._a;
  if (!a) return;
  let p = Number(pct);
  if (!isFinite(p)) p = 0;
  p = Math.max(0, Math.min(100, p));
  arcTrend(a, p);
  a.tgt = p;
  host.setAttribute('aria-valuenow', String(Math.round(p)));
  if (ARC_REDUCED) { a.cur = p; a.vel = 0; arcLive.delete(host); arcDraw(host); a.shown = true; return; }
  if (a.cur !== a.tgt || !a.shown) {
    a.shown = true;
    arcLive.add(host);
    if (!arcRaf) arcRaf = requestAnimationFrame(arcFrame);
  }
}
// Converte (una sola volta) la vecchia barra in arco; l'id passa al contenitore, quindi getElementById continua a funzionare.
function arcEnsure(el) {
  if (!el) return null;
  if (el.classList.contains('g-arc')) return el;
  if (!el.classList.contains('g-bar-fill') || !el.parentNode) return null;
  arcInitStyle();
  const host = el.parentNode, id = el.id;
  el.removeAttribute('id');
  host.className = 'g-arc';
  host.id = id;
  host.setAttribute('role', 'meter');
  host.setAttribute('aria-valuemin', '0');
  host.setAttribute('aria-valuemax', '100');
  host.innerHTML = '<div class="ga-clip"><b class="ga-dim"></b><b class="ga-lit"></b></div>' +
    '<i class="ga-c ga-dl"></i><i class="ga-c ga-dr"></i><i class="ga-c ga-ll"></i><i class="ga-c ga-lr"></i><i class="ga-tip"></i>' +
    '<span class="ga-val">--</span><span class="ga-arr">\u2013</span><span class="ga-trail"></span>';
  host._a = { cur: 0, tgt: 0, vel: 0, lastV: null, col: '', shown: false, items: [],
              val: host.querySelector('.ga-val'), arr: host.querySelector('.ga-arr'), trail: host.querySelector('.ga-trail') };
  return host;
}
function arcInitAll() { document.querySelectorAll('.g-bar-fill[id]').forEach(arcEnsure); }
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', arcInitAll); else arcInitAll();

function updateGradientBar(id, pct) {
  const host = arcEnsure(document.getElementById(id));
  if (host) arcSet(host, pct);
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
    cont.__sigLog = null;
    cont.innerHTML = '<div class="muted">In attesa di eventi...</div>';
    return;
  }

  // Prende gli ultimi 1000 elementi nell'ordine nativo (dal meno recente al piu recente)
  // Stesso cap del server (Select-Object -Last 1000 in Get-LiveRcodeFeed).
  const voci = feed.slice(-1000);
  const sigLog = voci.length + '|' + JSON.stringify(voci[0]) + '|' + JSON.stringify(voci[voci.length - 1]) + '|' + ((d.live_feed_summary && d.live_feed_summary.totale) || 0);
  if (cont.__sigLog === sigLog) return;
  cont.__sigLog = sigLog;
  const wasAtBottom = (cont.scrollHeight - cont.scrollTop - cont.clientHeight) < 48;

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
  if (wasAtBottom) cont.scrollTop = cont.scrollHeight;
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

// ---- Riferimenti realistici per il 100% (stessi valori e stessa logica della pagina Light: tenerli allineati) ----
// Cache: nessun resolver arriva al 100% di hit (domini nuovi, TTL scaduti): BNK_CACHE_TARGET_PCT di hit = punteggio pieno.
// Latenza: il 100% e' relativo alla linea. RTT di riferimento = mediana, su finestra mobile, del tempo di connessione
// TCP verso gli upstream online misurato dall'Upstream Radar. Con DoT una risoluzione non costa meno di circa 4 RTT (handshake TLS + query + risoluzione dell'upstream).
var BNK_CACHE_TARGET_PCT = 80, BNK_LAT_FULL_RATIO = 4, BNK_RTT_FALLBACK_MS = 25, BNK_RTT_MIN_MS = 5, BNK_RTT_WINDOW = 120;
var bnkRttHist = [];
function bnkMedian(a) {
  var q = a.slice().sort(function (x, y) { return x - y; }), n = q.length;
  return n ? (n % 2 ? q[(n - 1) / 2] : (q[n / 2 - 1] + q[n / 2]) / 2) : 0;
}
function bnkLineRtt(radar) {
  var ms = radar.filter(function (r) { return r && r.ok && Number(r.ms) > 0 && Number(r.ms) < 400; }).map(function (r) { return Number(r.ms); });
  if (ms.length) { bnkRttHist.push(bnkMedian(ms)); if (bnkRttHist.length > BNK_RTT_WINDOW) bnkRttHist.shift(); }
  return bnkRttHist.length ? Math.max(BNK_RTT_MIN_MS, bnkMedian(bnkRttHist)) : BNK_RTT_FALLBACK_MS;
}
// Punteggio latenza = tempo medio di ricorsione / RTT: fino a 4x RTT 100%, 80% a 8x, 50% a 16x, minimo 15% a 32x (interpolazione lineare; i multipli scalano con BNK_LAT_FULL_RATIO).
function bnkLatScore(recMs, rtt) {
  var r = rtt > 0 ? recMs / rtt : 0, F = BNK_LAT_FULL_RATIO, P = [[F, 100], [2 * F, 80], [4 * F, 50], [8 * F, 15]];
  if (r <= P[0][0]) return 100;
  for (var i = 1; i < P.length; i++) {
    if (r <= P[i][0]) return Math.round((P[i - 1][1] + (P[i][1] - P[i - 1][1]) * (r - P[i - 1][0]) / (P[i][0] - P[i - 1][0])) * 100000) / 100000;
  }
  return P[P.length - 1][1];
}

/* ---------- Riga di rete: banda (autoscala), IP, DNS del vincitore del radar ---------- */
var NSN = 40, nsPkD = 0, nsPkU = 0, nsRingD = [], nsRingU = [];
function nsNice(v) { var st = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]; for (var i = 0; i < st.length; i++) { if (v <= st[i]) return st[i]; } return Math.ceil(v / 1000) * 1000; }
function nsFmt(v) { return (Math.round(v * 10) / 10).toFixed(1).replace('.', ','); }
function nsEsc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function nsPaint(id, v, mx) {
  var b = document.getElementById(id); if (!b) return;
  if (!b.children.length) { for (var i = 0; i < NSN; i++) b.appendChild(document.createElement('i')); }
  var on = Math.round(Math.min(v / mx, 1) * NSN);
  for (var j = 0; j < NSN; j++) {
    var f = j / NSN;
    b.children[j].style.background = j < on ? (f < 0.6 ? '#3ddc84' : (f < 0.85 ? '#ffb300' : '#ff5c5c')) : '';
  }
}
function nsSet(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
function nsMeter(v, ring, ids, pk) {
  ring.push(v); if (ring.length > 60) ring.shift();
  var mx = nsNice(Math.max.apply(null, ring) * 1.15);
  nsPaint(ids[0], v, mx);
  document.getElementById(ids[1]).textContent = nsFmt(v);
  document.getElementById(ids[2]).textContent = 'picco ' + Math.round(pk) + ' Mbps';
  document.getElementById(ids[3]).textContent = mx;
}
var nsLineHold = 0;
async function forceLineTest() {
  var btn = document.getElementById('btnForceLine'), st = document.getElementById('forceLineStatus');
  if (btn && btn.disabled) return;
  if (!confirm('Avviare subito il test di velocit\u00e0 della linea?\n\nDura circa 15 secondi: prima il download, poi l\'upload, e per qualche secondo occupa tutta la banda.')) return;
  nsLineHold = Date.now() + 8000;
  if (btn) { btn.disabled = true; btn.innerHTML = '&#9203; Avvio...'; }
  try {
    var res = await fetch('/api/force-line-test', { method: 'POST', cache: 'no-store' });
    var data = await res.json().catch(function () { return {}; });
    if (st) st.textContent = data.status === 'started' ? 'Test avviato alle ' + new Date().toLocaleTimeString('it-IT') + '.' : (data.status === 'busy' ? 'Un test \u00e8 gi\u00e0 in corso.' : 'Errore: ' + (data.error || 'sconosciuto'));
    if (data.status === 'error') nsLineHold = 0;
  } catch (e) {
    nsLineHold = 0;
    if (st) st.textContent = 'Errore di rete durante la richiesta.';
  }
  if (st) setTimeout(function () { st.textContent = ''; }, 30000);
}
(function () { var b = document.getElementById('btnForceLine'); if (b) b.addEventListener('click', forceLineTest); })();
function nsPotUpdate(d) {
  var p = d.line_potential, n = d.net_speed;
  var cfg = [['nsPotDc', 'nsPotD', 'nsPotDs', 'down_mbps'], ['nsPotUc', 'nsPotU', 'nsPotUs', 'up_mbps']];
  for (var i = 0; i < cfg.length; i++) {
    var c = document.getElementById(cfg[i][0]), v = document.getElementById(cfg[i][1]), s = document.getElementById(cfg[i][2]);
    if (!c || !v || !s) continue;
    if (p && p.ok && p[cfg[i][3]] > 0) {
      var pot = p[cfg[i][3]];
      v.textContent = pot >= 100 ? String(Math.round(pot)) : nsFmt(pot);
      var sub = nsEsc(p.testo);
      if (n && n.ok) sub += ' &middot; in uso ' + Math.round(Math.min(n[cfg[i][3]] / pot, 9.99) * 100) + '%';
      s.innerHTML = sub;
      c.className = 'ns-pot' + (p.fonte === 'scheda' ? ' fb' : '') + (p.in_corso ? ' run' : '');
    } else {
      v.textContent = 'N/D'; s.innerHTML = '&nbsp;'; c.className = 'ns-pot fb';
    }
  }
  var fb = document.getElementById('btnForceLine');
  if (fb) {
    var busy = !!(p && p.in_corso) || Date.now() < nsLineHold;
    fb.disabled = busy;
    fb.innerHTML = busy ? '&#9203; Test in corso...' : '&#128225; Misura linea ora';
  }
}
function nsUpdate(d) {
  nsPotUpdate(d);
  var n = d.net_speed;
  if (n && n.ok) {
    nsPkD = Math.max(nsPkD, n.down_mbps); nsPkU = Math.max(nsPkU, n.up_mbps);
    nsMeter(n.down_mbps, nsRingD, ['nsDb', 'nsDv', 'nsDpk', 'nsDmx'], nsPkD);
    nsMeter(n.up_mbps, nsRingU, ['nsUb', 'nsUv', 'nsUpk', 'nsUmx'], nsPkU);
  } else {
    document.getElementById('nsDv').textContent = 'N/D';
    document.getElementById('nsUv').textContent = 'N/D';
    nsPaint('nsDb', 0, 10); nsPaint('nsUb', 0, 10);
  }
  var ip = d.connettivita_ip;
  if (ip) {
    nsSet('nsPub', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_wan) : 'N/D');
    nsSet('nsPubS', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_loc || '') || '&nbsp;' : 'non disponibile');
    var l4 = ip.ipv4_lan_ok ? String(ip.ipv4_lan).split(', ') : [];
    nsSet('nsV4', l4.length ? nsEsc(l4[0]) : 'N/D');
    nsSet('nsV4S', '<span class="ns-dot ' + (l4.length ? 'ok' : 'bad') + '"></span>' + (l4.length ? 'rete locale' + (l4.length > 1 ? ' (+' + (l4.length - 1) + ')' : '') : 'offline'));
    var l6 = ip.ipv6_lan_ok ? String(ip.ipv6_lan).split(', ') : [];
    if (ip.ipv6_wan_ok) { nsSet('nsV6', nsEsc(ip.ipv6_wan)); nsSet('nsV6S', '<span class="ns-dot ok"></span>pubblico'); }
    else if (l6.length) { nsSet('nsV6', nsEsc(l6[0])); nsSet('nsV6S', '<span class="ns-dot ok"></span>solo locale'); }
    else { nsSet('nsV6', 'N/D'); nsSet('nsV6S', '<span class="ns-dot bad"></span>non disponibile'); }
  }
  var rad = d.upstream_radar; if (rad && !Array.isArray(rad)) rad = [rad];
  rad = rad || [];
  var win = null, okN = 0;
  rad.forEach(function (r) { if (r && r.ok) { okN++; if (!win || r.ms < win.ms) win = r; } });
  var c = document.getElementById('nsDnsC');
  if (win) {
    c.className = 'ns-c win';
    nsSet('nsDns', nsEsc(win.tag || 'Upstream') + ' ' + nsEsc(win.ip));
    nsSet('nsDnsS', '<span class="ns-dot ok"></span>vincitore radar \u00b7 ' + Math.round(win.ms) + ' ms \u00b7 ' + okN + '/' + rad.length);
  } else {
    c.className = rad.length ? 'ns-c bad' : 'ns-c';
    nsSet('nsDns', rad.length ? 'Nessun resolver raggiungibile' : 'N/D');
    nsSet('nsDnsS', rad.length ? '<span class="ns-dot bad"></span>radar 0/' + rad.length : '&nbsp;');
  }
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
    try { nsUpdate(d); } catch (e) { /* la riga di rete non deve mai bloccare il refresh */ }
    try { updateLoadTitle(d.bunker_features && d.bunker_features.sys_load); } catch (e) { /* il titolo non deve mai bloccare il refresh */ }

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
    // precisione piena: ricalcolo dai contatori grezzi (il server arrotonda a 1 decimale), come la pagina Light
    if (qTot > 0 && typeof cHits === 'number') realCachePct = Math.max(0, Math.min(100, (cHits / qTot) * 100));
    // Unbound conta come cache hit anche le risposte date dalle RPZ (blocchi): cache reale = hit al netto dei blocchi
    const baseP = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base : {};
    const repP = d.dall_ultimo_report || {};
    let blockedN = (typeof baseP.rpz_azioni === 'number' && baseP.rpz_azioni > 0) ? baseP.rpz_azioni : ((typeof repP.blocchi_totali === 'number') ? repP.blocchi_totali : 0);
    if (qTot > 0 && typeof cHits === 'number') {
      blockedN = Math.max(0, Math.min(qTot, blockedN));
      const resolvN = qTot - blockedN;
      realCachePct = resolvN > 0 ? Math.max(0, Math.min(100, (Math.max(0, cHits - blockedN) / resolvN) * 100)) : 0;
    }

    // latMs = total.recursion.time.avg: media delle sole query in ricorsione (cache miss).
    // La latenza media percepita include le risposte da cache (~0 ms): recLat * (1 - cache%).
    let recLat = latMs || 0;
    let latFromRadar = false;
    if (qTot === 0 && (!recLat || recLat <= 0) && radarList.length > 0) {
      const okRadars = radarList.filter(r => r.ok);
      if (okRadars.length > 0) {
        recLat = Math.round(okRadars.reduce((acc, r) => acc + r.ms, 0) / okRadars.length);
        latFromRadar = true;
      }
    }
    if (recLat < 0) recLat = 0;
    const cacheFrac = Math.max(0, Math.min(1, (realCachePct || 0) / 100));
    let effectiveLat = latFromRadar ? recLat : Math.round(recLat * (1 - cacheFrac) * 10) / 10;
    const latRaw = latFromRadar ? recLat : recLat * (1 - cacheFrac);   // non arrotondata: serve ai punteggi

    // Punteggi con 1 decimale (r1) per rendere visibili anche le oscillazioni minime.
    const r1 = v => Math.round(v * 10) / 10;
    const r5 = v => Math.round(v * 100000) / 100000;   // 5 decimali, come la pagina Light
    // Latenza: relativa alla linea (RTT misurato dal radar); cache: relativa all'obiettivo realistico (BNK_CACHE_TARGET_PCT)
    const refRtt = bnkLineRtt(radarList);
    const latScore = bnkLatScore(recLat, refRtt);
    const cacheScoreP = Math.min(100, r5((realCachePct || 0) / BNK_CACHE_TARGET_PCT * 100));

    let upstreamScore = radarList.length > 0 ? r5((upOk / radarList.length) * 100) : 100;

    const ds = (d.statistiche_live && d.statistiche_live.dnssec) ? d.statistiche_live.dnssec : { secure: 0, bogus: 0 };
    // Stessa logica della pagina Light: validazione provata da secure/bogus; rosso solo se assente dopo 100+ query risolvibili
    const dsSecP = Number(ds.secure) || 0, dsBogP = Number(ds.bogus) || 0;
    const resolvQP = Math.max(0, qTot - Math.max(0, Math.min(qTot, blockedN)));
    const dnssecStateP = (dsSecP + dsBogP > 0) ? 'ok' : (resolvQP >= 100 ? 'fail' : 'wait');
    let dnssecPct = dnssecStateP === 'fail' ? 0 : 100;

    const prefetchVal = (d.statistiche_live && d.statistiche_live.prefetch) ? d.statistiche_live.prefetch : 0;
    const PREFETCH_SENSITIVITY = 10;
    const prefetchRatioPct = (qTot > 0) ? (prefetchVal / qTot) * 100 : 0;
    const prefetchScore = Math.max(0, Math.min(100, Math.round(100 - (prefetchRatioPct * PREFETCH_SENSITIVITY))));

    let qpsHeadroom = Math.max(0, Math.min(100, r5(100 - (liveQPS / 5))));
    let healthScore = (d.salute_sistema && d.salute_sistema.score !== undefined) ? d.salute_sistema.score : 100;

    let boostScore = r5(
      (cacheScoreP * 0.30) + 
      (latScore * 0.25) + 
      (upstreamScore * 0.15) + 
      (dnssecPct * 0.15) + 
      (qpsHeadroom * 0.05) +
      (healthScore * 0.10)
    );

    // Baseline = latenza senza cache (tutte le query in ricorsione), mai sotto cio' che la linea consente (BNK_LAT_FULL_RATIO x RTT).
    const effectiveBaselineMs = Math.max(refRtt * BNK_LAT_FULL_RATIO, recLat);

    const displayLat = effectiveLat;
    const msSaved = Math.max(0, r5(effectiveBaselineMs - (latFromRadar ? displayLat : latRaw)));

    const latGainReal = Math.min(40, r5((msSaved / (effectiveBaselineMs * BNK_CACHE_TARGET_PCT / 100)) * 40));
    let blkPct = (d.statistiche_live && d.statistiche_live.base) ? d.statistiche_live.base.blocchi_pct : 0;
    if (qTot > 0) blkPct = Math.max(0, (blockedN / qTot) * 100);
    const rpzGainReal = Math.min(20, r5(blkPct * 0.8));
    const ramGainReal = (d.ram_disk && d.ram_disk.attivo) ? 10 : 2;
    const dotPrefetchGain = (radarList.length > 0 ? 5 * upOk / radarList.length : 0) + ((prefetchVal > 0 || realCachePct >= 50) ? 5 : 2);

    let totalBunkerGain = r5(latGainReal + rpzGainReal + ramGainReal + dotPrefetchGain);
    if (totalBunkerGain > 80) totalBunkerGain = 80;
    const gainIdx = r5((totalBunkerGain / 80) * 100);   // stesso indice % mostrato dalla pagina Light

    document.getElementById('valGainLat').textContent = latGainReal.toFixed(1) + ' / 40 pt';
    updateGradientBar('barGainLat', Math.round((latGainReal / 40) * 100));

    document.getElementById('valGainRpz').textContent = rpzGainReal.toFixed(1) + ' / 20 pt';
    updateGradientBar('barGainRpz', Math.round((rpzGainReal / 20) * 100));

    document.getElementById('valGainRam').textContent = ramGainReal + ' / 10 pt';
    updateGradientBar('barGainRam', Math.round((ramGainReal / 10) * 100));

    document.getElementById('valGainDot').textContent = dotPrefetchGain + ' / 10 pt';
    updateGradientBar('barGainDot', Math.round((dotPrefetchGain / 10) * 100));

    document.getElementById('valRealCache').textContent = Number(realCachePct).toFixed(1) + '% (obiettivo ' + BNK_CACHE_TARGET_PCT + '% = ' + cacheScoreP.toFixed(1) + '%)';
    updateGradientBar('barRealCache', cacheScoreP);

    document.getElementById('valLatScore').textContent = latScore.toFixed(1) + '% (' + Number(displayLat).toFixed(1) + ' ms \u00b7 linea ' + refRtt.toFixed(1) + ' ms)';
    updateGradientBar('barLatScore', latScore);

    document.getElementById('valUpstreamScore').textContent = upstreamScore.toFixed(1) + '% (' + upOk + '/' + radarList.length + ')';
    updateGradientBar('barUpstreamScore', upstreamScore);

    document.getElementById('valDnssecScore').innerHTML = dnssecPct + '% <span class="' + (dnssecStateP === 'fail' ? 'esito-warn' : 'esito-ok') + '">[SEC: ' + fmt(ds.secure) + ' | BOG: ' + fmt(ds.bogus) + (dnssecStateP === 'wait' ? ' | in attesa' : '') + ']</span>';
    updateGradientBar('barDnssecScore', dnssecPct);

    document.getElementById('valPrefetchScore').innerHTML = prefetchVal > 0 ? '<span class="esito-ok">' + prefetchScore + '% (' + fmt(prefetchVal) + ' rinnovi, ' + prefetchRatioPct.toFixed(2) + '% delle query)</span>' : '<span class="esito-ok">100% (Cache gi&agrave; ottimale, prefetch non necessario)</span>';
    updateGradientBar('barPrefetchScore', prefetchScore);

    document.getElementById('valQpsScore').textContent = qpsHeadroom.toFixed(1) + '% (Live: ' + liveQPS + ' | Max: ' + maxQPS.toFixed(1) + ' req/s)';
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
    updateGradientBar('barRpzRules', bf.total_rpz_rules > 0 ? rpzGlobalScore : 0);
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

    const cacheEffPct = Number(realCachePct.toFixed(1));   // cache reale: al netto delle risposte RPZ
    document.getElementById('valCacheEff').textContent = cacheEffPct + '%';
    updateGradientBar('barCacheEff', cacheEffPct);
    const totalHits = (d.statistiche_live && d.statistiche_live.base) ? (d.statistiche_live.base.cache_hits || 0) : 0;
    const totalMisses = Math.max(0, qTot - totalHits);
    document.getElementById('cacheEffDettaglio').innerHTML = `
      <div>&#127919; Cache Hits: <b style="color:var(--green-bright);">${fmt(totalHits)}</b></div>
      <div>&#127760; Recursive Misses: <b style="color:var(--amber-bright);">${fmt(totalMisses)}</b></div>
      <div>&#128202; Query Servite: <b style="color:var(--accent);">${fmt(qTot)}</b></div>
      <div>&#128737;&#65039; Risposte RPZ (escluse dalla cache): <b style="color:var(--red-bright);">${fmt(blockedN)}</b></div>
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

    const badgesLive = document.getElementById('badges');
    const badges = document.createElement('div');
    
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
    bCache.title = 'Cache reale (peso 30%): ' + realCachePct + '% \u2192 punteggio ' + cacheScoreP.toFixed(1) + '% (obiettivo ' + BNK_CACHE_TARGET_PCT + '%)\nEfficienza latenza (peso 25%, RTT linea ' + refRtt.toFixed(1) + ' ms): ' + latScore.toFixed(1) + '%\nUpstream DoT online (peso 15%): ' + upstreamScore.toFixed(1) + '%\nIntegrità DNSSEC (peso 15%): ' + dnssecPct + '%\nRiserva capacità QPS (peso 5%): ' + qpsHeadroom + '%\nSalute sistema (peso 10%): ' + healthScore + '%';
    bCache.innerHTML = '&#128640; BUNKER BOOST SCORE: <b>' + boostScore.toFixed(1) + '%</b>';
    badges.appendChild(bCache);
    swapIfChanged(badgesLive, badges);

    const bGain = document.createElement('span');
    bGain.className = 'badge gain-highlight';
    bGain.title = 'Guadagno latenza: ' + latGainReal.toFixed(1) + ' / 40 pt\nGuadagno blocchi RPZ: ' + rpzGainReal.toFixed(1) + ' / 20 pt\nGuadagno RAM disk: ' + ramGainReal + ' / 10 pt\nGuadagno DoT/Prefetch: ' + dotPrefetchGain + ' / 10 pt\nTotale: ' + totalBunkerGain.toFixed(1) + ' / 80 pt = ' + gainIdx.toFixed(1) + '%';

    let gainRatio = Math.min(1, Math.max(0, gainIdx / 100));
    let hueStart  = Math.round(38 + gainRatio * 92);
    let hueEnd    = Math.round(58 + gainRatio * 80);

    bGain.style.background = `linear-gradient(135deg, hsla(${hueStart}, 85%, 45%, 0.28) 0%, hsla(${hueEnd}, 90%, 48%, 0.38) 100%)`;
    bGain.style.borderColor = `hsl(${hueEnd}, 90%, 50%)`;
    bGain.style.boxShadow = `0 0 24px hsla(${hueEnd}, 90%, 50%, 0.6)`;

    bGain.innerHTML = '&#9889; BUNKER GAIN: <b style="color:hsl(' + hueEnd + ', 95%, 58%); font-size:1.32em;">+' + gainIdx.toFixed(1) + '%</b> <span style="font-size:0.88em; opacity:0.95; margin-left:6px;">(~' + msSaved.toFixed(1) + 'ms/req saved)</span>';

    const gainContainer = document.getElementById('bunkerGainContainer');
    if (gainContainer) {
      const gainTmp = document.createElement('div');
      gainTmp.appendChild(bGain);
      swapIfChanged(gainContainer, gainTmp);
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
      let feedRcode = d.live_rcode_feed || [];
      if (!Array.isArray(feedRcode)) { feedRcode = [feedRcode]; }
      const sigRcode = feedRcode.length + '|' + JSON.stringify(feedRcode[0] || null) + '|' + JSON.stringify(feedRcode[feedRcode.length - 1] || null);
      const rcodeChanged = (sigRcode !== window.__sigRcode) || tbodyRcode.rows.length === 0;
      window.__sigRcode = sigRcode;
      if (rcodeChanged) tbodyRcode.innerHTML = '';

      if (!rcodeChanged) {
        /* feed invariato: nessuna ricostruzione del DOM */
      } else if (feedRcode.length === 0) {
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
      if (rcodeChanged) filtraLiveRcode();
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
</script>
</body>
</html>
'@

# === RACCOLTA DATI IN BACKGROUND (runspace separato, thread indipendente) ===
function Start-BackgroundCollectorLoop {
    Write-DashLog "Ciclo di raccolta dati in background avviato (PID $PID)."
    while ($true) {
        $sleepMs = 1500
        $cycleSw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Raccolta COMPLETA solo se la pagina Pro e' stata richiesta di recente; altrimenti
            # raccolta MINIMA (solo cio' che serve ai due indicatori della Light).
            $proActive = $false
            if ($script:BunkerSyncHash) {
                $proActive = (((Get-Date) - $script:BunkerSyncHash.ProTs).TotalSeconds -lt $script:ProHoldSec)
            }
            if ($proActive) { Get-BunkerStatusJson | Out-Null }
            else {
                Get-BunkerStatusLightJson | Out-Null
                # Light: un'istantanea nuova ogni 1 s (periodo netto, non 1 s di pausa DOPO la raccolta)
                $sleepMs = [int][math]::Max(50, 1000 - $cycleSw.ElapsedMilliseconds)
            }
        } catch { Write-DashLog "Errore nel ciclo di raccolta background: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds $sleepMs
    }
}

function Start-BackgroundCollector {
    # Json/Ts = JSON completo (pagina Pro); JsonLight/TsLight = JSON ridotto (pagina Light);
    # ProTs = ultima richiesta della pagina Pro; ProSession = inizio dell'ultima "sessione Pro".
    $script:BunkerSyncHash = [hashtable]::Synchronized(@{
        Json = $null; Ts = [DateTime]::MinValue
        JsonLight = $null; TsLight = [DateTime]::MinValue
        ProTs = [DateTime]::MinValue; ProSession = [DateTime]::MinValue
    })

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
                $lightReq      = $request.Url.Query -match '(\?|&)mode=light(&|$)'
                $sync          = $script:BunkerSyncHash
                $json          = $null
                if ($lightReq) {
                    # LIGHT: JSON ridotto; se la Pro e' attiva e il JSON completo e' fresco va bene
                    # anche quello (e' un soprainsieme). La Light NON attiva la raccolta completa.
                    if ($sync) {
                        if ($sync.JsonLight -and ((Get-Date) - $sync.TsLight).TotalSeconds -lt 10) { $json = $sync.JsonLight }
                        elseif ($sync.Json -and ((Get-Date) - $sync.Ts).TotalSeconds -lt 10)       { $json = $sync.Json }
                    }
                    if (-not $json) { $json = Get-BunkerStatusLightJson }
                } else {
                    # PRO: segnala che serve la raccolta completa
                    Set-ProActive
                    if ($forceVersions) {
                        $json = Get-BunkerStatusJson -ForceVersions
                    } else {
                        if ($sync) {
                            # Alla prima richiesta di una nuova sessione Pro attende che il collector
                            # (passato in modalita' completa) abbia prodotto un JSON NUOVO.
                            $waitUntil = (Get-Date).AddSeconds(15)
                            while ((-not $sync.Json -or $sync.Ts -le $sync.ProSession) -and (Get-Date) -lt $waitUntil) {
                                Start-Sleep -Milliseconds 250
                            }
                            if ($sync.Json -and $sync.Ts -gt $sync.ProSession) { $json = $sync.Json }
                        }
                        if (-not $json) { $json = Get-BunkerStatusJson }
                    }
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/light-history") {
                $lhWin = 0
                [void][int]::TryParse([string]$request.QueryString["win"], [ref]$lhWin)
                if ($lhWin -gt 0) { $lh = Get-LightRecentJson -WinSec $lhWin } else { $lh = Get-LightHistoryJson }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($lh)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/light-sample" -and $request.HttpMethod -eq "POST") {
                # Riceve i due punteggi calcolati dalla pagina Light. Stesse difese di /api/run-phase:
                # header custom (blocca POST cross-site), controllo Host/Origin (anti DNS-rebinding),
                # valori numerici validati nell'intervallo 0..100.
                $lsStatus = 400
                $lsBody   = '{"ok":false}'
                try {
                    $hdrOk  = ([string]$request.Headers["X-Bunker-Light"] -eq "1")
                    $hostOk = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))
                    if (-not ($hdrOk -and $hostOk -and $origOk)) {
                        $lsStatus = 403
                    } elseif ($request.ContentLength64 -gt 512) {
                        $lsStatus = 413
                    } else {
                        $rdr = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $raw = $rdr.ReadToEnd(); $rdr.Close()
                        $o = $raw | ConvertFrom-Json
                        $bv = [double]$o.b; $gv = [double]$o.g
                        if (-not ([double]::IsNaN($bv) -or [double]::IsNaN($gv) -or $bv -lt 0 -or $bv -gt 100 -or $gv -lt 0 -or $gv -gt 100)) {
                            [void](Add-LightHistoryPoint -Boost $bv -Gain $gv)
                            $lsStatus = 200
                            $lsBody   = '{"ok":true}'
                        }
                    }
                } catch {
                    Write-DashLog "Errore in /api/light-sample: $($_.Exception.Message)"
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($lsBody)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $lsStatus
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/light-reset" -and $request.HttpMethod -eq "POST") {
                # Azzera lo storico dei due indicatori della pagina Light. Stesse difese di
                # /api/light-sample: header custom (blocca POST cross-site) e controllo Host/Origin.
                $lrStatus = 403
                $lrBody   = '{"ok":false}'
                try {
                    $hdrOk  = ([string]$request.Headers["X-Bunker-Light"] -eq "1")
                    $hostOk = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))
                    if ($hdrOk -and $hostOk -and $origOk) {
                        Reset-LightHistory
                        Write-DashLog "Storico pagina Light azzerato dall'utente."
                        $lrStatus = 200
                        $lrBody   = '{"ok":true}'
                    }
                } catch {
                    $lrStatus = 500
                    Write-DashLog "Errore in /api/light-reset: $($_.Exception.Message)"
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($lrBody)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $lrStatus
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
            } elseif ($request.Url.AbsolutePath -eq "/api/force-line-test" -and $request.HttpMethod -eq "POST") {
                Write-DashLog "Richiesta di misura forzata della linea ricevuta dall'interfaccia Web."
                $lineStatus = 'error'
                try {
                    $lineRes    = @(Start-LineSpeedTest -DelaySec 0)
                    $lineStatus = [string]$lineRes[-1]
                } catch { Write-DashLog "Errore in /api/force-line-test: $($_.Exception.Message)" }
                $script:LpCacheTime = [DateTime]::MinValue
                Write-DashLog "Esito avvio misura linea forzata: $lineStatus"
                $respObj = [ordered]@{ status = $lineStatus }
                if ($lineStatus -eq 'error') { $respObj.error = 'avvio del test non riuscito (vedi dashboard_error.log)' }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes(($respObj | ConvertTo-Json -Compress))
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                if ($lineStatus -eq 'error') { $response.StatusCode = 500 }
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
            } elseif ($request.Url.AbsolutePath -eq "/pro" -or $request.Url.AbsolutePath -eq "/pro/") {
                Set-ProActive
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPage)
                $response.ContentType = "text/html; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html") {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPageLight)
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
    $trayRunspace.SessionStateProxy.SetVariable('PidFile', $PidFile)
    $trayRunspace.SessionStateProxy.SetVariable('LogFile', $LogFile)
    
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
        
        # Chiude davvero la Dashboard (processo intero: server HTTP + raccolta dati + icona).
        # Il servizio Unbound NON viene toccato: la protezione DNS resta attiva.
        $MenuItemClose = New-Object System.Windows.Forms.MenuItem("Chiudi Dashboard")
        $MenuItemClose.add_Click({
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            try {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    $owner,
                    "Chiudere la Dashboard?`n`nLa pagina web e la raccolta dati si fermeranno.`nIl servizio Unbound e la protezione DNS restano attivi.",
                    "UNBOUND BUNKER",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question)
            } finally { $owner.Dispose() }
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

            try { "[$((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))] Chiusura Dashboard richiesta dal menu della tray icon." | Out-File -LiteralPath $LogFile -Append -Encoding utf8 } catch {}
            try { $TrayIcon.Visible = $false; $TrayIcon.Dispose() } catch {}
            try { if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } } catch {}
            [Environment]::Exit(0)
        })

        $Menu.MenuItems.Add($MenuItemOpen)
        $Menu.MenuItems.Add("-")
        $Menu.MenuItems.Add($MenuItemRestart)
        $Menu.MenuItems.Add("-")
        $Menu.MenuItems.Add($MenuItemClose)
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
