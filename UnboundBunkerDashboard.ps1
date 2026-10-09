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

# === POTENZIALE LINEA (v1106.5, indicatori a chevron v1106.6: test di velocita' reale abbinato al task Unbound_Bunker_AbuseCh30m) ===
#
# Il PC non conosce la capacita' della fibra: vede solo la scheda verso il router. Il "potenziale" e'
# quindi MISURATO: a fine esecuzione del task AbuseCh30m (transizione In esecuzione -> Inattivo) la
# Dashboard lancia in un runspace separato un test con 4 flussi curl.exe paralleli verso Cloudflare
# (prima il download, poi l'upload, mai insieme), ciascuno limitato a $script:LpTestSecs secondi.
# Il test parte ad ogni scoccare delle :00 e delle :30, DOPO le fasi previste per quell'orario: si segna
# "in attesa" appena parte AbuseCh30m o Unbound_Bunker_2h e si misura quando nessuna delle due e' piu' in
# esecuzione da $script:LpSettleSec secondi (copre le fasi consecutive). Parte solo se l'ultima misura ha
# piu' di $script:LpMinAgeMin minuti; ogni PC aggiunge un piccolo scaglionamento (0-70 s, dal nome host)
# per non misurare tutti insieme sulla stessa linea. Risultato in R:\line_potential.json (volatile
# come il resto di R:). Un lock su file (R:\line_test.run, creazione esclusiva) impedisce che due
# runspace della Dashboard (collector background + thread HTTP) lancino due test insieme.
# Finche' non c'e' la prima misura si mostra, come ripiego, la velocita' di collegamento della scheda.
$script:LpFile        = "R:\line_potential.json"
$script:LpLockFile    = "R:\line_test.run"
$script:LpTaskName    = 'Unbound_Bunker_AbuseCh30m'
$script:LpMinAgeMin   = 25
$script:LpTaskNames   = @('Unbound_Bunker_AbuseCh30m', 'Unbound_Bunker_2h')
$script:LpSettleSec   = 15
$script:LpPending     = $false
$script:LpIdleSince   = $null
$script:LpStagger     = 0
try { $lpH = 0; foreach ($lpC in ([string]$env:COMPUTERNAME).ToCharArray()) { $lpH += [int]$lpC }; $script:LpStagger = ($lpH % 8) * 10 } catch {}
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
    # pochi secondi dopo le fasi pianificate (Unbound sta ricaricando le RPZ), 0 per la misura forzata dal pulsante.
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
            try { if ((Test-Path -LiteralPath $lpLog) -and ((Get-Item -LiteralPath $lpLog).Length -gt 102400)) { Remove-Item -LiteralPath $lpLog -Force } } catch {}
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
                    param($argLine, $n, $lenient)
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
                        $size = 0.0; if ($parts.Count -gt 2) { [void][double]::TryParse($parts[2].Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $inv, [ref]$size) }
                        $ec = ''; try { $ec = [string]$pr.ExitCode } catch {}
                        # Valido: risposta 2xx, oppure interruzione per tempo massimo (exit 28, codice HTTP 000) con dati
                        # gia' trasferiti: un upload piu' lungo di --max-time non riceve mai la risposta dal server.
                        $tt = 0.0; if ($parts.Count -gt 3) { [void][double]::TryParse($parts[3].Trim().Replace(',', '.'), [System.Globalization.NumberStyles]::Float, $inv, [ref]$tt) }
                        $accept = ($httpCode -match '^2\d\d$')
                        # Upload (modo "lenient"): conta anche se il server chiude/rifiuta a meta' o non risponde, purche'
                        # siano passati almeno 1 MB in almeno 1 secondo (throughput reale misurato lato client).
                        if (-not $accept -and $lenient -and $size -ge 1000000 -and $tt -ge 1.0) { $accept = $true }
                        if ($okParse -and $accept) { $sum += $v }
                        $er = ''; try { $er = ([string]$errTask.Result).Trim() } catch {}
                        & $lpW ('  flusso: out=[' + $txt.Trim() + '] exit=' + $ec + ' valido=' + $accept + $(if ($er) { ' err=[' + $er + ']' } else { '' }))
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
                # Upload: prova piu' varianti (HTTP/2 poi HTTP/1.1 su Cloudflare, poi un secondo server) e si ferma
                # alla prima che produce una velocita' > 0. Ogni tentativo e' registrato nel log.
                $ulTries = @(
                    @{ Url = 'https://speed.cloudflare.com/__up'; Extra = '' },
                    @{ Url = 'https://speed.cloudflare.com/__up'; Extra = '--http1.1 ' },
                    @{ Url = 'https://speedtest.tele2.net/upload.php'; Extra = '--http1.1 ' }
                )
                $ul = 0.0
                foreach ($t in $ulTries) {
                    $argUp = '-s -L -A "Mozilla/5.0" -o NUL ' + $t.Extra + '-w "%{speed_upload}|%{http_code}|%{size_upload}|%{time_total}" --max-time ' + $Secs + ' --connect-timeout 5 -X POST -H "Content-Type: application/octet-stream" --data-binary "@' + $tmpUp + '" "' + $t.Url + '"'
                    & $lpW ('Upload verso ' + $t.Url + ' ' + $t.Extra.Trim())
                    $ul = & $runFlows $argUp $flows $true
                    if ($ul -gt 0) { break }
                }
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

        # Rilevamento della fine delle fasi pianificate (AbuseCh30m e 2h), controllo al massimo ogni 3 s.
        # Appena una fase risulta in esecuzione si segna "in attesa"; quando nessuna e' piu' in esecuzione
        # da almeno $script:LpSettleSec secondi parte il test (se l'ultima misura e' abbastanza vecchia).
        if (($now - $script:LpCheckTime).TotalSeconds -ge 3) {
            $script:LpCheckTime = $now
            $live    = Get-BunkerTasksLiveState
            $running = $false
            foreach ($tn in $script:LpTaskNames) { if ($live.ContainsKey($tn) -and $live[$tn]) { $running = $true } }
            if ($running) {
                $script:LpPending   = $true
                $script:LpIdleSince = $null
            } elseif ($script:LpPending) {
                if (-not $script:LpIdleSince) {
                    $script:LpIdleSince = $now
                } elseif ((($now - $script:LpIdleSince).TotalSeconds -ge $script:LpSettleSec) -and -not $script:LpAsync) {
                    $script:LpPending   = $false
                    $script:LpIdleSince = $null
                    $ageMin = 99999.0
                    if (Test-Path -LiteralPath $script:LpFile) {
                        $ageMin = ($now - (Get-Item -LiteralPath $script:LpFile).LastWriteTime).TotalMinutes
                    }
                    if ($ageMin -ge $script:LpMinAgeMin) { [void](Start-LineSpeedTest -DelaySec (5 + $script:LpStagger)) }
                }
            }
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
    ipv4_isp    = ""
    ipv6_wan    = "N/D"
    ipv6_wan_ok = $false
    ipv6_loc    = ""
    ipv6_isp    = ""
}
$script:WanAsync     = $null
$script:WanFailCount = 0
$script:LanCacheTime = [DateTime]::MinValue
$script:LanCacheData = $null

function Start-WanRefreshAsync {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        $ProgressPreference = 'SilentlyContinue'
        $ip4Wan = "N/D"; $loc4 = ""; $isp4 = ""
        $ip6Wan = "N/D"; $loc6 = ""; $isp6 = ""

        try {
            $r4 = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,city,country,isp,org,query' -TimeoutSec 3 -ErrorAction Stop
            if ($r4.status -eq 'success') {
                $ip4Wan = $r4.query
                $isp4   = if ($r4.isp) { [string]$r4.isp } elseif ($r4.org) { [string]$r4.org } else { "" }
                $loc4   = (@($r4.city, $r4.country) | Where-Object { $_ }) -join ', '
            }
        } catch {
            try {
                $r4 = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 3 -ErrorAction Stop
                if ($r4.ip) {
                    $ip4Wan = $r4.ip
                    $loc4   = (@($r4.city, $r4.country) | Where-Object { $_ }) -join ', '
                    # ipinfo restituisce "AS3269 Nome Provider": si toglie il prefisso ASN
                    $isp4   = if ($r4.org) { ([string]$r4.org) -replace '^AS\d+\s+', '' } else { "" }
                }
            } catch {}
        }

        try {
            $r6 = Invoke-RestMethod -Uri 'https://ipapi.co/json/' -TimeoutSec 3 -ErrorAction Stop
            if ($r6.ip -match ':') {
                $ip6Wan = $r6.ip
                $isp6   = if ($r6.org) { ([string]$r6.org) -replace '^AS\d+\s+', '' } else { "" }
                $loc6   = (@($r6.city, $r6.country_code) | Where-Object { $_ }) -join ', '
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

        [pscustomobject]@{ ip4 = $ip4Wan; loc4 = $loc4; isp4 = $isp4; ip6 = $ip6Wan; loc6 = $loc6; isp6 = $isp6 }
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
                    ipv4_isp    = $res.isp4
                    ipv6_wan    = $res.ip6
                    ipv6_wan_ok = ($res.ip6 -ne "N/D")
                    ipv6_loc    = $res.loc6
                    ipv6_isp    = $res.isp6
                }
            } else {
                # Un solo giro a vuoto puo' essere un timeout isolato: si tiene l'ultimo valore; al secondo consecutivo si passa a N/D
                $script:WanFailCount++
                if ($script:WanFailCount -ge 2) {
                    $script:WanCacheData = @{
                        ipv4_wan = "N/D"; ipv4_wan_ok = $false; ipv4_loc = ""; ipv4_isp = ""
                        ipv6_wan = "N/D"; ipv6_wan_ok = $false; ipv6_loc = ""; ipv6_isp = ""
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
        ipv4_isp    = $script:WanCacheData.ipv4_isp
        ipv6_wan    = $script:WanCacheData.ipv6_wan
        ipv6_wan_ok = $script:WanCacheData.ipv6_wan_ok
        ipv6_loc    = $script:WanCacheData.ipv6_loc
        ipv6_isp    = $script:WanCacheData.ipv6_isp
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
                    $rOra = $matches[1]; $rLista = $matches[2]; $rDom = $matches[3]
                    # [FIX] $matches[3] e' la REGOLA della lista (es. *.gvt2.com.): il dominio interrogato segue 'IP@porta'
                    if ($ln -match 'rpz-(?:nxdomain|nodata|passthru)\s+\S+@\d+\s+(\S+)') { $rDom = $matches[1] }
                    $feed += @{
                        orario    = $rOra
                        dominio   = $rDom.TrimEnd('.')
                        rcode     = $rcodeMap
                        resolver  = "$shield Scudo RPZ"
                        rpz_lista = $rLista
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

# === CONNESSIONI LIVE PER LA LIGHT (v1106.7; v1106.8: via cache/rete dal flag cache del log-replies; v1106.9: colonne Download/Upload disgiunte) ===
# Feed leggero e INCREMENTALE: come Get-LiveFeedSummary tiene un puntatore di posizione byte su R:\unbound.log e
# ad ogni chiamata legge e interpreta SOLO le righe nuove (costo proporzionale al traffico nuovo). Gli ultimi
# eventi finiscono in un piccolo buffer circolare con numero progressivo: la pagina Light mostra solo quelli
# che non ha ancora visto. Ogni evento ha: n (progressivo), t (orario), d (dominio), c (esito: NOERROR/NXDOMAIN/...),
# v (via: 'c' = risposta dalla cache RAM, 'n' = risposta arrivata dalla rete tramite un resolver upstream,
# 'r' = bloccata dallo scudo RPZ). Colonna Download della Light = tutti gli eventi (risposte servite al PC);
# colonna Upload = solo quelli con v='n' (domande uscite davvero verso internet: cache e RPZ non generano traffico).
# v1106.9: le due colonne sono DISGIUNTE. Ogni evento ha anche k ('u' = Upload, 'd' = Download):
#   Upload   = query realmente INVIATE a un resolver upstream (righe "sending query:" + "sending to target: IP#porta"),
#              sotto-query DNSSEC (DS/DNSKEY) comprese; v='n', ip = resolver di destinazione.
#   Download = risposte che ARRIVANO al PC: risposte realmente ricevute da un upstream ("reply from IP#porta" +
#              "query response was ...", v='n', ip), risposte servite dalla CACHE (v='c') e blocchi RPZ (v='r').
# La risposta finale al client di una risoluzione in rete (flag cache 0) NON e' ripetuta: c'e' gia' la risposta dell'upstream.
# Le richieste doppie 127.0.0.1 / ::1 (e A/AAAA nello stesso secondo) dello stesso dominio sono mostrate una volta sola.
# Se il log non contiene le righe di dettaglio degli upstream (verbosita' bassa) si ripiega sul vecchio comportamento.
$script:LightConnPos      = -1
$script:LightConnPending  = ""
$script:LightConnSeq      = 0
$script:LightConnRing     = New-Object System.Collections.Generic.List[object]
$script:LightConnUpstream = $false
$script:LightConnLast     = $null
$script:LcThrName         = @{}     # per thread: dominio dell'ultima query inviata / risposta in arrivo
$script:LcThrIp           = @{}     # per thread: resolver upstream dell'ultima risposta ricevuta
$script:LcThrType         = @{}     # per thread: tipo (A/AAAA/DS/DNSKEY...) dell'ultima query inviata / risposta in arrivo
# v1107.2: ogni evento porta anche q (tipo query), s (1 = sotto-query DNSSEC DS/DNSKEY, non richiesta da un programma)
#          e o (1 = traffico della dashboard stessa: geolocalizzazione IP, controllo versioni GitHub)
$script:LcOwnRx           = '^(ip-api\.com|ipinfo\.io|ipapi\.co|(ipv4\.|ipv6\.)?icanhazip\.com|api\.github\.com|raw\.githubusercontent\.com)$'
$script:LcDetail          = $false  # visto almeno un "sending to target": il log ha il dettaglio upstream
$script:LcRecentT         = ""      # secondo corrente per l'anti-doppione
$script:LcRecent          = @{}
# [v1107.9] Conteggi delle emoji mostrate ai lati dei badge Velocita linea (d = Download, u = Upload).
# LcFold = totali gia' attribuiti (chiave = codice paese a 2 lettere oppure _R/_DS/_DK/_SG/_PT/_NX/_ER/_WW per le icone speciali);
# LcDomCnt = domini in attesa del paese (si "piegano" in LcFold appena la bandierina e' risolta).
# Come per session_history.json, i totali sono salvati su RAM disk (R:\emoji_counts.txt, scrittura atomica ogni 15 s) insieme alla
# posizione di lettura del log: al riavvio della Dashboard si riparte da li' senza perdere ne' contare due volte le righe.
# Si azzerano solo con lo spegnimento reale del PC (R: e' volatile), non allo svuotamento biorario del log.
$script:LcFold      = @{ d = @{}; u = @{} }
$script:LcDomCnt    = @{ d = @{}; u = @{} }
$script:LcCcKnown   = @{}
$script:LcFlCache   = @{ d = @(); u = @() }
$script:LcFlCacheT  = $null
$script:LcCountFile = 'R:\emoji_counts.txt'
$script:LcSaveT     = $null
$script:LcCatchUp   = $false
if ($script:IsBackgroundCollector) {
    try {
        if ([System.IO.File]::Exists($script:LcCountFile)) {
            foreach ($lcLn in [System.IO.File]::ReadAllLines($script:LcCountFile, [System.Text.Encoding]::UTF8)) {
                $lcP = $lcLn.Split("`t")
                if ($lcP[0] -eq 'pos' -and $lcP.Count -ge 2) { $script:LightConnPos = [int64]$lcP[1]; $script:LcCatchUp = $true }
                elseif ($lcP.Count -ge 4 -and ($lcP[1] -eq 'd' -or $lcP[1] -eq 'u')) {
                    if ($lcP[0] -eq 'F') { $script:LcFold[$lcP[1]][$lcP[2]] = [int64]$lcP[3] }
                    elseif ($lcP[0] -eq 'P') { $script:LcDomCnt[$lcP[1]][$lcP[2]] = [int64]$lcP[3] }
                }
            }
        }
    } catch {}
}
$script:LightConnSrc      = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Anti-doppione: stesso dominio, stesso verso e stessa via nello stesso secondo (127.0.0.1 / ::1, A / AAAA) = un solo evento.
function Test-LightConnDup {
    param([string]$T, [string]$Key)
    if ($script:LcRecentT -ne $T) { $script:LcRecentT = $T; $script:LcRecent = @{} }
    if ($script:LcRecent.ContainsKey($Key)) { return $true }
    $script:LcRecent[$Key] = 1
    return $false
}

# === BANDIERA DEL PAESE DEL SERVER (v1107.4) ===
# Ogni dominio mostrato nel ticker Download/Upload della Light riceve una bandierina col paese del SUO server.
# Tutto locale e senza inviare nulla a terzi: il dominio si risolve in A con la rete locale (Unbound) e l'IPv4
# ottenuto si cerca in un database paese-per-intervallo IP (DB-IP Lite, CC BY 4.0, via sapics/ip-location-db su
# GitHub) scaricato SOLO IN MEMORIA (nessuna scrittura su SSD e nessun file su R:\). Il lavoro gira in un runspace
# separato (non blocca mai il ciclo da 1 s); il risultato per dominio e' in una cache condivisa (GeoState) che il
# feed copia nel campo geo della risposta. Se qualcosa fallisce non cambia nulla: le righe restano senza bandierina.
# Le query A fatte dal worker compaiono nel log di Unbound: finche' un dominio e' in lavorazione (GeoSelf, 6 s)
# le sue righe 'A' non vengono mostrate nel ticker, cosi' la bandierina non genera righe doppie.
# Nota: la geolocalizzazione per IP e' una stima (CDN/anycast possono risultare in un altro paese).
$script:GeoUrl4    = 'https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/dbip-country-ipv4.csv'
$script:GeoState   = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
$script:GeoQueue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:GeoSelf    = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,long]'
$script:GeoWorker  = $null
$script:GeoWorkerFail = 0

function Start-GeoWorker {
    if ($script:GeoWorker -or $script:GeoWorkerFail -ge 3) { return }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('GeoState', $script:GeoState)
        $rs.SessionStateProxy.SetVariable('GeoQueue', $script:GeoQueue)
        $rs.SessionStateProxy.SetVariable('GeoSelf',  $script:GeoSelf)
        $rs.SessionStateProxy.SetVariable('GeoUrl4',  $script:GeoUrl4)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $ErrorActionPreference = 'SilentlyContinue'
            $ProgressPreference    = 'SilentlyContinue'
            try { [System.Threading.Thread]::CurrentThread.Priority = [System.Threading.ThreadPriority]::BelowNormal } catch {}
            try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch {}
            $ready = $false; $lastTry = [DateTime]::MinValue
            $sa = $null; $ea = $null; $ca = $null
            while ($true) {
                if (-not $ready) {
                    # caricamento del database in memoria (riprova ogni 10 minuti se il download fallisce)
                    if (([DateTime]::UtcNow - $lastTry).TotalSeconds -ge 600) {
                        $lastTry = [DateTime]::UtcNow
                        try {
                            $wc = New-Object System.Net.WebClient
                            $bytes = $wc.DownloadData($GeoUrl4)
                            $wc.Dispose()
                            if ($bytes.Length -gt 3000000) {
                                $sl = New-Object 'System.Collections.Generic.List[long]'
                                $el = New-Object 'System.Collections.Generic.List[long]'
                                $cl = New-Object 'System.Collections.Generic.List[string]'
                                $ms = New-Object System.IO.MemoryStream(,$bytes)
                                $sr = New-Object System.IO.StreamReader($ms, [System.Text.Encoding]::ASCII)
                                while ($null -ne ($ln = $sr.ReadLine())) {
                                    $p = $ln.Split(',')
                                    if ($p.Length -lt 3) { continue }
                                    $a = $p[0].Split('.'); $b = $p[1].Split('.')
                                    if ($a.Length -ne 4 -or $b.Length -ne 4) { continue }
                                    [void]$sl.Add([long]$a[0] * 16777216 + [long]$a[1] * 65536 + [long]$a[2] * 256 + [long]$a[3])
                                    [void]$el.Add([long]$b[0] * 16777216 + [long]$b[1] * 65536 + [long]$b[2] * 256 + [long]$b[3])
                                    [void]$cl.Add([string]::Intern($p[2].Trim()))
                                }
                                $sr.Close(); $ms.Dispose()
                                $sa = $sl.ToArray(); $ea = $el.ToArray(); $ca = $cl.ToArray()
                                # controllo di coerenza: 8.8.8.8 deve risultare US (ordinamento e parsing corretti)
                                $chk = [long]8 * 16777216 + [long]8 * 65536 + [long]8 * 256 + [long]8
                                $ix = [Array]::BinarySearch($sa, $chk)
                                if ($ix -lt 0) { $ix = (-bnot $ix) - 1 }
                                if ($sa.Length -gt 100000 -and $ix -ge 0 -and $chk -le $ea[$ix] -and $ca[$ix] -eq 'US') { $ready = $true }
                            }
                        } catch {}
                        $bytes = $null; $sl = $null; $el = $null; $cl = $null
                        [System.GC]::Collect()
                    }
                    if (-not $ready) { Start-Sleep -Milliseconds 2000; continue }
                }
                $dom = $null
                if (-not $GeoQueue.TryDequeue([ref]$dom)) { Start-Sleep -Milliseconds 250; continue }
                if ($GeoSelf.Count -gt 500) { $GeoSelf.Clear() }
                # PTR IPv4: l'IP e' nel nome (ottetti al contrario), nessuna query DNS e nessun segnaposto GeoSelf
                $ptrIp = $null
                if ($dom -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)\.in-addr\.arpa$') { $ptrIp = $matches[4] + '.' + $matches[3] + '.' + $matches[2] + '.' + $matches[1] }
                else { $GeoSelf[$dom] = [DateTime]::UtcNow.Ticks + 60000000 }
                $cc = '-'; $retry = $false
                try {
                    $ipStr = $null
                    if ($ptrIp) { $ipStr = $ptrIp }
                    else {
                        $rr = Resolve-DnsName -Name $dom -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
                        foreach ($r in @($rr)) { if ($r.Type -eq 'A' -and $r.IPAddress) { $ipStr = [string]$r.IPAddress; break } }
                    }
                    if ($ipStr -and $ipStr -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
                        $v = [long]$matches[1] * 16777216 + [long]$matches[2] * 65536 + [long]$matches[3] * 256 + [long]$matches[4]
                        $ix = [Array]::BinarySearch($sa, $v)
                        if ($ix -lt 0) { $ix = (-bnot $ix) - 1 }
                        if ($ix -ge 0 -and $v -le $ea[$ix]) { $cc = $ca[$ix] }
                    }
                } catch {
                    $m = [string]$_.Exception.Message
                    if ($m -match 'timeout|timed out|period expired|1460') { $retry = $true }
                }
                if ($retry) { $tmp = ''; [void]$GeoState.TryRemove($dom, [ref]$tmp) }
                else { $GeoState[$dom] = $cc }
                Start-Sleep -Milliseconds 120
            }
        })
        $script:GeoWorker = @{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke() }
        Write-DashLog "Worker bandiere paese avviato (database DB-IP caricato in memoria al primo utilizzo)."
    } catch {
        $script:GeoWorkerFail++
        $script:GeoWorker = $null
        Write-DashLog "Worker bandiere paese NON avviato: $($_.Exception.Message)"
    }
}

function Request-GeoCountry {
    param([string]$Dom)
    try {
        $isPtr4 = ($Dom -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\.in-addr\.arpa$')
        if (-not $isPtr4) {
            if ($Dom.Length -lt 4 -or $Dom -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9-]{2,}$') { return }
            if ($Dom -match '\.(arpa|local|lan|internal|home|localdomain)$') { return }
        }
        if ($script:GeoState.ContainsKey($Dom)) { return }
        if ($script:GeoQueue.Count -gt 150) { return }
        if ($script:GeoState.Count -gt 3000) { $script:GeoState.Clear() }
        if ($script:GeoState.TryAdd($Dom, '')) {
            $script:GeoQueue.Enqueue($Dom)
            if (-not $script:GeoWorker) { Start-GeoWorker }
        }
    } catch {}
}

# [v1107.9] Il dominio e' eleggibile alla ricerca del paese? (stesse regole di Request-GeoCountry + traffico della dashboard)
function Test-GeoEligible {
    param([string]$Dom)
    if ($Dom -match $script:LcOwnRx) { return $false }
    if ($Dom -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\.in-addr\.arpa$') { return $true }
    if ($Dom.Length -lt 4 -or $Dom -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9-]{2,}$') { return $false }
    if ($Dom -match '\.(arpa|local|lan|internal|home|localdomain)$') { return $false }
    return $true
}

# [v1107.9] Salvataggio atomico dei conteggi su RAM disk (file temporaneo + rinomina), come session_history.json
function Save-EmojiCounts {
    try {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('pos' + "`t" + [string][int64]$script:LightConnPos + "`n")
        foreach ($k in @('d', 'u')) {
            foreach ($e in @($script:LcFold[$k].GetEnumerator())) { [void]$sb.Append('F' + "`t" + $k + "`t" + $e.Key + "`t" + $e.Value + "`n") }
            foreach ($e in @($script:LcDomCnt[$k].GetEnumerator())) { [void]$sb.Append('P' + "`t" + $k + "`t" + $e.Key + "`t" + $e.Value + "`n") }
        }
        $tmp = $script:LcCountFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:LcCountFile -Force
    } catch { Write-DashLog "Errore salvataggio conteggi emoji: $($_.Exception.Message)" }
}

function Add-LightConnEvent {
    param([string]$T, [string]$Dom, [string]$Code, [string]$Via, [string]$Kind = 'd', [string]$Ip = '', [string]$Qt = '')
    if ($Dom.Length -gt 90) { $Dom = $Dom.Substring(0, 90) }
    # v1107.4: la query A del worker bandiere per questo dominio non e' traffico dell'utente: non va mostrata
    if ($Qt -eq 'A' -and $Via -ne 'r' -and $script:GeoSelf.Count -gt 0) {
        $gx = [long]0
        if ($script:GeoSelf.TryGetValue($Dom, [ref]$gx)) {
            if ([DateTime]::UtcNow.Ticks -lt $gx) {
                if ($Via -eq 'c') { [void]$script:GeoSelf.TryRemove($Dom, [ref]$gx) }
                return
            }
            [void]$script:GeoSelf.TryRemove($Dom, [ref]$gx)
        }
    }
    $script:LightConnSeq++
    $sub = 0; if ($Qt -match '^(DS|DNSKEY|NSEC|NSEC3|NSEC3PARAM|RRSIG)$') { $sub = 1 }
    $own = 0; if ($Dom -match $script:LcOwnRx) { $own = 1 }
    $ev = @{ n = $script:LightConnSeq; t = $T; d = $Dom; c = $Code; v = $Via; k = $Kind; ip = $Ip; q = $Qt; s = $sub; o = $own }
    [void]$script:LightConnRing.Add($ev)
    while ($script:LightConnRing.Count -gt 40) { $script:LightConnRing.RemoveAt(0) }
    if ($Kind -eq 'd') { $script:LightConnLast = $ev }
    # [v1107.9] conteggio di OGNI icona mostrata nel ticker (stessa logica della Light): stop RPZ, chiave+lucchetto DS, chiave DNSKEY,
    # sigillo RRSIG/NSEC, PTR, punto interrogativo NXDOMAIN, avviso per gli errori; per le risposte normali la bandierina del paese
    $fold = $script:LcFold[$Kind]
    if ($fold) {
        $fkey = ''
        if ($Via -eq 'r') { $fkey = '_R' }
        elseif ($sub -eq 1) { if ($Qt -eq 'DS') { $fkey = '_DS' } elseif ($Qt -eq 'DNSKEY') { $fkey = '_DK' } else { $fkey = '_SG' } }
        elseif ($Dom -match '\.(in-addr|ip6)\.arpa$' -or $Qt -eq 'PTR') { $fkey = '_PT' }
        elseif ($Code -eq 'NXDOMAIN') { $fkey = '_NX' }
        elseif ($Code -ne 'NOERROR') { $fkey = '_ER' }
        elseif ($own -eq 1 -or -not (Test-GeoEligible $Dom)) { $fkey = '_WW' }
        else {
            $kn = [string]$script:LcCcKnown[$Dom]
            if ($kn) { $fkey = $kn }
            else {
                $dcm = $script:LcDomCnt[$Kind]
                if ($dcm.ContainsKey($Dom)) { $dcm[$Dom]++ } elseif ($dcm.Count -lt 5000) { $dcm[$Dom] = 1 }
            }
        }
        if ($fkey) { $fold[$fkey] = [int64]$fold[$fkey] + 1 }
    }
    if ($Kind -eq 'u' -and $sub -eq 0 -and $own -eq 0 -and $Code -eq 'NOERROR' -and $Via -ne 'r') { Request-GeoCountry $Dom }
    # bandierina: solo per risposte reali (NOERROR, non RPZ), non sotto-query DNSSEC e non traffico della dashboard
    if ($Kind -eq 'd' -and $Code -eq 'NOERROR' -and $Via -ne 'r' -and $sub -eq 0 -and $own -eq 0) { Request-GeoCountry $Dom }
}

function Get-LightConnFeed {
    try {
        if ([System.IO.File]::Exists($RpzLog)) {
            $fs = New-Object System.IO.FileStream($RpzLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $len       = $fs.Length
                $dropFirst = $false
                if ($script:LightConnPos -lt 0) {
                    # primo giro: parte vicino alla fine (niente rilettura dell'intero log)
                    $script:LightConnPos     = [math]::Max(0, $len - 65536)
                    $script:LightConnPending = ""
                    $dropFirst = ($script:LightConnPos -gt 0)
                }
                elseif ($len -lt $script:LightConnPos) {
                    # log svuotato (riavvio Unbound/Dashboard o ciclo biorario): si riparte dall'inizio
                    $script:LightConnPos     = 0
                    $script:LightConnPending = ""
                }
                elseif (($len - $script:LightConnPos) -gt $(if ($script:LcCatchUp) { 8388608 } else { 262144 })) {
                    # arretrato eccessivo (es. la Pro era aperta e questo feed non e' stato letto): salta alla coda
                    $script:LightConnPos     = $len - 262144
                    $script:LightConnPending = ""
                    $dropFirst = $true
                }

                if ($len -gt $script:LightConnPos) {
                    $toRead = $len - $script:LightConnPos
                    [void]$fs.Seek($script:LightConnPos, [System.IO.SeekOrigin]::Begin)
                    $buf = New-Object byte[] $toRead
                    $off = 0
                    while ($off -lt $toRead) {
                        $n = $fs.Read($buf, $off, $toRead - $off)
                        if ($n -le 0) { break }
                        $off += $n
                    }
                    $script:LightConnPos += $off
                    $script:LcCatchUp = $false

                    $text  = $script:LightConnPending + [System.Text.Encoding]::UTF8.GetString($buf, 0, $off)
                    $parts = $text -split "`n"
                    # l'ultima porzione puo' essere una riga ancora incompleta: resta da parte per il prossimo giro
                    $script:LightConnPending = $parts[-1]
                    if ($parts.Count -gt 1) {
                        $startIdx = 0
                        if ($dropFirst) { $startIdx = 1 }   # prima riga probabilmente troncata a meta'
                        for ($i = $startIdx; $i -lt ($parts.Count - 1); $i++) {
                            $ln = $parts[$i].TrimEnd("`r")
                            if ($ln.Length -lt 20) { continue }
                            $th = ''
                            if ($ln -match '\[(\d+:\d+)\]') { $th = $matches[1] }
                            $lt = ''
                            if ($ln -match '(\d{2}:\d{2}:\d{2})') { $lt = $matches[1] }
                            if ($ln -match 'info:\s+sending query:\s+(\S+)\s+(\S+)\s+IN') {
                                $script:LcThrName[$th] = $matches[1].TrimEnd('.')
                                $script:LcThrType[$th] = $matches[2]
                            }
                            elseif ($ln -match 'debug:\s+sending to target:\s+<[^>]*>\s+(\S+?)#\d+') {
                                # UPLOAD: query davvero inviata a un resolver upstream (DS/DNSKEY del DNSSEC compresi)
                                $script:LcDetail = $true
                                $upIp = $matches[1]
                                $upDom = $script:LcThrName[$th]
                                if ($upDom) { Add-LightConnEvent -T $lt -Dom $upDom -Code 'NOERROR' -Via 'n' -Kind 'u' -Ip $upIp -Qt $script:LcThrType[$th] }
                            }
                            elseif ($ln -match 'info:\s+response for\s+(\S+)\s+(\S+)\s+IN') {
                                $script:LcThrName[$th] = $matches[1].TrimEnd('.')
                                $script:LcThrType[$th] = $matches[2]
                            }
                            elseif ($ln -match 'info:\s+reply from\s+<[^>]*>\s+(\S+?)#\d+') {
                                $script:LcThrIp[$th] = $matches[1]
                            }
                            elseif ($ln -match 'info:\s+query response was\s+(.+)$') {
                                # DOWNLOAD: risposta realmente ricevuta dall'upstream
                                $rs = $matches[1].ToUpper()
                                $rc = 'NOERROR'
                                if ($rs -match 'NXDOMAIN') { $rc = 'NXDOMAIN' }
                                elseif ($rs -match 'SERVFAIL') { $rc = 'SERVFAIL' }
                                elseif ($rs -match 'REFUSED') { $rc = 'REFUSED' }
                                elseif ($rs -match 'FORMERR') { $rc = 'FORMERR' }
                                $dnDom = $script:LcThrName[$th]; $dnIp = $script:LcThrIp[$th]
                                if ($dnDom -and $dnIp) { Add-LightConnEvent -T $lt -Dom $dnDom -Code $rc -Via 'n' -Kind 'd' -Ip $dnIp -Qt $script:LcThrType[$th] }
                                $script:LcThrIp.Remove($th)
                            }
                            elseif ($ln -match 'info:\s+sending query to\s+[0-9a-fA-F.:]+') {
                                $script:LightConnUpstream = $true
                            }
                            elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\s+info:\s+\S+\s+(\S+)\s+(?<qt>\S+)\s+IN\s+(NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR)(?:\s+([0-9.]+)\s+([01])\s+\d+)?') {
                                $t = $matches[1]; $dom = $matches[2].TrimEnd('.'); $code = $matches[3].ToUpper(); $qt0 = $matches['qt']
                                # Il log-replies di Unbound chiude la riga con: durata, flag cache (1 = servita dalla cache, 0 = risolta
                                # in rete verso un upstream), dimensione. E' il segnale affidabile per distinguere cache e rete; solo se
                                # mancano quei campi si ripiega sulla riga "sending query to" vista poco prima.
                                $cf = $matches[5]
                                $via = 'c'
                                if ($null -ne $cf) { if ($cf -eq '0') { $via = 'n' } }
                                elseif ($script:LightConnUpstream) { $via = 'n' }
                                $script:LightConnUpstream = $false
                                # la riga di risposta che segue subito una riga RPZ dello stesso dominio e secondo e' lo stesso evento
                                $dup = $false
                                $lastEv = $script:LightConnLast
                                if ($lastEv -and $lastEv.v -eq 'r' -and $lastEv.d -eq $dom -and $lastEv.t -eq $t) { $dup = $true }
                                if (-not $dup) {
                                    if ($via -eq 'n' -and $script:LcDetail) {
                                        # gia' mostrata come risposta dell'upstream (Download) e query inviata (Upload)
                                    }
                                    elseif ($via -eq 'n') {
                                        # log senza dettaglio upstream: ripiego, la stessa risoluzione compare in entrambe le colonne
                                        if (-not (Test-LightConnDup -T $t -Key ($dom + '|d|n'))) {
                                            Add-LightConnEvent -T $t -Dom $dom -Code $code -Via 'n' -Kind 'u' -Qt $qt0
                                            Add-LightConnEvent -T $t -Dom $dom -Code $code -Via 'n' -Kind 'd' -Qt $qt0
                                        }
                                    }
                                    elseif (-not (Test-LightConnDup -T $t -Key ($dom + '|d|c'))) {
                                        Add-LightConnEvent -T $t -Dom $dom -Code $code -Via $via -Kind 'd' -Qt $qt0
                                    }
                                }
                            }
                            elseif ($ln -match '(\d{2}:\d{2}:\d{2}).*?\[([a-zA-Z0-9_\-]+)\].*?(\S+)\s+rpz-(nxdomain|nodata|passthru)') {
                                $code = 'NOERROR'
                                $rT = $matches[1]; $rK = $matches[4]; $rDom = $matches[3]
                                if ($rK -eq 'nxdomain') { $code = 'NXDOMAIN' }
                                # [FIX] $matches[3] e' la REGOLA della lista (es. *.gvt2.com.), non il dominio interrogato:
                                # il dominio reale segue 'IP@porta' (rpz-nxdomain 127.0.0.1@54639 beacons.gcp.gvt2.com. A IN).
                                # Cosi' la risposta successiva (stesso dominio, flag cache 1) viene riconosciuta come duplicato.
                                $rQt = ''
                                if ($ln -match 'rpz-(?:nxdomain|nodata|passthru)\s+\S+@\d+\s+(\S+)(?:\s+(\S+)\s+IN)?') { $rDom = $matches[1]; if ($matches[2]) { $rQt = $matches[2] } }
                                $script:LightConnUpstream = $false
                                if (-not (Test-LightConnDup -T $rT -Key ($rDom.TrimEnd('.') + '|d|r'))) {
                                    Add-LightConnEvent -T $rT -Dom $rDom.TrimEnd('.') -Code $code -Via 'r' -Kind 'd' -Qt $rQt
                                }
                            }
                        }
                    }
                }
            } finally { $fs.Close() }
        }
    } catch {}
    # v1107.4: paese del server per i domini presenti nel registro (solo quelli gia' risolti)
    $geoOut = @{}
    try {
        foreach ($ge in $script:LightConnRing) {
            $gv = ''
            if ($script:GeoState.TryGetValue([string]$ge.d, [ref]$gv)) { if ($gv) { $geoOut[[string]$ge.d] = $gv } }
        }
    } catch {}
    # [v1107.9] classifica emoji (bandierine + icone speciali _XX): ricalcolata al massimo ogni 2 s; i domini in attesa si "piegano" nei totali
    try {
        if (-not $script:LcFlCacheT -or ((Get-Date) - $script:LcFlCacheT).TotalSeconds -ge 2) {
            if ($script:LcCcKnown.Count -gt 20000) { $script:LcCcKnown = @{} }
            foreach ($fk in @('d', 'u')) {
                $dcm = $script:LcDomCnt[$fk]; $fold = $script:LcFold[$fk]
                foreach ($dom in @($dcm.Keys)) {
                    $gs = ''
                    $has = $script:GeoState.TryGetValue([string]$dom, [ref]$gs)
                    $fcc = ''
                    if ($gs -match '^[A-Z]{2}$') { $fcc = $gs; $script:LcCcKnown[[string]$dom] = $gs }
                    elseif ($gs -eq '-') { $fcc = '_WW' }
                    elseif (-not $has) { Request-GeoCountry ([string]$dom) }
                    if ($fcc) { $fold[$fcc] = [int64]$fold[$fcc] + [int64]$dcm[$dom]; $dcm.Remove($dom) }
                }
                $farr = @()
                foreach ($fa in ($fold.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 80)) { $farr += @{ cc = $fa.Key; n = $fa.Value } }
                $script:LcFlCache[$fk] = $farr
            }
            $script:LcFlCacheT = Get-Date
        }
        # salvataggio su R:\ ogni 15 s (solo il raccoglitore in background, per non avere due scrittori)
        if ($script:IsBackgroundCollector) {
            if (-not $script:LcSaveT) { $script:LcSaveT = Get-Date }
            elseif (((Get-Date) - $script:LcSaveT).TotalSeconds -ge 15) { $script:LcSaveT = Get-Date; Save-EmojiCounts }
        }
    } catch {}
    return [ordered]@{ src = $script:LightConnSrc; ev = $script:LightConnRing.ToArray(); geo = $geoOut; fl = $script:LcFlCache }
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
    $connLive    = Get-LightConnFeed
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
        conn_live        = $connLive
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
    # Connessioni live (colonne Download/Upload): lettura incrementale delle sole righe nuove del log
    $connLive = Get-LightConnFeed
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
        conn_live        = $connLive
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

# === PAGINA SHELL (rotta / e /pro aperte come pagina principale del browser): contiene la radio, che non viene mai ricaricata, e la dashboard (Light/Pro) in un frame ===
$HtmlShell = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UNBOUND BUNKER CERBERO</title>
<link rel="icon" id="shellIcon" href="data:,">
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #000; color-scheme: dark; overflow: hidden; }
  body { display: flex; flex-direction: column; position: relative; }
  #radioBar { flex: 0 0 auto; display: flex; align-items: center; justify-content: center; gap: 12px; height: 52px; padding: 0 14px; background: #000; border-bottom: 1px solid #222; color: #e8e8e8; font-family: Segoe UI, Arial, sans-serif; font-size: 14px; user-select: none; }
  #radioBtn { width: 34px; height: 34px; border-radius: 50%; border: 1px solid #555; background: #111; color: #fff; font-size: 14px; cursor: pointer; padding: 0; line-height: 1; }
  #radioBtn:hover { background: #222; border-color: #888; }
  #radioViz { flex: 0 0 auto; display: flex; align-items: flex-end; gap: 2px; width: 110px; height: 30px; opacity: 0; transition: opacity .25s; }
  #radioViz.on { opacity: 1; }
  #radioViz .vb { flex: 0 0 5px; width: 5px; height: 2px; border-radius: 1px; }
  #radioIcon { flex: 0 0 auto; font-size: 18px; }
  #radioSel { flex: 0 0 auto; max-width: 220px; height: 30px; padding: 0 8px; background: #111; color: #fff; border: 1px solid #555; border-radius: 6px; font-family: inherit; font-size: 14px; font-weight: 700; cursor: pointer; }
  #radioSel:hover { border-color: #888; }
  #radioAddBtn, #radioDelBtn { flex: 0 0 auto; width: 30px; height: 30px; border-radius: 6px; border: 1px solid #555; background: #111; color: #fff; font-size: 20px; line-height: 1; padding: 0; cursor: pointer; }
  #radioAddBtn:hover, #radioDelBtn:hover { background: #222; border-color: #888; }
  #radioDelBtn { color: #ff7b7b; }
  #radioAdd { position: absolute; top: 53px; left: 50%; transform: translateX(-50%); z-index: 20; width: min(600px, 94vw); box-sizing: border-box; padding: 14px; background: #0b0b0b; border: 1px solid #444; border-radius: 10px; box-shadow: 0 8px 30px rgba(0,0,0,0.7); color: #e8e8e8; font-family: Segoe UI, Arial, sans-serif; font-size: 14px; }
  #radioAdd[hidden] { display: none; }
  #radioAdd .ra-row { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  #radioAdd .ra-row:last-child { margin-bottom: 0; }
  #radioAdd label { flex: 0 0 52px; color: #9a9a9a; }
  #radioAdd input { flex: 1 1 auto; min-width: 0; height: 32px; padding: 0 10px; background: #111; color: #fff; border: 1px solid #555; border-radius: 6px; font: inherit; }
  #radioAdd input:focus { outline: none; border-color: #4fb3ff; }
  #radioAdd button { height: 32px; padding: 0 14px; border-radius: 6px; border: 1px solid #555; background: #151515; color: #fff; font: inherit; cursor: pointer; }
  #radioAdd button:hover:not(:disabled) { background: #222; border-color: #888; }
  #radioAdd button:disabled { opacity: 0.5; cursor: default; }
  #raSave { border-color: #4fb3ff; }
  #raMsg { flex: 1 1 auto; font-size: 12px; color: #9a9a9a; }
  #raMsg.err { color: #ff7b7b; }
  #raHint { margin: 0 0 10px 0; font-size: 12px; color: #8a8a8a; line-height: 1.4; }
  #radioDel { position: absolute; top: 53px; left: 50%; transform: translateX(-50%); z-index: 20; width: min(600px, 94vw); box-sizing: border-box; padding: 14px; background: #0b0b0b; border: 1px solid #5a2a2a; border-radius: 10px; box-shadow: 0 8px 30px rgba(0,0,0,0.7); color: #e8e8e8; font-family: Segoe UI, Arial, sans-serif; font-size: 14px; }
  #radioDel[hidden] { display: none; }
  #radioDel .ra-row { display: flex; align-items: flex-start; gap: 10px; margin-bottom: 10px; }
  #radioDel .ra-row:last-child { margin-bottom: 0; align-items: center; flex-wrap: wrap; justify-content: flex-end; }
  #radioDel label { flex: 0 0 52px; color: #9a9a9a; padding-top: 6px; }
  #radioDel input, #radioDel textarea { flex: 1 1 auto; min-width: 0; box-sizing: border-box; padding: 0 10px; background: #111; color: #cfcfcf; border: 1px solid #444; border-radius: 6px; font: inherit; }
  #radioDel input { height: 32px; }
  #radioDel textarea { padding: 6px 10px; resize: none; line-height: 1.4; overflow-y: auto; }
  #radioDel input:focus, #radioDel textarea:focus { outline: none; }
  #radioDel button { flex: 0 0 auto; white-space: nowrap; height: 32px; padding: 0 14px; border-radius: 6px; border: 1px solid #555; background: #151515; color: #fff; font: inherit; cursor: pointer; }
  #radioDel button:hover:not(:disabled) { background: #222; border-color: #888; }
  #radioDel button:disabled { opacity: 0.5; cursor: default; }
  #radioDel #rdGo { border-color: #ff7b7b; color: #ff9b9b; }
  #radioDel #rdGo.final { background: #ff1a1a; border-color: #ff4d4d; color: #fff; font-weight: 700; box-shadow: 0 0 12px rgba(255,26,26,0.6); }
  #radioDel #rdGo.final:hover:not(:disabled) { background: #ff3333; border-color: #ff7b7b; }
  #rdMsg { flex: 1 1 100%; min-width: 0; font-size: 12px; line-height: 1.4; color: #9a9a9a; }
  #rdMsg.err { color: #ff7b7b; }
  #rdMsg.warn { color: #ffb347; font-weight: 600; }
  #rdHint { margin: 0 0 10px 0; font-size: 12px; color: #8a8a8a; line-height: 1.4; }
  #radioSel option { background: #111; color: #fff; }
  #radioSong { flex: 0 1 auto; min-width: 0; max-width: 45vw; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #4fb3ff; font-weight: 600; }
  #radioState { flex: 0 0 auto; color: #8a8a8a; font-size: 12px; }
  #radioVol { flex: 0 0 auto; width: 110px; accent-color: #4fb3ff; }
  #mainFrame { flex: 1 1 auto; display: block; width: 100%; min-height: 0; border: 0; background: #000; }
</style>
</head>
<body>
<div id="radioBar">
  <button id="radioBtn" type="button" title="Play / Pausa">&#9654;</button>
  <div id="radioViz" aria-hidden="true"></div>
  <span id="radioIcon">&#128251;</span>
  <select id="radioSel" title="Scegli la radio"></select>
  <button id="radioAddBtn" type="button" title="Aggiungi una radio all'elenco">+</button>
  <button id="radioDelBtn" type="button" title="Rimuovi la radio selezionata dall'elenco">&#8722;</button>
  <span id="radioSong"></span>
  <span id="radioState">connessione...</span>
  <input id="radioVol" type="range" min="0" max="100" value="100" title="Volume">
  <audio id="radioAudio" preload="none"></audio>
</div>
<div id="radioAdd" hidden>
  <p id="raHint">La radio viene scritta nell'elenco dentro lo script UnboundBunkerDashboard.ps1 e compare subito nella tendina, senza riavviare la dashboard. Se piu' stream, separali con uno spazio: il primo e' il principale, gli altri di riserva.</p>
  <div class="ra-row"><label for="raName">Nome</label><input id="raName" type="text" maxlength="40" placeholder="Nome della radio" autocomplete="off"></div>
  <div class="ra-row"><label for="raUrl">URL</label><input id="raUrl" type="text" placeholder="https://server:porta/stream.mp3" autocomplete="off" spellcheck="false"></div>
  <div class="ra-row"><span id="raMsg"></span><button id="raCancel" type="button">Annulla</button><button id="raSave" type="button">Salva</button></div>
</div>
<div id="radioDel" hidden>
  <p id="rdHint">Stai per rimuovere questa radio dall'elenco dentro lo script UnboundBunkerDashboard.ps1: serviranno due conferme e alla fine sparisce subito dalla tendina, senza riavviare la dashboard.</p>
  <div class="ra-row"><label for="rdName">Nome</label><input id="rdName" type="text" readonly tabindex="-1"></div>
  <div class="ra-row"><label for="rdUrl">URL</label><textarea id="rdUrl" readonly rows="2" spellcheck="false" tabindex="-1"></textarea></div>
  <div class="ra-row"><span id="rdMsg"></span><button id="rdCancel" type="button">Annulla</button><button id="rdGo" type="button">Rimuovi</button></div>
</div>
<iframe id="mainFrame" title="Unbound Bunker Dashboard"></iframe>
<script>
(function () {
  var f = document.getElementById('mainFrame');
  var lastTitle = '', lastIcon = '', lastPath = location.pathname;

  // === RADIO: lettore audio nativo sullo stream diretto, vive nella shell e non si ricarica cambiando pagina ===
  // ===== ELENCO RADIO =====
  // Il pulsante + della barra aggiunge una riga qui sotto (la scrive il server dentro questo script), poi la dashboard si riavvia.
  // A mano: una riga { name: 'Nome', urls: ['stream principale', 'stream di riserva'] }, con la virgola finale, tra i due commenti.
  // Gli url di una radio sono in ordine di preferenza: se uno non risponde si passa al successivo (e poi di nuovo al primo).
  // NON modificare ne' spostare i due commenti che delimitano l'elenco: il server li usa per trovare il punto dove inserire.
  var RADIO_STATIONS = [
    // RADIO_LIST_BEGIN
    { name: 'Q8 Radio', urls: ['https://nr15.newradio.it:9132/stream?ext=.mp3', 'http://152.228.228.253:9132/stream?ext=.mp3', 'http://152.228.228.253:9132/'] },
    { name: 'Radio  Toscana', urls: ['https://sr14.inmystream.it/stream/radiotoscana/stream', 'https://sr14.inmystream.it/stream/radiotoscana/stream2'] },
    { name: 'RTL102.5', urls: ['https://streamingv2.shoutcast.com/rtl-1025_48.aac'] },
    { name: 'Radio Subasio', urls: ['https://icy.unitedradio.it/Subasio.mp3'] },
    { name: 'M2O', urls: ['https://streamcdni1-4c4b867c89244861ac216426883d1ad0.msvdn.net/radiom2o/radiom2o/play1.m3u8'] },
    { name: '105 Dance 90', urls: ['http://icy.unitedradio.it/105Dance90.mp3'] },
    { name: 'RMC', urls: ['https://icy.unitedradio.it/RMC.mp3'] },
    { name: 'Radio Italia', urls: ['https://radioitaliasmi.akamaized.net/hls/live/2093120/RISMI/stream01/streamPlaylist.m3u8'] },
    { name: 'Radio Italy Live', urls: ['https://streaming.radiostreamlive.com/radioitalylive_devices'] },
    { name: 'Radio Country Live', urls: ['https://streaming.radiostreamlive.com/radiocountrylive_devices'] },
    { name: 'Radio Love Live', urls: ['https://streaming.radiostreamlive.com/radiolovelive_devices'] },
    { name: 'Radio New York Live', urls: ['https://streaming.radiostreamlive.com/radionylive_devices'] },
    { name: 'Radio Miami Beach Live', urls: ['https://streaming.radiostreamlive.com/miamibeachradio_devices'] },
    { name: 'Back to the 80s', urls: ['http://s1.nexuscast.com:8135/;;audio.mp3'] },
    { name: 'Radio North Pole', urls: ['https://streaming.radiostreamlive.com/radionorthpole_devices'] },
    { name: 'Radio Santa Claus', urls: ['https://streaming.radiostreamlive.com/radiosantaclaus_devices'] },
    { name: 'Radio Fantastica', urls: ['https://streaming.radiosa.biz/babboleo_lab/fantastica.stream/playlist.m3u8'] },
    { name: 'Discoradio', urls: ['https://stream.discoradio.radio/audio/disco.stream_aac/chunklist.m3u8'] },
    { name: 'Dimensione Suono Soft', urls: ['https://stream.dimensionesuonosoft.radio/audio/dssc.stream_aac64/chunklist.m3u8'] },
    { name: 'Dimensione Suono Roma', urls: ['https://stream.dimensionesuonoroma.radio/audio/dsr.stream_aac/chunklist.m3u8'] },
    { name: 'Radio Cuore', urls: ['https://stream10.xdevel.com/audio32s975552-1839/stream/icecast.audio'] },
    { name: 'Radio Kiss Kiss', urls: ['https://kisskiss.fluidstream.eu/KissKiss.aac'] },
    { name: 'RMC Love Song', urls: ['http://edge.radiomontecarlo.net/rmcweb006'] },
    { name: 'RMC Fitness', urls: ['https://icy.unitedradio.it/rmcweb023'] },
    { name: 'RMC Greatest Artists', urls: ['http://edge.radiomontecarlo.net/rmcweb007'] },
    // RADIO_LIST_END
  ];
  var STREAMS = RADIO_STATIONS[0].urls;
  var sIdx = 0;
  var au = document.getElementById('radioAudio'), btn = document.getElementById('radioBtn');
  var st = document.getElementById('radioState'), vol = document.getElementById('radioVol');
  var wantPlay = true, retryTimer = null, armed = false;
  try { var sv = localStorage.getItem('radioVol'); if (sv !== null) vol.value = sv; } catch (e) {}
  au.volume = vol.value / 100;
  vol.addEventListener('input', function () {
    au.volume = vol.value / 100;
    try { localStorage.setItem('radioVol', vol.value); } catch (e) {}
  });
  function setUi(playing, msg) { btn.innerHTML = playing ? '&#10074;&#10074;' : '&#9654;'; st.textContent = msg; }
  function startRadio(fresh) {
    clearTimeout(retryTimer);
    if (fresh || !au.src) { var u = STREAMS[sIdx]; au.src = (u.indexOf('?') < 0) ? u : u + '&_=' + Date.now(); }
    var pr = au.play();
    if (pr && pr.catch) pr.catch(function (err) {
      if (err && err.name === 'NotAllowedError') { setUi(false, 'clicca play (il browser blocca l\'avvio automatico)'); armAutoplay(); }
      else { scheduleRetry(); }
    });
  }
  function scheduleRetry() {
    if (!wantPlay) return;
    setUi(false, 'riconnessione...');
    clearTimeout(retryTimer);
    sIdx = (sIdx + 1) % STREAMS.length;   // prova lo stream successivo
    retryTimer = setTimeout(function () { startRadio(true); }, sIdx === 0 ? 3000 : 800);
  }
  // Il primo clic/tasto ovunque nella pagina (anche dentro la dashboard, che e' dello stesso sito) sblocca l'audio
  function armAutoplay() {
    if (armed) return; armed = true;
    var go = function () {
      if (!wantPlay || !au.paused) return;
      armed = false;
      document.removeEventListener('pointerdown', go, true); document.removeEventListener('keydown', go, true);
      try { f.contentDocument.removeEventListener('pointerdown', go, true); f.contentDocument.removeEventListener('keydown', go, true); } catch (e) {}
      startRadio(false);
    };
    document.addEventListener('pointerdown', go, true); document.addEventListener('keydown', go, true);
    var hook = function () { try { f.contentDocument.addEventListener('pointerdown', go, true); f.contentDocument.addEventListener('keydown', go, true); } catch (e) {} };
    hook(); f.addEventListener('load', hook);
  }
  au.addEventListener('playing', function () { setUi(true, 'in onda'); });
  au.addEventListener('waiting', function () { if (wantPlay) st.textContent = 'buffering...'; });
  au.addEventListener('error', scheduleRetry);
  au.addEventListener('stalled', function () { if (wantPlay) { clearTimeout(retryTimer); retryTimer = setTimeout(function () { if (!au.paused && au.readyState < 3) startRadio(true); }, 8000); } });
  au.addEventListener('ended', scheduleRetry);
  btn.addEventListener('click', function () {
    if (au.paused) { wantPlay = true; sIdx = 0; startRadio(true); }
    else { wantPlay = false; clearTimeout(retryTimer); au.pause(); au.removeAttribute('src'); au.load(); setUi(false, 'in pausa'); }
  });

  // === TITOLO DELLA CANZONE IN ONDA: letto dalla pagina di stato del server radio (Icecast, poi Shoutcast v2, poi v1) ===
  var songEl = document.getElementById('radioSong');
  var songKind = {};   // per ogni server, quale tipo di pagina di stato ha risposto l'ultima volta
  function cleanSong(s) {
    s = String(s || '').replace(/\s+/g, ' ').trim();
    return (!s || /^(no live title|n\/a|unknown|-)$/i.test(s)) ? '' : s;
  }
  function parseSong(kind, txt) {
    if (kind === 'ice') {
      var j = JSON.parse(txt), src = j.icestats && j.icestats.source;
      var arr = Array.isArray(src) ? src : (src ? [src] : []);
      var pick = null, i;
      for (i = 0; i < arr.length; i++) { if (/\/stream$/.test(String(arr[i].listenurl || '').split('?')[0])) { pick = arr[i]; break; } }
      if (!pick) pick = arr[0];
      if (!pick) return '';
      var ti = String(pick.title || ''), ar = String(pick.artist || '');
      return cleanSong(ar && ti && ti.toLowerCase().indexOf(ar.toLowerCase()) < 0 ? ar + ' - ' + ti : ti);
    }
    if (kind === 'sc2') { return cleanSong(JSON.parse(txt).songtitle); }
    var f7 = txt.replace(/<[^>]*>/g, '').trim().split(',');   // Shoutcast v1 /7.html: ... ,ultimo campo = titolo
    return f7.length > 6 ? cleanSong(f7.slice(6).join(',')) : '';
  }
  function fetchSong(url, kind) {
    var ac = (window.AbortController ? new AbortController() : null);
    var to = setTimeout(function () { if (ac) ac.abort(); }, 6000);
    return fetch(url, { cache: 'no-store', signal: ac ? ac.signal : undefined }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then(function (txt) { clearTimeout(to); return parseSong(kind, txt); }, function (e) { clearTimeout(to); throw e; });
  }
  // Se la pagina di stato della radio non e' leggibile dal browser (CORS o piattaforma diversa), il titolo lo legge il server della dashboard
  // (metadati ICY dentro lo stream) tramite /api/radio-meta; 'pending' = prima richiesta, la risposta e' in preparazione.
  function proxySong(u, tries) {
    fetch('/api/radio-meta?u=' + encodeURIComponent(u), { cache: 'no-store', headers: { 'X-Bunker-Radio': '1' } }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (j) {
      if (au.paused) return;
      var s = cleanSong(j && j.title);
      if (s) { songEl.textContent = '\u266A ' + s; songEl.title = s; }
      else if (j && j.pending && tries < 4) { setTimeout(function () { if (!au.paused) proxySong(u, tries + 1); }, 2000); }
      else { songEl.textContent = ''; songEl.title = ''; }
    }, function () {});
  }
  function pollSong() {
    if (au.paused) { songEl.textContent = ''; songEl.title = ''; return; }
    var o = STREAMS[sIdx].replace(/^(https?:\/\/[^\/]+).*$/, '$1');
    var eps = [
      { k: 'ice', u: o + '/status-json.xsl' },
      { k: 'sc2', u: o + '/stats?sid=1&json=1' },
      { k: 'sc1', u: o + '/7.html' }
    ];
    if (songKind[o]) { eps = eps.filter(function (e) { return e.k === songKind[o]; }); }
    (function next(i) {
      if (i >= eps.length) {
        if (songKind[o] === 'proxy' || eps.length > 1) songKind[o] = 'proxy'; else delete songKind[o];
        proxySong(STREAMS[sIdx], 0); return;
      }
      fetchSong(eps[i].u, eps[i].k).then(function (s) {
        songKind[o] = eps[i].k;
        songEl.textContent = s ? '\u266A ' + s : '';
        songEl.title = s;
      }, function () { next(i + 1); });
    })(0);
  }
  au.addEventListener('playing', function () { setTimeout(pollSong, 1500); });
  au.addEventListener('pause', pollSong);
  setInterval(pollSong, 10000);

  // === ISTOGRAMMA COLORATO (stile B): barre piene, un colore per banda; si muove solo se dalla radio arriva audio davvero ===
  // 'Arriva audio' = in riproduzione, dati sufficienti nel buffer e orologio dello stream che avanza. Senza dati le barre scendono e spariscono.
  var viz = document.getElementById('radioViz'), vBars = [], vLv = [], vTimer = null, vLastT = -1, VN = 16;
  for (var vi = 0; vi < VN; vi++) {
    var vb = document.createElement('span'); vb.className = 'vb';
    vb.style.background = 'hsl(' + Math.round(vi * 300 / VN) + ',80%,60%)';
    viz.appendChild(vb); vBars.push(vb); vLv.push(0);
  }
  function vizTick() {
    if (document.hidden) return;
    var ct = au.currentTime, flowing = !au.paused && au.readyState >= 3 && Math.abs(ct - vLastT) > 0.005, any = false;
    vLastT = ct;
    for (var i = 0; i < VN; i++) {
      var t = flowing ? Math.max(0.05, Math.min(1, Math.random() * (1 - 0.6 * i / VN) * (0.55 + Math.random() * 0.6))) : 0;
      vLv[i] = Math.max(t, vLv[i] * (flowing ? 0.78 : 0.6));
      vBars[i].style.height = Math.max(2, Math.round(vLv[i] * 30)) + 'px';
      if (vLv[i] > 0.03) any = true;
    }
    viz.classList.toggle('on', flowing || any);
    if (!flowing && !any && au.paused) { clearInterval(vTimer); vTimer = null; viz.classList.remove('on'); }
  }
  function vizStart() { if (!vTimer) vTimer = setInterval(vizTick, 90); }
  au.addEventListener('play', vizStart);
  au.addEventListener('playing', vizStart);

  // === TENDINA RADIO: sceglie la radio, ricorda l'ultima scelta e fa ripartire l'audio ===
  var sel = document.getElementById('radioSel'), cur = 0;
  RADIO_STATIONS.forEach(function (s, i) { var o = document.createElement('option'); o.value = i; o.textContent = s.name; sel.appendChild(o); });
  try { var sn = localStorage.getItem('radioStation'); RADIO_STATIONS.forEach(function (s, i) { if (s.name === sn) cur = i; }); } catch (e) {}
  sel.value = cur; STREAMS = RADIO_STATIONS[cur].urls; sIdx = 0;
  sel.addEventListener('change', function () {
    cur = +sel.value; STREAMS = RADIO_STATIONS[cur].urls; sIdx = 0;
    try { localStorage.setItem('radioStation', RADIO_STATIONS[cur].name); } catch (e) {}
    songEl.textContent = ''; songEl.title = '';
    wantPlay = true; clearTimeout(retryTimer); startRadio(true);
  });

  // Aggiorna la tendina e la radio in uso SENZA ricaricare la pagina: l'audio in onda non si interrompe se la radio non cambia
  function rebuildSel() {
    while (sel.firstChild) sel.removeChild(sel.firstChild);
    RADIO_STATIONS.forEach(function (s, i) { var o = document.createElement('option'); o.value = i; o.textContent = s.name; sel.appendChild(o); });
  }
  function useStation(i, play) {
    cur = i; sel.value = i; STREAMS = RADIO_STATIONS[i].urls; sIdx = 0;
    try { localStorage.setItem('radioStation', RADIO_STATIONS[i].name); } catch (e) {}
    songEl.textContent = ''; songEl.title = '';
    if (play) { wantPlay = true; clearTimeout(retryTimer); startRadio(true); }
  }

  // === PULSANTE +: aggiunge una radio all'elenco scritto nello script e riavvia la dashboard ===
  var addBtn = document.getElementById('radioAddBtn'), addPanel = document.getElementById('radioAdd');
  var raName = document.getElementById('raName'), raUrl = document.getElementById('raUrl');
  var raMsg = document.getElementById('raMsg'), raSave = document.getElementById('raSave'), raCancel = document.getElementById('raCancel');
  function raSay(s, isErr) { raMsg.textContent = s || ''; raMsg.className = isErr ? 'err' : ''; }
  function raOpen(show) {
    addPanel.hidden = !show;
    if (show) { raSay(''); raName.focus(); }
  }
  addBtn.addEventListener('click', function () { rdOpen(false); raOpen(addPanel.hidden); });
  raCancel.addEventListener('click', function () { raOpen(false); });
  addPanel.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { raOpen(false); }
    else if (e.key === 'Enter') { e.preventDefault(); raSave.click(); }
  });
  // Dopo il riavvio chiesto al server: aspetta che torni su e ricarica la pagina intera
  function waitServerBack() {
    var sawDown = false, t0 = Date.now();
    var iv = setInterval(function () {
      fetch('/api/status', { cache: 'no-store' }).then(function (r) {
        if (r.ok) { if (sawDown || Date.now() - t0 > 15000) { clearInterval(iv); location.reload(); } }
        else { sawDown = true; }
      }, function () { sawDown = true; });
      if (Date.now() - t0 > 90000) { clearInterval(iv); raSay('Il riavvio sta impiegando troppo: ricarica la pagina a mano.', true); }
    }, 1000);
  }
  raSave.addEventListener('click', function () {
    var nm = raName.value.trim(), ur = raUrl.value.trim();
    if (!nm) { raSay('Scrivi il nome della radio.', true); raName.focus(); return; }
    if (!/^https?:\/\//i.test(ur)) { raSay("L'URL deve iniziare con http:// o https://", true); raUrl.focus(); return; }
    raSave.disabled = true; raCancel.disabled = true; raSay('Salvataggio nello script...');
    fetch('/api/radio-add', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Bunker-Radio': '1' },
      body: JSON.stringify({ name: nm, url: ur })
    }).then(function (r) {
      return r.json().catch(function () { return { ok: false, error: 'Risposta non valida dal server (HTTP ' + r.status + ')' }; });
    }).then(function (j) {
      if (!j || !j.ok) { raSay((j && j.error) || 'Errore nel salvataggio.', true); raSave.disabled = false; raCancel.disabled = false; return; }
      if (j.restart) {
        // Il server non e' riuscito ad aggiornare la pagina in memoria: ripiego sul riavvio completo
        try { localStorage.setItem('radioStation', nm); } catch (e) {}
        raSay('Salvata. Riavvio completo della dashboard...');
        fetch('/api/restart', { method: 'POST' }).catch(function () {});
        waitServerBack();
        return;
      }
      RADIO_STATIONS.push({ name: nm, urls: ur.split(/\s+/).filter(Boolean) });
      rebuildSel(); useStation(RADIO_STATIONS.length - 1, wantPlay);
      raName.value = ''; raUrl.value = ''; raSave.disabled = false; raCancel.disabled = false; raOpen(false);
    }, function () {
      raSay('Server non raggiungibile.', true); raSave.disabled = false; raCancel.disabled = false;
    });
  });

  // === PULSANTE -: rimuove dall'elenco la radio selezionata (info complete, 2 conferme) e riavvia la dashboard ===
  var delBtn = document.getElementById('radioDelBtn'), delPanel = document.getElementById('radioDel');
  var rdName = document.getElementById('rdName'), rdUrl = document.getElementById('rdUrl'), rdMsg = document.getElementById('rdMsg');
  var rdGo = document.getElementById('rdGo'), rdCancel = document.getElementById('rdCancel');
  var rdStep = 0;
  function rdSay(s, cls) { rdMsg.textContent = s || ''; rdMsg.className = cls || ''; }
  function rdReset() { rdStep = 0; rdGo.className = ''; rdGo.textContent = 'Rimuovi'; rdGo.disabled = false; rdCancel.disabled = false; }
  function rdFill() {
    var s = RADIO_STATIONS[cur];
    rdName.value = s.name;
    rdUrl.value = s.urls.join('\n');
    rdUrl.rows = Math.max(2, Math.min(5, s.urls.length));
    rdReset();
    if (RADIO_STATIONS.length <= 1) { rdSay("E' l'ultima radio dell'elenco: non si puo' rimuovere.", 'err'); rdGo.disabled = true; }
    else { rdSay(s.urls.length + (s.urls.length === 1 ? ' indirizzo stream' : ' indirizzi stream')); }
  }
  function rdOpen(show) {
    if (show) { raOpen(false); rdFill(); }
    delPanel.hidden = !show;
    if (!show) { rdReset(); }
  }
  delBtn.addEventListener('click', function () { rdOpen(delPanel.hidden); });
  rdCancel.addEventListener('click', function () { rdOpen(false); });
  delPanel.addEventListener('keydown', function (e) { if (e.key === 'Escape') { rdOpen(false); } });
  // Se si cambia radio nella tendina mentre il pannello e' aperto, le info si aggiornano e le conferme ripartono da zero
  sel.addEventListener('change', function () { if (!delPanel.hidden) { rdFill(); } });
  rdGo.addEventListener('click', function () {
    var nm = RADIO_STATIONS[cur].name, ix = cur;
    if (rdStep === 0) {
      rdStep = 1; rdGo.textContent = 'Si, continua';
      rdSay('Conferma 1 di 2: vuoi davvero rimuovere "' + nm + '"?', 'warn');
      return;
    }
    if (rdStep === 1) {
      rdStep = 2; rdGo.className = 'final'; rdGo.textContent = 'Rimuovi definitivamente';
      rdSay('Conferma 2 di 2: ULTIMA conferma. La radio viene cancellata dallo script e dalla tendina.', 'warn');
      return;
    }
    rdGo.disabled = true; rdCancel.disabled = true; rdSay('Rimozione dallo script...');
    fetch('/api/radio-remove', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Bunker-Radio': '1' },
      body: JSON.stringify({ index: ix, name: nm })
    }).then(function (r) {
      return r.json().catch(function () { return { ok: false, error: 'Risposta non valida dal server (HTTP ' + r.status + ')' }; });
    }).then(function (j) {
      if (!j || !j.ok) { rdReset(); rdSay((j && j.error) || 'Errore nella rimozione.', 'err'); return; }
      if (j.restart) {
        // Il server non e' riuscito ad aggiornare la pagina in memoria: ripiego sul riavvio completo
        try { if (localStorage.getItem('radioStation') === nm) localStorage.removeItem('radioStation'); } catch (e) {}
        rdSay('Rimossa. Riavvio completo della dashboard...');
        fetch('/api/restart', { method: 'POST' }).catch(function () {});
        waitServerBack();
        return;
      }
      RADIO_STATIONS.splice(ix, 1);
      rebuildSel(); useStation(0, wantPlay);
      rdReset(); rdOpen(false);
    }, function () {
      rdReset(); rdSay('Server non raggiungibile.', 'err');
    });
  });
  // === TITOLO SCHEDA A ROTAZIONE (v1107.1): con la radio in onda alterna indicazioni dashboard -> nome radio -> brano ===
  // Fasi fisse: indicazioni 4 s, radio 3 s, brano 4 s (se piu' lungo dello spazio nella linguetta scorre come un'insegna, un giro intero).
  // Radio ferma/in pausa o dashboard OFFLINE: nessuna rotazione, resta il titolo della dashboard. Brano assente: la fase viene saltata.
  var baseT = '', rotPhase = 0, rotStep = 0, ROT_W = 24;
  function rotCompose() {
    var base = baseT || document.title;
    if (!base || /OFFLINE/.test(base) || au.paused) { rotPhase = 0; rotStep = 0; return base; }
    var name = RADIO_STATIONS[cur] ? String(RADIO_STATIONS[cur].name).replace(/\s+/g, ' ').trim() : '';
    var song = (songEl.title || '').replace(/\s+/g, ' ').trim();
    if (rotPhase === 1 && !name) { rotPhase = 2; rotStep = 0; }
    if (rotPhase === 2 && !song) { rotPhase = 0; rotStep = 0; }
    var out, dur;
    if (rotPhase === 0) { out = base; dur = 8; }
    else if (rotPhase === 1) { out = '\uD83D\uDCFB ' + name; dur = 6; }
    else {
      var txt = '\u266A ' + song;
      if (txt.length <= ROT_W) { out = txt; dur = 8; }
      else { var loop = txt + '   \u266A   '; out = (loop + loop).substr(rotStep % loop.length, ROT_W); dur = loop.length; }
    }
    rotStep++;
    if (rotStep >= dur) { rotStep = 0; rotPhase = (rotPhase + 1) % 3; }
    return out;
  }
  setInterval(function () { var t2 = rotCompose(); if (t2 && t2 !== document.title) document.title = t2; }, 500);
  startRadio(false);
  f.src = location.pathname + location.search;
  // La dashboard vive nel frame: titolo (pallini colorati), favicon e indirizzo vengono ricopiati sulla scheda del browser
  setInterval(function () {
    try {
      var d = f.contentDocument;
      if (!d) return;
      var t = d.title;
      if (t) baseT = t;   // il titolo a schermo lo compone la rotazione qui sotto
      var l = d.querySelector('link[rel~="icon"]');
      var h = l ? l.getAttribute('href') : '';
      if (h && h !== lastIcon) {
        lastIcon = h;
        var old = document.getElementById('shellIcon');
        var n = document.createElement('link');
        n.id = 'shellIcon'; n.rel = 'icon'; n.href = h;
        old.parentNode.replaceChild(n, old);
      }
      var p = f.contentWindow.location.pathname;
      if (p && p.charAt(0) === '/' && p !== lastPath) { lastPath = p; history.replaceState(null, '', p); }
    } catch (e) {}
  }, 400);
})();
</script>
</body>
</html>
'@

# Il browser dichiara con Sec-Fetch-Dest se la richiesta e' la pagina principale (document) o un frame (iframe):
# solo la pagina principale riceve la shell con la radio. Senza intestazione (curl, controlli esterni) si serve la dashboard come prima.
function Test-WantsShell {
    param($req)
    try { return ([string]$req.Headers['Sec-Fetch-Dest'] -eq 'document') } catch { return $false }
}

# Dopo che /api/radio-add o /api/radio-remove hanno riscritto l'elenco nel file, aggiorna anche la copia in memoria della pagina
# contenitore ($HtmlShell, letta una sola volta all'avvio): cosi' un ricaricamento della pagina mostra subito l'elenco nuovo
# e non serve riavviare la dashboard. Restituisce $false se non riesce (la pagina ripiega allora sul riavvio completo).
function Update-RadioShellMemory {
    param([string]$NewScriptText)
    try {
        $mB = '// RADIO_LIST_' + 'BEGIN'
        $mE = '// RADIO_LIST_' + 'END'
        $nB = $NewScriptText.IndexOf($mB, [System.StringComparison]::Ordinal)
        $nE = if ($nB -ge 0) { $NewScriptText.IndexOf($mE, $nB, [System.StringComparison]::Ordinal) } else { -1 }
        $sB = $script:HtmlShell.IndexOf($mB, [System.StringComparison]::Ordinal)
        $sE = if ($sB -ge 0) { $script:HtmlShell.IndexOf($mE, $sB, [System.StringComparison]::Ordinal) } else { -1 }
        if ($nB -lt 0 -or $nE -lt 0 -or $sB -lt 0 -or $sE -lt 0) { return $false }
        $script:HtmlShell = $script:HtmlShell.Substring(0, $sB) + $NewScriptText.Substring($nB, $nE - $nB) + $script:HtmlShell.Substring($sE)
        return $true
    } catch { return $false }
}

# === TITOLO CANZONE DELLE RADIO (rotta /api/radio-meta) ===
# Legge i metadati ICY (StreamTitle) dentro lo stream della radio, per le radio la cui pagina di stato non e' leggibile dal browser.
# La lettura gira in un runspace in background: il server HTTP, che e' a thread unico, non aspetta mai la radio.
$script:RadioMetaCache = @{}
$script:RadioMetaJobs  = @{}
$script:RadioMetaScript = {
    param($u)
    try {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
        if ($u -match '\.m3u8') { return '' }
        $req = [System.Net.HttpWebRequest]::Create($u)
        $req.Headers.Add('Icy-MetaData', '1')
        $req.UserAgent = 'Mozilla/5.0 UnboundBunkerDashboard'
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $resp = $req.GetResponse()
        try {
            $mi = 0
            [void][int]::TryParse([string]$resp.Headers['icy-metaint'], [ref]$mi)
            if ($mi -le 0 -or $mi -gt 65536) { return '' }
            $s = $resp.GetResponseStream()
            $buf = New-Object byte[] 4096
            $left = $mi
            while ($left -gt 0) {
                $n = $s.Read($buf, 0, [Math]::Min($left, $buf.Length))
                if ($n -le 0) { return '' }
                $left -= $n
            }
            $lb = $s.ReadByte()
            if ($lb -le 0) { return '' }
            $mb = New-Object byte[] ($lb * 16)
            $got = 0
            while ($got -lt $mb.Length) {
                $n = $s.Read($mb, $got, $mb.Length - $got)
                if ($n -le 0) { break }
                $got += $n
            }
            $txt = [System.Text.Encoding]::UTF8.GetString($mb, 0, $got)
            if ($txt.Contains([string][char]0xFFFD)) { $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($mb, 0, $got) }
            if ($txt -match "StreamTitle='(.*?)';") { return $Matches[1] }
            return ''
        } finally { try { $resp.Close() } catch {} }
    } catch { return '' }
}

function Get-RadioMetaTitle {
    param([string]$Url)
    $now = Get-Date
    foreach ($k in @($script:RadioMetaJobs.Keys)) {
        $j = $script:RadioMetaJobs[$k]
        $done = $j.h.IsCompleted
        if ($done -or (($now - $j.started).TotalSeconds -gt 20)) {
            $t = ''
            if ($done) {
                try { $r = $j.ps.EndInvoke($j.h); if ($r -and $r.Count -gt 0) { $t = [string]$r[0] } } catch {}
                try { $j.ps.Dispose() } catch {}
            } else {
                try { [void]$j.ps.BeginStop($null, $null) } catch {}
            }
            $script:RadioMetaJobs.Remove($k)
            $script:RadioMetaCache[$k] = @{ title = $t; ts = $now }
        }
    }
    $c = $script:RadioMetaCache[$Url]
    if (-not $script:RadioMetaJobs.ContainsKey($Url) -and ((-not $c) -or (($now - $c.ts).TotalSeconds -ge 8))) {
        try {
            $ps = [powershell]::Create()
            [void]$ps.AddScript($script:RadioMetaScript.ToString()).AddArgument($Url)
            $script:RadioMetaJobs[$Url] = @{ ps = $ps; h = $ps.BeginInvoke(); started = $now }
        } catch { Write-DashLog "Errore avvio lettura titolo radio: $($_.Exception.Message)" }
    }
    if ($c) { return [string]$c.title } else { return '' }
}

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
    color: var(--text); font-family: var(--font-ui); padding: 14px 20px 18px;
  }
  .wrap { max-width: 1360px; margin: 0 auto; }
  header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 12px; }
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
  .netstrip { background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%); border: 1px solid var(--border-strong); border-radius: 14px; padding: 10px 14px; margin: 0 0 12px; text-align: left; font-family: var(--font-ui); transition: opacity 0.4s; }
  .netstrip.stale { opacity: 0.45; filter: grayscale(0.7); }
  .ns-meters { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
  .ns-pot { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin: 0 0 6px; padding: 5px 10px; font-size: 0.8em; border-radius: 10px; border: 1px solid rgba(79,179,255,0.30); background: linear-gradient(90deg, rgba(79,179,255,0.14) 0%, rgba(79,179,255,0.03) 100%); box-shadow: inset 3px 0 0 var(--accent); }
  .ns-pot.fb { border-color: var(--border-strong); background: rgba(255,255,255,0.03); box-shadow: inset 3px 0 0 var(--dim); }
  .ns-pot-l { font-size: 0.82em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-pot.run .ns-pot-l::after { content: ' \25CF'; color: #ffd600; animation: nsPotPulse 1.2s ease-in-out infinite; }
  .ns-pot-s { font-size: 0.82em; color: var(--dim); margin-top: 1px; line-height: 1.3; }
  .ns-pot-v { text-align: right; white-space: nowrap; }
  .ns-pot-v b { font-family: var(--font-mono); font-size: 1.7em; line-height: 1; color: var(--accent); letter-spacing: 0; }
  .ns-pot.fb .ns-pot-v b { color: var(--dim); }
  .ns-pot-v small { font-size: 0.8em; color: var(--dim); margin-left: 3px; }
  @keyframes nsPotPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.25; } }
  .ns-mh { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; font-size: 0.74em; color: var(--dim); margin-bottom: 3px; letter-spacing: 0.06em; text-transform: uppercase; }
  .ns-mh b { font-family: var(--font-mono); font-size: 1.7em; color: var(--text); letter-spacing: 0; }
  .ns-mh small { font-size: 0.9em; color: var(--dim); letter-spacing: 0; text-transform: none; font-weight: 400; }
  /* ---------- Connessioni live sotto Download/Upload: 3 righe, scorrimento verticale fluido, nuove in basso ---------- */
  .ns-lane { position: relative; height: 176px; margin: 0 0 4px; overflow: hidden; border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); }
  .ns-lane .ce { position: absolute; left: 0; right: 0; top: 0; height: 22px; display: flex; align-items: center; gap: 8px; padding: 0 8px; font-family: var(--font-mono); font-size: 12px; white-space: nowrap; opacity: 0; will-change: transform, opacity; }
  /* Bandierine paese (v1107.4): Windows non disegna le bandiere emoji, quindi si incorpora il font 'Twemoji Country Flags'
     (talkjs/country-flag-emoji-polyfill, MIT; grafica Twemoji CC-BY 4.0). unicode-range = solo i simboli bandiera. */
  @font-face { font-family: "TwemojiFlags"; src: url("data:font/woff2;base64,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") format("woff2");
    unicode-range: U+1F1E6-1F1FF, U+1F3F4, U+E0062-E0063, U+E0065, U+E0067, U+E006C, U+E006E, U+E0073-E0074, U+E0077, U+E007F; font-display: swap; }
  .ns-lane .ce .cf.cf2 { min-width: 3.4em; }
  .ns-lane .ce .cf { flex: 0 0 auto; min-width: 1.7em; white-space: nowrap; text-align: center; font-family: "TwemojiFlags", "Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji", sans-serif; font-size: 13px; line-height: 1; }
  .ns-lane .ce .cd { flex: 0 0 auto; width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
  .ns-lane .ce .ct { flex: 0 0 auto; opacity: 0.6; }
  .ns-lane .ce .cn { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .ns-lane .ce .cv { flex: 0 0 auto; font-size: 0.85em; opacity: 0.55; text-transform: uppercase; letter-spacing: 0.05em; }
  .ns-lane .ce .cq { flex: 0 0 auto; font-size: 0.78em; opacity: 0.8; border: 1px solid currentColor; border-radius: 4px; padding: 0 4px; line-height: 1.35; }
  .ns-lane .ce .cx { flex: 0 0 auto; font-size: 0.85em; opacity: 0.9; font-weight: 700; }
  .ns-lane .ce .cw { flex: 0 0 auto; font-size: 0.75em; opacity: 0.6; font-style: italic; }
  .ns-lane .ce.ok { color: var(--green); }
  .ns-lane .ce.no { color: var(--red); }
  .ns-lane .ce.er { color: var(--amber); }
  .ns-lane .ce.sub.ok { color: var(--dim); }
  .ns-lane .ce.ow .cn { font-style: italic; }
  .ns-lane .ce-more { position: absolute; right: 6px; top: 2px; z-index: 2; font-family: var(--font-mono); font-size: 10px; color: var(--dim); background: rgba(0,0,0,0.5); border-radius: 6px; padding: 0 5px; opacity: 0; transition: opacity 0.3s ease; pointer-events: none; }
  .ns-g { display: block; width: 100%; max-width: 250px; margin: 0 auto; }
  .ns-g .gl { fill: var(--dim); font-size: 10px; }
  .ns-g .gt { stroke: var(--dim); stroke-width: 1.2; }
  .ns-g .gv { fill: var(--text); font-family: var(--font-mono); font-size: 22px; }
  .ns-g .gu { fill: var(--dim); font-size: 11px; }
  .ns-g .gnd { transform-origin: 100px 100px; transition: transform 0.6s ease; }
  .ns-cv .gv { font-size: 24px; }
  .ns-cv .cv-c { fill: none; stroke: rgba(255,255,255,0.12); stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round; transition: stroke 0.4s ease; }
  .ns-cv .cv-c.on { stroke: var(--cv); animation: cvPulse 1.2s ease-in-out infinite; animation-delay: calc(var(--i) * 0.15s); }
  @keyframes cvPulse { 0%, 100% { stroke-opacity: 0.18; } 35% { stroke-opacity: 1; } }
  @media (prefers-reduced-motion: reduce) { .ns-cv .cv-c.on { animation: none; } }
  #nsDc { --cv: #22d3ee; } #nsUc { --cv: #ff8c1a; }
  #nsDv { fill: #22d3ee; } #nsUv { fill: #ff8c1a; }
  #nsDs { stroke: #22d3ee; } #nsDa, #nsDd { fill: #22d3ee; }
  #nsUs { stroke: #ff8c1a; } #nsUa, #nsUd { fill: #ff8c1a; }
  #nsDq, #nsUq { stroke: rgba(219,229,238,0.5); }
  .ns-st { display: flex; gap: 6px; max-width: 250px; margin: 4px auto 0; }
  .ns-st span { flex: 1; min-width: 0; text-align: center; background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 8px; padding: 2px 2px; }
  .ns-st small { display: block; font-size: 0.66em; letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }
  .ns-st b { font-family: var(--font-mono); font-size: 0.95em; color: var(--text); font-weight: 700; }
  .ns-stc { max-width: 250px; margin: 2px auto 0; font-size: 0.66em; text-align: center; color: var(--dim); }
  #nsDSa { color: #22d3ee; } #nsUSa { color: #ff8c1a; }
  #nsPotDc:not(.fb) .ns-pot-v b { color: #22d3ee; } #nsPotUc:not(.fb) .ns-pot-v b { color: #ff8c1a; }
  .ns-tr { font-size: 0.72em; text-align: center; margin: 2px 0 0; min-height: 1.3em; }
  .ns-row { display: flex; justify-content: center; align-items: flex-start; gap: 14px; }
  .ns-a { flex: 0 1 215px; min-width: 0; }
  .ns-b { flex: 0 1 250px; min-width: 0; }
  .ns-trs { color: var(--dim); }
  .ns-hc { display: block; width: 100%; max-width: 250px; margin: 2px auto 0; }
  .ns-hc .gl { fill: var(--dim); font-size: 9px; }
  .ns-hc .gr { stroke: rgba(255,255,255,0.12); stroke-width: 1; }
  .ns-hc .ar { fill: var(--accent); fill-opacity: 0.16; }
  .ns-hc .ln { fill: none; stroke: var(--accent); stroke-width: 1.8; stroke-linejoin: round; }
  .ns-hc .dt { fill: var(--accent); }
  .ns-hc .pq { stroke: #ffb300; stroke-width: 1; stroke-dasharray: 4 3; }
  .ns-sc { display: flex; justify-content: space-between; font-size: 0.7em; color: var(--dim); margin-top: 3px; font-family: var(--font-mono); }
  .ns-info { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; margin: 0 0 10px; padding: 0 0 10px; border-bottom: 1px solid var(--border); }
  .ns-c { background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 10px; padding: 5px 10px; min-width: 0;
    display: grid; grid-template-columns: auto minmax(0, 1fr); column-gap: 8px; align-items: baseline; }
  .ns-c .ns-l { grid-column: 1; grid-row: 1; }
  .ns-c .ns-s { grid-column: 2; grid-row: 1; margin: 0; text-align: right; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ns-c .ns-v { grid-column: 1 / -1; grid-row: 2; margin-top: 2px; }
  .ns-c.win { border-color: rgba(61,220,132,0.45); }
  .ns-c.bad { border-color: rgba(255,92,92,0.45); }
  .ns-l { font-size: 0.68em; color: var(--dim); letter-spacing: 0.07em; text-transform: uppercase; }
  .ns-v { font-family: var(--font-mono); font-size: 0.88em; font-weight: 700; color: var(--text); margin-top: 3px; word-break: break-all; line-height: 1.35; }
  .ns-s { font-size: 0.72em; color: var(--dim); margin-top: 2px; }
  .ns-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; background: var(--dim); }
  .ns-dot.ok { background: #3ddc84; box-shadow: 0 0 6px #3ddc84; }
  .ns-dot.bad { background: #ff5c5c; }
  @media (max-width: 900px) { .ns-info { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
  @media (max-width: 560px) { .ns-meters { grid-template-columns: 1fr; } .ns-row { flex-wrap: wrap; } }
  /* [v1107.8] Classifica bandierine ai lati dei badge Velocita linea (sinistra = Download, destra = Upload) */
  .ns-meters.rz-on { grid-template-columns: auto minmax(0, 1fr) minmax(0, 1fr) auto; }
  .rz { position: relative; width: 172px; align-self: start; font-family: var(--font-mono); font-size: 12px; }
  .rz-i { position: absolute; left: 0; width: 50%; box-sizing: border-box; padding: 0 5px; height: 20px; display: flex; align-items: center; gap: 6px; white-space: nowrap; transition: top 0.6s cubic-bezier(0.2, 0.8, 0.2, 1), left 0.6s cubic-bezier(0.2, 0.8, 0.2, 1); }
  .rz-l .rz-i { justify-content: flex-end; }
  .rz-e { font-size: 15px; line-height: 1; font-family: "TwemojiFlags", "Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji", sans-serif; }
  .rz-i b { font-weight: 700; color: var(--text); font-variant-numeric: tabular-nums; }
  .rz-i.up b { animation: rzUp 1s ease-out; }
  @keyframes rzUp { 0% { color: #ffd600; } 100% { color: var(--text); } }
  @media (max-width: 560px) { .ns-meters.rz-on { grid-template-columns: 1fr; } .rz { width: auto; height: auto !important; display: flex; flex-wrap: wrap; gap: 4px 14px; } .rz-i { position: static; width: auto; } .rz-l { order: -1; } .rz-r { order: 3; } }

  .gauges { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 14px; }
  .card {
    background: linear-gradient(180deg, var(--panel) 0%, var(--panel-2) 100%);
    border: 1px solid var(--border-strong); border-radius: 16px; padding: 14px 16px 12px;
    box-shadow: 0 10px 30px rgba(0,0,0,0.4); text-align: center;
  }
  .card h2 { margin: 0 0 4px; font-size: 0.95em; letter-spacing: 0.08em; color: var(--dim); text-transform: uppercase; }
  .card svg { width: 100%; max-width: 380px; height: auto; display: block; margin: 0 auto; }
  .value { font-family: var(--font-mono); font-weight: 700; }
  /* Striscia delle ultime variazioni (a destra la piu' recente): scorre verso sinistra */
  .card svg.trail { max-width: 380px; margin: -4px auto 2px; overflow: visible; }
  .trail .ti { transition: transform 0.5s cubic-bezier(0.22, 0.8, 0.3, 1), opacity 0.5s ease; }
  @media (prefers-reduced-motion: reduce) { .trail .ti { transition: none; } }
  .detail { color: var(--dim); font-size: 0.82em; margin-top: 3px; min-height: 1.3em; font-family: var(--font-mono); }
  .stale { opacity: 0.45; filter: grayscale(0.7); transition: opacity 0.4s; }
  /* ---------- Componenti del punteggio (accanto alla lancetta su card larga, sotto su card stretta) ---------- */
  .card { container-type: inline-size; }
  .upper { display: block; }
  .gcol { min-width: 0; }
  .comps { margin-top: 8px; text-align: left; }
  .chead { display: flex; justify-content: space-between; gap: 8px; font-size: 0.72em; color: var(--dim); padding: 0 2px 3px; }
  .crow { display: grid; grid-template-columns: 14px minmax(0, 1fr) auto; align-items: center; gap: 8px; padding: 4px 2px; border-top: 1px solid var(--border); }
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
  .hist { margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--border); text-align: left; }
  .hist-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; flex-wrap: wrap; margin-bottom: 4px; }
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
  .hist-stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 6px; }
  .hist-stat { background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 8px; padding: 3px 4px; text-align: center; }
  .hist-stat span { display: block; font-size: 0.6em; letter-spacing: 0.09em; text-transform: uppercase; color: var(--dim); }
  .hist-stat b { display: block; font-family: var(--font-mono); font-size: 0.78em; margin-top: 2px; font-variant-numeric: tabular-nums; }
  footer { color: var(--dim); font-size: 0.75em; text-align: center; margin-top: 12px; }
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
      <h1>&#128737; UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1107.7 - by Mauro Bigoni</h1>
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
  <div class="ns-info">
    <div class="ns-c"><div class="ns-l">IP pubblico</div><div class="ns-v" id="nsPub">N/D</div><div class="ns-s" id="nsPubS">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv4</div><div class="ns-v" id="nsV4">N/D</div><div class="ns-s" id="nsV4S">&nbsp;</div></div>
    <div class="ns-c"><div class="ns-l">IPv6</div><div class="ns-v" id="nsV6">N/D</div><div class="ns-s" id="nsV6S">&nbsp;</div></div>
    <div class="ns-c" id="nsDnsC"><div class="ns-l">DNS in uso</div><div class="ns-v" id="nsDns">N/D</div><div class="ns-s" id="nsDnsS">&nbsp;</div></div>
  </div>
  <div class="ns-meters">
    <div>
      <div class="ns-pot fb" id="nsPotDc" title="Potenziale velocit&agrave; della connessione internet: ultima misura di un test reale, eseguito ogni 30 minuti (alle :00 e alle :30) dopo i task di aggiornamento. Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11015;</div><div class="ns-pot-s" id="nsPotDs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotD">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span style="color:#22d3ee">&#11015; Download</span><small id="nsDpk">picco 0 Mbps</small></div>
      <div class="ns-lane" id="nsLaneD" title="Risposte DNS servite al PC (dalla cache RAM, dalla rete o bloccate dallo scudo RPZ). Verde = consentita, rosso = NXDOMAIN o bloccata, giallo = errore del resolver (SERVFAIL). Il riquadro indica il tipo di query; grigio = verifica DNSSEC (DS/DNSKEY) non richiesta direttamente da un programma; 'dash' = traffico della dashboard stessa; xN = richieste identiche nello stesso istante unite"></div>
      <div class="ns-row"><div class="ns-a"><svg class="ns-g ns-cv" id="nsDc" viewBox="0 0 200 104" role="img" aria-label="Indicatore download"><polyline class="cv-c" id="nsDc0" style="--i:0" points="20,6.0 30,13.0 40,6.0"/><polyline class="cv-c" id="nsDc1" style="--i:1" points="20,18.5 30,25.5 40,18.5"/><polyline class="cv-c" id="nsDc2" style="--i:2" points="20,31.0 30,38.0 40,31.0"/><polyline class="cv-c" id="nsDc3" style="--i:3" points="20,43.5 30,50.5 40,43.5"/><polyline class="cv-c" id="nsDc4" style="--i:4" points="20,56.0 30,63.0 40,56.0"/><polyline class="cv-c" id="nsDc5" style="--i:5" points="20,68.5 30,75.5 40,68.5"/><polyline class="cv-c" id="nsDc6" style="--i:6" points="20,81.0 30,88.0 40,81.0"/><polyline class="cv-c" id="nsDc7" style="--i:7" points="20,93.5 30,100.5 40,93.5"/><text class="gv" id="nsDv" x="66" y="42">--</text><text class="gu" x="66" y="57">Mbps</text><text class="gu" id="nsDx" x="66" y="82">&nbsp;</text></svg>
      <div class="ns-tr" id="nsDt">&nbsp;</div></div>
      <div class="ns-b"><svg class="ns-hc" viewBox="0 0 200 70" role="img" aria-label="Storico download"><line class="gr" x1="0" x2="200" y1="6" y2="6"/><line class="gr" x1="0" x2="200" y1="32" y2="32"/><line class="gr" x1="0" x2="200" y1="58" y2="58"/><line class="pq" id="nsDq" x1="0" x2="200" y1="58" y2="58"/><path class="ar" id="nsDa" d=""/><path class="ln" id="nsDs" d=""/><circle class="dt" id="nsDd" r="2.6" cx="-10" cy="58"/><text class="gl" id="nsDm" x="2" y="15">&nbsp;</text><text class="gl" id="nsDm2" x="2" y="41">&nbsp;</text><text class="gl" x="0" y="69">-6 min</text><text class="gl" x="200" y="69" text-anchor="end">ora</text></svg><div class="ns-st"><span><small>Attuale</small><b id="nsDSa">--</b></span><span><small>Min</small><b id="nsDSn">--</b></span><span><small>Max</small><b id="nsDSx">--</b></span></div><div class="ns-stc">Mbps, ultimi 6 min</div></div></div>
    </div>
    <div>
      <div class="ns-pot fb" id="nsPotUc" title="Potenziale velocit&agrave; della connessione internet: ultima misura di un test reale, eseguito ogni 30 minuti (alle :00 e alle :30) dopo i task di aggiornamento. Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11014;</div><div class="ns-pot-s" id="nsPotUs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotU">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span style="color:#ff8c1a">&#11014; Upload</span><small id="nsUpk">picco 0 Mbps</small></div>
      <div class="ns-lane" id="nsLaneU" title="Domande uscite davvero verso internet tramite i resolver upstream. Le risposte dalla cache RAM e i blocchi dello scudo RPZ non generano traffico in uscita e non compaiono qui. Il riquadro indica il tipo di query; grigio = verifica DNSSEC (DS/DNSKEY) non richiesta direttamente da un programma; 'dash' = traffico della dashboard stessa; xN = richieste identiche nello stesso istante unite; +N in alto a destra = eventi non mostrati negli ultimi 30 s"></div>
      <div class="ns-row"><div class="ns-a"><svg class="ns-g ns-cv" id="nsUc" viewBox="0 0 200 104" role="img" aria-label="Indicatore upload"><polyline class="cv-c" id="nsUc0" style="--i:7" points="20,13.0 30,6.0 40,13.0"/><polyline class="cv-c" id="nsUc1" style="--i:6" points="20,25.5 30,18.5 40,25.5"/><polyline class="cv-c" id="nsUc2" style="--i:5" points="20,38.0 30,31.0 40,38.0"/><polyline class="cv-c" id="nsUc3" style="--i:4" points="20,50.5 30,43.5 40,50.5"/><polyline class="cv-c" id="nsUc4" style="--i:3" points="20,63.0 30,56.0 40,63.0"/><polyline class="cv-c" id="nsUc5" style="--i:2" points="20,75.5 30,68.5 40,75.5"/><polyline class="cv-c" id="nsUc6" style="--i:1" points="20,88.0 30,81.0 40,88.0"/><polyline class="cv-c" id="nsUc7" style="--i:0" points="20,100.5 30,93.5 40,100.5"/><text class="gv" id="nsUv" x="66" y="42">--</text><text class="gu" x="66" y="57">Mbps</text><text class="gu" id="nsUx" x="66" y="82">&nbsp;</text></svg>
      <div class="ns-tr" id="nsUt">&nbsp;</div></div>
      <div class="ns-b"><svg class="ns-hc" viewBox="0 0 200 70" role="img" aria-label="Storico upload"><line class="gr" x1="0" x2="200" y1="6" y2="6"/><line class="gr" x1="0" x2="200" y1="32" y2="32"/><line class="gr" x1="0" x2="200" y1="58" y2="58"/><line class="pq" id="nsUq" x1="0" x2="200" y1="58" y2="58"/><path class="ar" id="nsUa" d=""/><path class="ln" id="nsUs" d=""/><circle class="dt" id="nsUd" r="2.6" cx="-10" cy="58"/><text class="gl" id="nsUm" x="2" y="15">&nbsp;</text><text class="gl" id="nsUm2" x="2" y="41">&nbsp;</text><text class="gl" x="0" y="69">-6 min</text><text class="gl" x="200" y="69" text-anchor="end">ora</text></svg><div class="ns-st"><span><small>Attuale</small><b id="nsUSa">--</b></span><span><small>Min</small><b id="nsUSn">--</b></span><span><small>Max</small><b id="nsUSx">--</b></span></div><div class="ns-stc">Mbps, ultimi 6 min</div></div></div>
    </div>
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
        <div class="hist-plot"><svg viewBox="0 0 480 124" role="img" aria-label="Storico del funzionamento del bunker"></svg><div class="hist-tip"></div></div>
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
        <div class="hist-plot"><svg viewBox="0 0 480 124" role="img" aria-label="Storico del miglioramento applicato al PC"></svg><div class="hist-tip"></div></div>
        <div class="hist-stats">
          <div class="hist-stat"><span>Min</span><b id="h2min">--</b></div>
          <div class="hist-stat"><span>Media</span><b id="h2avg">--</b></div>
          <div class="hist-stat"><span>Max</span><b id="h2max">--</b></div>
          <div class="hist-stat"><span>Ora</span><b id="h2now">--</b></div>
        </div>
      </div>
    </div>
  </div>
  <footer id="foot">Aggiornamento in tempo reale ogni secondo - Bandierina = paese stimato del server del dominio (IP geolocalizzato offline con DB-IP.com, CC BY 4.0; grafica bandiere Twemoji, CC BY 4.0)</footer>
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
  function nsFlags(d) {
    var fl = d.conn_live && d.conn_live.fl;
    if (!fl) return;
    var m = document.querySelector('.ns-meters'); if (!m) return;
    var SP = { _R: ['\uD83D\uDED1', 'Bloccato dallo scudo RPZ'], _DS: ['\uD83D\uDD10', 'Verifica DNSSEC (DS)'], _DK: ['\uD83D\uDD11', 'Verifica DNSSEC (DNSKEY)'], _SG: ['\uD83D\uDD0F', 'Verifica DNSSEC (RRSIG/NSEC)'], _PT: ['\uD83D\uDD01', 'Ricerca inversa (PTR)'], _NX: ['\u2753', 'Dominio inesistente (NXDOMAIN)'], _ER: ['\u26A0\uFE0F', 'Errore del resolver'], _WW: ['\uD83C\uDF10', 'Paese non determinabile'] };
    var S = nsFlags.S || (nsFlags.S = { rows: { L: {}, R: {} }, prev: { L: {}, R: {} } });
    if (!S.L) {
      S.L = document.createElement('div'); S.L.className = 'rz rz-l';
      S.R = document.createElement('div'); S.R.className = 'rz rz-r';
      m.insertBefore(S.L, m.firstChild); m.appendChild(S.R); m.classList.add('rz-on');
    }
    var H = 20, sides = [['L', S.L, fl.d], ['R', S.R, fl.u]];
    for (var s = 0; s < sides.length; s++) {
      var side = sides[s][0], box = sides[s][1], rows = S.rows[side], prev = S.prev[side];
      var list = (sides[s][2] || []).filter(function (x) { return x && /^(_[A-Z]{1,2}|[A-Z]{2})$/.test(x.cc) && (x.cc.charAt(0) !== '_' || SP[x.cc]); });
      list.sort(function (a, b) { return (b.n - a.n) || (a.cc < b.cc ? -1 : 1); });
      var seen = {};
      box.style.height = (Math.ceil(list.length / 2) * H) + 'px';
      for (var j = 0; j < list.length; j++) {
        var it = list[j], r = rows[it.cc]; seen[it.cc] = 1;
        if (!r) {
          r = rows[it.cc] = document.createElement('div'); r.className = 'rz-i';
          r.innerHTML = side === 'L' ? '<b></b><span class="rz-e"></span>' : '<span class="rz-e"></span><b></b>';
          var ico = side === 'L' ? r.lastChild : r.firstChild;
          if (SP[it.cc]) { ico.textContent = SP[it.cc][0]; r.title = SP[it.cc][1]; }
          else { ico.textContent = String.fromCodePoint(0x1F1E6 + it.cc.charCodeAt(0) - 65, 0x1F1E6 + it.cc.charCodeAt(1) - 65); r.title = it.cc; }
          box.appendChild(r);
        }
        var rowsN = Math.ceil(list.length / 2), col = Math.floor(j / rowsN), row = j % rowsN;
        r.style.top = (row * H) + 'px';
        r.style.left = (col * 50) + '%';
        var b = side === 'L' ? r.firstChild : r.lastChild, txt = Number(it.n).toLocaleString('it-IT');
        if (b.textContent !== txt) {
          var up = prev[it.cc] != null && it.n > prev[it.cc];
          b.textContent = txt;
          if (up) { r.classList.remove('up'); void r.offsetWidth; r.classList.add('up'); }
        }
        prev[it.cc] = it.n;
      }
      for (var k in rows) { if (!seen[k]) { box.removeChild(rows[k]); delete rows[k]; delete prev[k]; } }
    }
  }
  function nsEsc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function nsSet(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
  function nsGauge(v, hist, X, pk, pot) {
    var now = Date.now();
    if (!hist.length || now - (hist._t || 0) >= 3000) { hist.push(v); hist._t = now; if (hist.length > 119) hist.shift(); }
    var hmax = Math.max.apply(null, hist.concat([v]));
    var mx = nsNice(Math.max(pot > 0 ? pot : hmax * 1.15, v));
    var f = Math.min(v / mx, 1);
    var sv = document.getElementById('ns' + X + 'c');
    if (sv && sv._lit !== 8) {
      sv._lit = 8;
      for (var ci = 0; ci < 8; ci++) { var ch = document.getElementById('ns' + X + 'c' + ci); if (ch) ch.setAttribute('class', 'cv-c on'); }
    }
    var el = document.getElementById('ns' + X + 'v'); if (el) { el.textContent = nsFmt(v); el.style.fill = ''; }
    el = document.getElementById('ns' + X + 'x'); if (el) el.textContent = Math.round(f * 100) + '% della scala';
    el = document.getElementById('ns' + X + 'pk'); if (el) el.textContent = 'picco ' + Math.round(pk) + ' Mbps';
    var prev = hist.slice(-6);
    el = document.getElementById('ns' + X + 't');
    if (el) {
      if (prev.length < 3) { el.innerHTML = '&nbsp;'; }
      else {
        var avg = prev.reduce(function (x, y) { return x + y; }, 0) / prev.length;
        var dl = avg > 0.05 ? (v - avg) / avg * 100 : 0;
        var stable = Math.abs(dl) < 3 || Math.abs(v - avg) < 0.5;
        el.innerHTML = '<span style="color:' + (stable ? 'var(--dim)' : (dl > 0 ? '#3ddc84' : '#ffb300')) + '">' + (stable ? '&#9644; stabile' : (dl > 0 ? '&#9650; +' : '&#9660; ') + Math.round(dl) + '%') + '</span> <span class="ns-trs">rispetto alla media recente</span>';
      }
    }
    var pts = hist.concat([v]), n = pts.length, cm = nsNice(hmax * 1.15), step = 200 / 119, d = '', last = null, first = null;
    for (var i = 0; i < n; i++) {
      var x = 200 - (n - 1 - i) * step, y = 58 - Math.min(pts[i] / cm, 1) * 52;
      d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1);
      if (first === null) first = x; last = [x, y];
    }
    el = document.getElementById('ns' + X + 's'); if (el) el.setAttribute('d', d);
    el = document.getElementById('ns' + X + 'a'); if (el) el.setAttribute('d', d + 'L' + last[0].toFixed(1) + ' 58L' + first.toFixed(1) + ' 58Z');
    el = document.getElementById('ns' + X + 'd'); if (el) { el.setAttribute('cx', last[0].toFixed(1)); el.setAttribute('cy', last[1].toFixed(1)); }
    el = document.getElementById('ns' + X + 'q'); if (el) { var py = 58 - Math.min(hmax / cm, 1) * 52; el.setAttribute('y1', py.toFixed(1)); el.setAttribute('y2', py.toFixed(1)); }
    el = document.getElementById('ns' + X + 'm'); if (el) el.textContent = cm + ' Mbps';
    el = document.getElementById('ns' + X + 'm2'); if (el) el.textContent = (cm % 2 === 0) ? String(cm / 2) : nsFmt(cm / 2);
    el = document.getElementById('ns' + X + 'Sa'); if (el) el.textContent = nsFmt(v);
    el = document.getElementById('ns' + X + 'Sn'); if (el) el.textContent = nsFmt(Math.min.apply(null, pts));
    el = document.getElementById('ns' + X + 'Sx'); if (el) el.textContent = nsFmt(hmax);
  }
  function nsGaugeOff(X) {
    var el = document.getElementById('ns' + X + 'v'); if (el) { el.textContent = 'N/D'; el.style.fill = 'var(--dim)'; }
    var sv = document.getElementById('ns' + X + 'c'); if (sv) { sv._lit = -1; for (var ci = 0; ci < 8; ci++) { var ch = document.getElementById('ns' + X + 'c' + ci); if (ch) ch.setAttribute('class', 'cv-c'); } }
    el = document.getElementById('ns' + X + 'x'); if (el) el.innerHTML = '&nbsp;';
    el = document.getElementById('ns' + X + 't'); if (el) el.innerHTML = '&nbsp;';
    el = document.getElementById('ns' + X + 's'); if (el) el.setAttribute('d', '');
    el = document.getElementById('ns' + X + 'a'); if (el) el.setAttribute('d', '');
    el = document.getElementById('ns' + X + 'd'); if (el) el.setAttribute('cx', '-10');
  var ids = ['Sa', 'Sn', 'Sx'];
  for (var si = 0; si < 3; si++) { el = document.getElementById('ns' + X + ids[si]); if (el) el.textContent = '--'; }
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
    try { nsFlags(d); } catch (e) {}
    var p = d.line_potential, n = d.net_speed;
    var cfg = [['nsPotDc', 'nsPotD', 'nsPotDs', 'down_mbps'], ['nsPotUc', 'nsPotU', 'nsPotUs', 'up_mbps']];
    for (var i = 0; i < cfg.length; i++) {
      var c = document.getElementById(cfg[i][0]), v = document.getElementById(cfg[i][1]), s = document.getElementById(cfg[i][2]);
      if (!c || !v || !s) continue;
      if (p && p.ok && p[cfg[i][3]] > 0) {
        var pot = p[cfg[i][3]];
        v.textContent = String(Math.floor(pot));
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
      nsGauge(n.down_mbps, nsRingD, 'D', nsPkD, (d.line_potential && d.line_potential.ok && d.line_potential.fonte === 'misura' && d.line_potential.down_mbps > 0) ? d.line_potential.down_mbps : 0);
      nsGauge(n.up_mbps, nsRingU, 'U', nsPkU, (d.line_potential && d.line_potential.ok && d.line_potential.fonte === 'misura' && d.line_potential.up_mbps > 0) ? d.line_potential.up_mbps : 0);
    } else {
      nsGaugeOff('D');
      nsGaugeOff('U');
    }
    var ip = d.connettivita_ip;
    if (ip) {
      nsSet('nsPub', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_wan) : 'N/D');
      nsSet('nsPubS', ip.ipv4_wan_ok ? [ip.ipv4_loc, ip.ipv4_isp].filter(Boolean).map(nsEsc).join('<br>') || '&nbsp;' : 'non disponibile');
      // IPv4/IPv6: se ci sono piu' indirizzi vengono mostrati TUTTI, uno per riga
      var l4 = ip.ipv4_lan_ok ? String(ip.ipv4_lan).split(', ') : [];
      nsSet('nsV4', l4.length ? l4.map(nsEsc).join('<br>') : 'N/D');
      nsSet('nsV4S', '<span class="ns-dot ' + (l4.length ? 'ok' : 'bad') + '"></span>' + (l4.length ? 'rete locale' + (l4.length > 1 ? ' (' + l4.length + ' indirizzi)' : '') : 'offline'));
      var l6 = ip.ipv6_lan_ok ? String(ip.ipv6_lan).split(', ') : [];
      var a6 = [];
      if (ip.ipv6_wan_ok) a6.push(ip.ipv6_wan);
      l6.forEach(function (x) { if (a6.indexOf(x) < 0) a6.push(x); });
      if (a6.length) {
        nsSet('nsV6', a6.map(nsEsc).join('<br>'));
        nsSet('nsV6S', '<span class="ns-dot ok"></span>' + (ip.ipv6_wan_ok ? 'pubblico' + (l6.length ? ' + ' + l6.length + (l6.length > 1 ? ' locali' : ' locale') : '') : 'solo locale' + (l6.length > 1 ? ' (' + l6.length + ' indirizzi)' : '')));
      } else { nsSet('nsV6', 'N/D'); nsSet('nsV6S', '<span class="ns-dot bad"></span>non disponibile'); }
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

  // ---- Connessioni live sotto Download/Upload (v1106.7) ----
  // Download = risposte in arrivo al PC (upstream con IP, cache, RPZ); Upload = query uscite davvero verso i resolver upstream (IP di destinazione). Colonne disgiunte (v1106.9).
  // Otto righe visibili (v1107.3), le nuove entrano dal basso e salgono in modo fluido (moto smorzato, senza scatti):
  // la prima e l'ultima riga sono meno luminose, quelle centrali piene. Verde/rosso/ambra come il live log della Pro.
  var CE_RH = 22, CE_GAP = 900, CE_MAXQ = 3, CE_ROWS = 8;
  var CE_OP = [[-1, 0], [0, 0.45], [1, 0.8], [2, 1], [6, 1], [7, 0.8], [8, 0]];
  var ceReduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  var ceSrc = null, ceLastN = 0;
  function ceOp(p) {
    if (p <= -1 || p >= CE_ROWS) return 0;
    for (var i = 0; i < CE_OP.length - 1; i++) {
      var a = CE_OP[i], b = CE_OP[i + 1];
      if (p >= a[0] && p <= b[0]) return a[1] + (b[1] - a[1]) * ((p - a[0]) / (b[0] - a[0]));
    }
    return 0;
  }
  // v1107.4: bandierina del paese del server. Il server manda geo = {dominio: 'IT'} per i domini del registro gia' risolti;
  // le righe nate prima della risoluzione restano 'in attesa' e si completano al primo giro utile.
  var ceGeo = Object.create(null), cePend = Object.create(null), ceGeoN = 0;
  function ceSetFlag(s, cc) {
    if (cc === '-') { if (s._q) return; s.textContent = '\u{1F310}'; s.title = 'Paese non determinabile'; return; }
    if (typeof cc !== 'string' || !/^[A-Z]{2}$/.test(cc)) return;
    try { s.textContent = String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65); s.title = cc; } catch (e) { /* senza bandierina */ }
  }
  function ceFlag(s, dom, quiet) {
    s._q = !!quiet;
    var cc = ceGeo[dom];
    if (cc) { ceSetFlag(s, cc); return; }
    s._t = Date.now();
    (cePend[dom] || (cePend[dom] = [])).push(s);
  }
  function ceGeoIn(g) {
    if (ceGeoN > 2000) { ceGeo = Object.create(null); ceGeoN = 0; }
    if (g && typeof g === 'object') {
      for (var k in g) { if (Object.prototype.hasOwnProperty.call(g, k)) { if (!ceGeo[k]) ceGeoN++; ceGeo[k] = g[k]; } }
    }
    for (var d in cePend) {
      var arr = cePend[d], cc = ceGeo[d], keep = [];
      for (var i = 0; i < arr.length; i++) { var s = arr[i]; if (!s.isConnected) continue; if (cc) ceSetFlag(s, cc); else if (Date.now() - (s._t || 0) > 10000) ceSetFlag(s, '-'); else keep.push(s); }
      if (keep.length) cePend[d] = keep; else delete cePend[d];
    }
  }
  function CeLane(id) {
    this.el = document.getElementById(id); this.items = []; this.q = []; this.last = 0;
    this.drops = []; this.moreTxt = '';   // v1107.2: eventi scartati (istante, quantita') per l'indicatore +N
    this.more = null;
    if (this.el) { this.more = document.createElement('div'); this.more.className = 'ce-more'; this.el.appendChild(this.more); }
  }
  // v1107.2: richieste identiche (stesso nome, tipo, orario e verso) ancora in coda = una sola riga con xN;
  // gli eventi che escono dalla coda senza essere mostrati vengono contati nell'indicatore +N (ultimi 30 s)
  CeLane.prototype.push = function (ev) {
    var key = ev.d + '|' + (ev.q || '') + '|' + (ev.t || '') + '|' + ev.v;
    ev.x = ev.x || 1;
    for (var i = 0; i < this.q.length; i++) {
      var o = this.q[i];
      if (o.d + '|' + (o.q || '') + '|' + (o.t || '') + '|' + o.v === key) { o.x += ev.x; return; }
    }
    this.q.push(ev);
    while (this.q.length > CE_MAXQ) { var g = this.q.shift(); this.drops.push([performance.now(), g.x || 1]); }
  };
  CeLane.prototype.updMore = function (now) {
    if (!this.more) return;
    while (this.drops.length && now - this.drops[0][0] > 30000) this.drops.shift();
    var n = 0; for (var i = 0; i < this.drops.length; i++) n += this.drops[i][1];
    var tx = n > 0 ? '+' + n : '';
    if (tx !== this.moreTxt) { this.moreTxt = tx; this.more.textContent = tx; this.more.style.opacity = n > 0 ? '1' : '0'; }
  };
  CeLane.prototype.add = function (ev) {
    if (!this.el) return;
    var cls = ev.c === 'NOERROR' ? 'ok' : (ev.c === 'NXDOMAIN' ? 'no' : 'er');
    var el = document.createElement('div');
    el.className = 'ce ' + cls + (ev.s ? ' sub' : '') + (ev.o ? ' ow' : '');
    var d = document.createElement('span'); d.className = 'cd';
    var t = document.createElement('span'); t.className = 'ct'; t.textContent = ev.t || '--:--:--';
    var n = document.createElement('span'); n.className = 'cn'; n.textContent = ev.d || '-';
    var f = document.createElement('span'); f.className = 'cf';
    if (ev.v === 'r') { f.textContent = '\u{1F6D1}'; f.title = 'Bloccato dallo scudo RPZ'; }
    else if (ev.s) {   // sotto-query DNSSEC: DS = chiave+lucchetto, DNSKEY = chiave, RRSIG/NSEC = sigillo
      var qk = String(ev.q || '').toUpperCase();
      f.textContent = qk === 'DS' ? '\u{1F510}' : (qk === 'DNSKEY' ? '\u{1F511}' : '\u{1F50F}');
      f.title = 'Verifica DNSSEC (' + qk + ')';
    }
    else if (/\.(in-addr|ip6)\.arpa$/i.test(String(ev.d || '')) || ev.q === 'PTR') { f.textContent = '\u{1F501}'; f.title = 'Ricerca inversa (PTR): da IP a nome';
      if (/\.in-addr\.arpa$/i.test(String(ev.d || ''))) { var pf = document.createElement('span'); f.appendChild(pf); f.classList.add('cf2'); ceFlag(pf, ev.d, true); }
    }
    else if (ev.c === 'NXDOMAIN') { f.textContent = '\u2753'; f.title = 'Dominio inesistente (NXDOMAIN)'; }
    else if (ev.c !== 'NOERROR') { f.textContent = '\u26A0\uFE0F'; f.title = 'Errore del resolver (' + ev.c + ')'; }
    else ceFlag(f, ev.d);
    el.appendChild(d); el.appendChild(t); el.appendChild(f); el.appendChild(n);
    if (ev.o) { var w = document.createElement('span'); w.className = 'cw'; w.textContent = 'dash'; el.appendChild(w); }
    if (ev.x > 1) { var xx = document.createElement('span'); xx.className = 'cx'; xx.textContent = '\u00d7' + ev.x; el.appendChild(xx); }
    if (ev.q) { var qq = document.createElement('span'); qq.className = 'cq'; qq.textContent = ev.q; el.appendChild(qq); }
    if (ev.showVia) {
      var v = document.createElement('span'); v.className = 'cv';
      v.textContent = ev.vt ? ev.vt : (ev.v === 'r' ? 'rpz' : (ev.v === 'n' ? 'rete' : 'cache'));
      el.appendChild(v);
    }
    this.el.appendChild(el);
    for (var i = 0; i < this.items.length; i++) this.items[i].target -= 1;
    this.items.push({ el: el, pos: CE_ROWS, target: CE_ROWS - 1 });
  };
  CeLane.prototype.tick = function (dt, now) {
    if (this.q.length && now - this.last >= CE_GAP) { this.add(this.q.shift()); this.last = now; }
    if (!this.items.length) return;
    var k = ceReduce ? 1 : 1 - Math.exp(-dt * 6);
    for (var i = this.items.length - 1; i >= 0; i--) {
      var it = this.items[i];
      it.pos += (it.target - it.pos) * k;
      it.el.style.transform = 'translateY(' + (it.pos * CE_RH).toFixed(2) + 'px)';
      it.el.style.opacity = ceOp(it.pos).toFixed(3);
      if (it.target < -1 && it.pos < -0.98) { it.el.remove(); this.items.splice(i, 1); }
    }
  };
  var ceLaneD = new CeLane('nsLaneD'), ceLaneU = new CeLane('nsLaneU');
  var cePrev = performance.now();
  function ceFrame(now) {
    var dt = Math.min(0.1, (now - cePrev) / 1000); cePrev = now;
    ceLaneD.tick(dt, now); ceLaneU.tick(dt, now);
    ceLaneD.updMore(now); ceLaneU.updMore(now);
    requestAnimationFrame(ceFrame);
  }
  requestAnimationFrame(ceFrame);
  function connUpdate(d) {
    var cl = d && d.conn_live;
    if (!cl || cl.ev == null) return;
    try { ceGeoIn(cl.geo); } catch (e) { /* le bandierine non devono mai bloccare il ticker */ }
    var ev = Array.isArray(cl.ev) ? cl.ev : [cl.ev];
    var src = String(cl.src || '');
    var mx = ceLastN;
    for (var i = 0; i < ev.length; i++) { var nn = ev[i].n | 0; if (nn > mx) mx = nn; }
    if (src !== ceSrc) {   // primo contatto (o riavvio del server): si parte da adesso, senza riproporre il passato
      ceSrc = src; ceLastN = mx; return;
    }
    for (var j = 0; j < ev.length; j++) {
      var e = ev[j];
      if ((e.n | 0) <= ceLastN) continue;
      // v1106.9: colonne disgiunte. k='u' = query inviata a un upstream (Upload), altrimenti risposta in arrivo (Download)
      if (e.k === 'u') ceLaneU.push({ n: e.n, t: e.t, d: e.d, c: e.c, v: e.v, vt: e.ip || 'rete', q: e.q, s: e.s, o: e.o, showVia: true });
      else ceLaneD.push({ n: e.n, t: e.t, d: e.d, c: e.c, v: e.v, vt: (e.v === 'n' && e.ip) ? e.ip : '', q: e.q, s: e.s, o: e.o, showVia: true });
    }
    ceLastN = mx;
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
      try { connUpdate(d); } catch (e) { /* le connessioni live non devono mai bloccare le lancette */ }

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
  var HW = 480, HH = 124, PL = 48, PR = 12, PT = 12, PB = 24;
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
<title>UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1107.7 - by Mauro Bigoni</title>
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
  .ns-g { display: block; width: 100%; max-width: 250px; margin: 0 auto; }
  .ns-g .gl { fill: var(--dim); font-size: 10px; }
  .ns-g .gt { stroke: var(--dim); stroke-width: 1.2; }
  .ns-g .gv { fill: var(--text); font-family: var(--font-mono); font-size: 22px; }
  .ns-g .gu { fill: var(--dim); font-size: 11px; }
  .ns-g .gnd { transform-origin: 100px 100px; transition: transform 0.6s ease; }
  .ns-cv .gv { font-size: 24px; }
  .ns-cv .cv-c { fill: none; stroke: rgba(255,255,255,0.12); stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round; transition: stroke 0.4s ease; }
  .ns-cv .cv-c.on { stroke: var(--cv); animation: cvPulse 1.2s ease-in-out infinite; animation-delay: calc(var(--i) * 0.15s); }
  @keyframes cvPulse { 0%, 100% { stroke-opacity: 0.18; } 35% { stroke-opacity: 1; } }
  @media (prefers-reduced-motion: reduce) { .ns-cv .cv-c.on { animation: none; } }
  #nsDc { --cv: #22d3ee; } #nsUc { --cv: #ff8c1a; }
  #nsDv { fill: #22d3ee; } #nsUv { fill: #ff8c1a; }
  #nsDs { stroke: #22d3ee; } #nsDa, #nsDd { fill: #22d3ee; }
  #nsUs { stroke: #ff8c1a; } #nsUa, #nsUd { fill: #ff8c1a; }
  #nsDq, #nsUq { stroke: rgba(219,229,238,0.5); }
  .ns-st { display: flex; gap: 6px; max-width: 250px; margin: 6px auto 0; }
  .ns-st span { flex: 1; min-width: 0; text-align: center; background: rgba(255,255,255,0.03); border: 1px solid var(--border); border-radius: 8px; padding: 4px 2px; }
  .ns-st small { display: block; font-size: 0.66em; letter-spacing: 0.07em; text-transform: uppercase; color: var(--dim); }
  .ns-st b { font-family: var(--font-mono); font-size: 0.95em; color: var(--text); font-weight: 700; }
  .ns-stc { max-width: 250px; margin: 3px auto 0; font-size: 0.66em; text-align: center; color: var(--dim); }
  #nsDSa { color: #22d3ee; } #nsUSa { color: #ff8c1a; }
  #nsPotDc:not(.fb) .ns-pot-v b { color: #22d3ee; } #nsPotUc:not(.fb) .ns-pot-v b { color: #ff8c1a; }
  .ns-tr { font-size: 0.76em; text-align: center; margin: 2px 0 4px; min-height: 1.3em; }
  .ns-trs { color: var(--dim); }
  .ns-hc { display: block; width: 100%; max-width: 250px; margin: 2px auto 0; }
  .ns-hc .gl { fill: var(--dim); font-size: 9px; }
  .ns-hc .gr { stroke: rgba(255,255,255,0.12); stroke-width: 1; }
  .ns-hc .ar { fill: var(--accent); fill-opacity: 0.16; }
  .ns-hc .ln { fill: none; stroke: var(--accent); stroke-width: 1.8; stroke-linejoin: round; }
  .ns-hc .dt { fill: var(--accent); }
  .ns-hc .pq { stroke: #ffb300; stroke-width: 1; stroke-dasharray: 4 3; }
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
    <h1>&#128737; UNBOUND BUNKER CERBERO - DASHBOARD LIVE Versione 1107.7 - by Mauro Bigoni</h1>
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
      <div class="ns-pot fb" id="nsPotDc" title="Potenziale velocit&agrave; della connessione internet: ultima misura di un test reale, eseguito ogni 30 minuti (alle :00 e alle :30) dopo i task di aggiornamento. Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11015;</div><div class="ns-pot-s" id="nsPotDs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotD">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span style="color:#22d3ee">&#11015; Download</span><small id="nsDpk">picco 0 Mbps</small></div>
      <svg class="ns-g ns-cv" id="nsDc" viewBox="0 0 200 104" role="img" aria-label="Indicatore download"><polyline class="cv-c" id="nsDc0" style="--i:0" points="20,6.0 30,13.0 40,6.0"/><polyline class="cv-c" id="nsDc1" style="--i:1" points="20,18.5 30,25.5 40,18.5"/><polyline class="cv-c" id="nsDc2" style="--i:2" points="20,31.0 30,38.0 40,31.0"/><polyline class="cv-c" id="nsDc3" style="--i:3" points="20,43.5 30,50.5 40,43.5"/><polyline class="cv-c" id="nsDc4" style="--i:4" points="20,56.0 30,63.0 40,56.0"/><polyline class="cv-c" id="nsDc5" style="--i:5" points="20,68.5 30,75.5 40,68.5"/><polyline class="cv-c" id="nsDc6" style="--i:6" points="20,81.0 30,88.0 40,81.0"/><polyline class="cv-c" id="nsDc7" style="--i:7" points="20,93.5 30,100.5 40,93.5"/><text class="gv" id="nsDv" x="66" y="42">--</text><text class="gu" x="66" y="57">Mbps</text><text class="gu" id="nsDx" x="66" y="82">&nbsp;</text></svg>
      <div class="ns-tr" id="nsDt">&nbsp;</div>
      <svg class="ns-hc" viewBox="0 0 200 70" role="img" aria-label="Storico download"><line class="gr" x1="0" x2="200" y1="6" y2="6"/><line class="gr" x1="0" x2="200" y1="32" y2="32"/><line class="gr" x1="0" x2="200" y1="58" y2="58"/><line class="pq" id="nsDq" x1="0" x2="200" y1="58" y2="58"/><path class="ar" id="nsDa" d=""/><path class="ln" id="nsDs" d=""/><circle class="dt" id="nsDd" r="2.6" cx="-10" cy="58"/><text class="gl" id="nsDm" x="2" y="15">&nbsp;</text><text class="gl" id="nsDm2" x="2" y="41">&nbsp;</text><text class="gl" x="0" y="69">-6 min</text><text class="gl" x="200" y="69" text-anchor="end">ora</text></svg><div class="ns-st"><span><small>Attuale</small><b id="nsDSa">--</b></span><span><small>Min</small><b id="nsDSn">--</b></span><span><small>Max</small><b id="nsDSx">--</b></span></div><div class="ns-stc">Mbps, ultimi 6 min</div>
    </div>
    <div>
      <div class="ns-pot fb" id="nsPotUc" title="Potenziale velocit&agrave; della connessione internet: ultima misura di un test reale, eseguito ogni 30 minuti (alle :00 e alle :30) dopo i task di aggiornamento. Se vedi &laquo;velocit&agrave; scheda&raquo; il test non ha ancora prodotto una misura valida">
        <div><div class="ns-pot-l">&#128225; Velocit&agrave; linea &#11014;</div><div class="ns-pot-s" id="nsPotUs">&nbsp;</div></div>
        <div class="ns-pot-v"><b id="nsPotU">--</b><small>Mbps</small></div>
      </div>
      <div class="ns-mh"><span style="color:#ff8c1a">&#11014; Upload</span><small id="nsUpk">picco 0 Mbps</small></div>
      <svg class="ns-g ns-cv" id="nsUc" viewBox="0 0 200 104" role="img" aria-label="Indicatore upload"><polyline class="cv-c" id="nsUc0" style="--i:7" points="20,13.0 30,6.0 40,13.0"/><polyline class="cv-c" id="nsUc1" style="--i:6" points="20,25.5 30,18.5 40,25.5"/><polyline class="cv-c" id="nsUc2" style="--i:5" points="20,38.0 30,31.0 40,38.0"/><polyline class="cv-c" id="nsUc3" style="--i:4" points="20,50.5 30,43.5 40,50.5"/><polyline class="cv-c" id="nsUc4" style="--i:3" points="20,63.0 30,56.0 40,63.0"/><polyline class="cv-c" id="nsUc5" style="--i:2" points="20,75.5 30,68.5 40,75.5"/><polyline class="cv-c" id="nsUc6" style="--i:1" points="20,88.0 30,81.0 40,88.0"/><polyline class="cv-c" id="nsUc7" style="--i:0" points="20,100.5 30,93.5 40,100.5"/><text class="gv" id="nsUv" x="66" y="42">--</text><text class="gu" x="66" y="57">Mbps</text><text class="gu" id="nsUx" x="66" y="82">&nbsp;</text></svg>
      <div class="ns-tr" id="nsUt">&nbsp;</div>
      <svg class="ns-hc" viewBox="0 0 200 70" role="img" aria-label="Storico upload"><line class="gr" x1="0" x2="200" y1="6" y2="6"/><line class="gr" x1="0" x2="200" y1="32" y2="32"/><line class="gr" x1="0" x2="200" y1="58" y2="58"/><line class="pq" id="nsUq" x1="0" x2="200" y1="58" y2="58"/><path class="ar" id="nsUa" d=""/><path class="ln" id="nsUs" d=""/><circle class="dt" id="nsUd" r="2.6" cx="-10" cy="58"/><text class="gl" id="nsUm" x="2" y="15">&nbsp;</text><text class="gl" id="nsUm2" x="2" y="41">&nbsp;</text><text class="gl" x="0" y="69">-6 min</text><text class="gl" x="200" y="69" text-anchor="end">ora</text></svg><div class="ns-st"><span><small>Attuale</small><b id="nsUSa">--</b></span><span><small>Min</small><b id="nsUSn">--</b></span><span><small>Max</small><b id="nsUSx">--</b></span></div><div class="ns-stc">Mbps, ultimi 6 min</div>
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
function nsSet(id, html) { var e = document.getElementById(id); if (e) e.innerHTML = html; }
function nsGauge(v, hist, X, pk, pot) {
  var now = Date.now();
  if (!hist.length || now - (hist._t || 0) >= 3000) { hist.push(v); hist._t = now; if (hist.length > 119) hist.shift(); }
  var hmax = Math.max.apply(null, hist.concat([v]));
  var mx = nsNice(Math.max(pot > 0 ? pot : hmax * 1.15, v));
  var f = Math.min(v / mx, 1);
  var sv = document.getElementById('ns' + X + 'c');
    if (sv && sv._lit !== 8) {
      sv._lit = 8;
      for (var ci = 0; ci < 8; ci++) { var ch = document.getElementById('ns' + X + 'c' + ci); if (ch) ch.setAttribute('class', 'cv-c on'); }
    }
    var el = document.getElementById('ns' + X + 'v'); if (el) { el.textContent = nsFmt(v); el.style.fill = ''; }
    el = document.getElementById('ns' + X + 'x'); if (el) el.textContent = Math.round(f * 100) + '% della scala';
    el = document.getElementById('ns' + X + 'pk'); if (el) el.textContent = 'picco ' + Math.round(pk) + ' Mbps';
    var prev = hist.slice(-6);
  el = document.getElementById('ns' + X + 't');
  if (el) {
    if (prev.length < 3) { el.innerHTML = '&nbsp;'; }
    else {
      var avg = prev.reduce(function (x, y) { return x + y; }, 0) / prev.length;
      var dl = avg > 0.05 ? (v - avg) / avg * 100 : 0;
      var stable = Math.abs(dl) < 3 || Math.abs(v - avg) < 0.5;
      el.innerHTML = '<span style="color:' + (stable ? 'var(--dim)' : (dl > 0 ? '#3ddc84' : '#ffb300')) + '">' + (stable ? '&#9644; stabile' : (dl > 0 ? '&#9650; +' : '&#9660; ') + Math.round(dl) + '%') + '</span> <span class="ns-trs">rispetto alla media recente</span>';
    }
  }
  var pts = hist.concat([v]), n = pts.length, cm = nsNice(hmax * 1.15), step = 200 / 119, d = '', last = null, first = null;
  for (var i = 0; i < n; i++) {
    var x = 200 - (n - 1 - i) * step, y = 58 - Math.min(pts[i] / cm, 1) * 52;
    d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1);
    if (first === null) first = x; last = [x, y];
  }
  el = document.getElementById('ns' + X + 's'); if (el) el.setAttribute('d', d);
  el = document.getElementById('ns' + X + 'a'); if (el) el.setAttribute('d', d + 'L' + last[0].toFixed(1) + ' 58L' + first.toFixed(1) + ' 58Z');
  el = document.getElementById('ns' + X + 'd'); if (el) { el.setAttribute('cx', last[0].toFixed(1)); el.setAttribute('cy', last[1].toFixed(1)); }
  el = document.getElementById('ns' + X + 'q'); if (el) { var py = 58 - Math.min(hmax / cm, 1) * 52; el.setAttribute('y1', py.toFixed(1)); el.setAttribute('y2', py.toFixed(1)); }
  el = document.getElementById('ns' + X + 'm'); if (el) el.textContent = cm + ' Mbps';
    el = document.getElementById('ns' + X + 'm2'); if (el) el.textContent = (cm % 2 === 0) ? String(cm / 2) : nsFmt(cm / 2);
    el = document.getElementById('ns' + X + 'Sa'); if (el) el.textContent = nsFmt(v);
    el = document.getElementById('ns' + X + 'Sn'); if (el) el.textContent = nsFmt(Math.min.apply(null, pts));
    el = document.getElementById('ns' + X + 'Sx'); if (el) el.textContent = nsFmt(hmax);
}
function nsGaugeOff(X) {
  var el = document.getElementById('ns' + X + 'v'); if (el) { el.textContent = 'N/D'; el.style.fill = 'var(--dim)'; }
  var sv = document.getElementById('ns' + X + 'c'); if (sv) { sv._lit = -1; for (var ci = 0; ci < 8; ci++) { var ch = document.getElementById('ns' + X + 'c' + ci); if (ch) ch.setAttribute('class', 'cv-c'); } }
  el = document.getElementById('ns' + X + 'x'); if (el) el.innerHTML = '&nbsp;';
  el = document.getElementById('ns' + X + 't'); if (el) el.innerHTML = '&nbsp;';
  el = document.getElementById('ns' + X + 's'); if (el) el.setAttribute('d', '');
  el = document.getElementById('ns' + X + 'a'); if (el) el.setAttribute('d', '');
  el = document.getElementById('ns' + X + 'd'); if (el) el.setAttribute('cx', '-10');
  var ids = ['Sa', 'Sn', 'Sx'];
  for (var si = 0; si < 3; si++) { el = document.getElementById('ns' + X + ids[si]); if (el) el.textContent = '--'; }
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
      v.textContent = String(Math.floor(pot));
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
    nsGauge(n.down_mbps, nsRingD, 'D', nsPkD, (d.line_potential && d.line_potential.ok && d.line_potential.fonte === 'misura' && d.line_potential.down_mbps > 0) ? d.line_potential.down_mbps : 0);
    nsGauge(n.up_mbps, nsRingU, 'U', nsPkU, (d.line_potential && d.line_potential.ok && d.line_potential.fonte === 'misura' && d.line_potential.up_mbps > 0) ? d.line_potential.up_mbps : 0);
  } else {
    nsGaugeOff('D');
    nsGaugeOff('U');
  }
  var ip = d.connettivita_ip;
  if (ip) {
    nsSet('nsPub', ip.ipv4_wan_ok ? nsEsc(ip.ipv4_wan) : 'N/D');
    nsSet('nsPubS', ip.ipv4_wan_ok ? [ip.ipv4_loc, ip.ipv4_isp].filter(Boolean).map(nsEsc).join('<br>') || '&nbsp;' : 'non disponibile');
    // IPv4/IPv6: se ci sono piu' indirizzi vengono mostrati TUTTI, uno per riga
    var l4 = ip.ipv4_lan_ok ? String(ip.ipv4_lan).split(', ') : [];
    nsSet('nsV4', l4.length ? l4.map(nsEsc).join('<br>') : 'N/D');
    nsSet('nsV4S', '<span class="ns-dot ' + (l4.length ? 'ok' : 'bad') + '"></span>' + (l4.length ? 'rete locale' + (l4.length > 1 ? ' (' + l4.length + ' indirizzi)' : '') : 'offline'));
    var l6 = ip.ipv6_lan_ok ? String(ip.ipv6_lan).split(', ') : [];
    var a6 = [];
    if (ip.ipv6_wan_ok) a6.push(ip.ipv6_wan);
    l6.forEach(function (x) { if (a6.indexOf(x) < 0) a6.push(x); });
    if (a6.length) {
      nsSet('nsV6', a6.map(nsEsc).join('<br>'));
      nsSet('nsV6S', '<span class="ns-dot ok"></span>' + (ip.ipv6_wan_ok ? 'pubblico' + (l6.length ? ' + ' + l6.length + (l6.length > 1 ? ' locali' : ' locale') : '') : 'solo locale' + (l6.length > 1 ? ' (' + l6.length + ' indirizzi)' : '')));
    } else { nsSet('nsV6', 'N/D'); nsSet('nsV6S', '<span class="ns-dot bad"></span>non disponibile'); }
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
            } elseif ($request.Url.AbsolutePath -eq "/api/radio-meta" -and $request.HttpMethod -eq "GET") {
                # Titolo della canzone in onda, letto dal server (metadati ICY). Stesse difese delle altre rotte radio (header custom,
                # Host/Origin) e in piu' accetta SOLO indirizzi presenti nell'elenco radio: non e' un proxy aperto.
                $rmStatus = 403
                $rmBody   = '{"ok":false}'
                try {
                    $hdrOk  = ([string]$request.Headers["X-Bunker-Radio"] -eq "1")
                    $hostOk = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))
                    if ($hdrOk -and $hostOk -and $origOk) {
                        $rmUrl = [string]$request.QueryString["u"]
                        $rmAllowed = $false
                        if ($rmUrl -and $rmUrl.Length -le 300) {
                            $rmB = $script:HtmlShell.IndexOf('// RADIO_LIST_' + 'BEGIN', [System.StringComparison]::Ordinal)
                            $rmE = if ($rmB -ge 0) { $script:HtmlShell.IndexOf('// RADIO_LIST_' + 'END', $rmB, [System.StringComparison]::Ordinal) } else { -1 }
                            if ($rmB -ge 0 -and $rmE -gt $rmB) {
                                $rmBlock = $script:HtmlShell.Substring($rmB, $rmE - $rmB)
                                foreach ($rmM in [regex]::Matches($rmBlock, "'(https?://[^']+)'")) {
                                    if ($rmM.Groups[1].Value -ceq $rmUrl) { $rmAllowed = $true; break }
                                }
                            }
                        }
                        if ($rmAllowed) {
                            $rmTitle = Get-RadioMetaTitle $rmUrl
                            $rmPending = (-not $script:RadioMetaCache.ContainsKey($rmUrl))
                            $rmStatus = 200
                            $rmBody   = (@{ ok = $true; title = $rmTitle; pending = $rmPending } | ConvertTo-Json -Compress)
                        } else {
                            $rmStatus = 400
                        }
                    }
                } catch {
                    $rmStatus = 500
                    Write-DashLog "Errore in /api/radio-meta: $($_.Exception.Message)"
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($rmBody)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $rmStatus
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/radio-add" -and $request.HttpMethod -eq "POST") {
                # Aggiunge una radio all'elenco scritto dentro questo stesso script: la riga viene inserita tra i due commenti
                # JavaScript che delimitano l'elenco (marcatori RADIO_LIST, parte BEGIN e parte END, nella pagina contenitore).
                # Stesse difese di /api/light-sample: header custom (blocca POST cross-site) e controllo Host/Origin (anti DNS-rebinding).
                # Nome e URL passano solo con caratteri ammessi (niente apici, backslash, < o >): nel .ps1 puo' finire al massimo
                # una riga dell'elenco, mai codice. Il riavvio completo lo chiede poi la pagina con /api/restart.
                $raStatus = 400
                $raBody   = '{"ok":false,"error":"Richiesta non valida"}'
                try {
                    $hdrOk  = ([string]$request.Headers["X-Bunker-Radio"] -eq "1")
                    $hostOk = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))
                    if (-not ($hdrOk -and $hostOk -and $origOk)) {
                        $raStatus = 403
                        $raBody   = '{"ok":false,"error":"Accesso negato"}'
                    } elseif ($request.ContentLength64 -gt 2048) {
                        $raStatus = 413
                        $raBody   = '{"ok":false,"error":"Richiesta troppo grande"}'
                    } else {
                        $rdr = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $raw = $rdr.ReadToEnd(); $rdr.Close()
                        $o = $raw | ConvertFrom-Json
                        $raName = ([string]$o.name).Trim()
                        $raUrls = @(([string]$o.url).Trim() -split '\s+' | Where-Object { $_ })
                        $raErr  = ''
                        if ($raName -notmatch '^[\p{L}\p{N}][\p{L}\p{N} .&+_()\-]{0,39}$') {
                            $raErr = 'Nome non valido (max 40 caratteri: lettere, numeri, spazio e . & + _ ( ) -)'
                        } elseif ($raUrls.Count -lt 1 -or $raUrls.Count -gt 5) {
                            $raErr = 'Indica da 1 a 5 indirizzi, separati da uno spazio'
                        } else {
                            foreach ($raU in $raUrls) {
                                if ($raU.Length -gt 300 -or $raU -notmatch '^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%\[\]\-]+$') {
                                    $raErr = 'Indirizzo non valido (deve iniziare con http:// o https://, senza apici ne caratteri speciali)'
                                    break
                                }
                            }
                        }
                        if ($raErr) {
                            $raBody = (@{ ok = $false; error = $raErr } | ConvertTo-Json -Compress)
                        } else {
                            $raTarget = if ($script:CurrentScriptPath) { $script:CurrentScriptPath } else { Join-Path $UbDir "UnboundBunkerDashboard.ps1" }
                            $raText = [System.IO.File]::ReadAllText($raTarget, [System.Text.Encoding]::UTF8)
                            $mB = '// RADIO_LIST_' + 'BEGIN'
                            $mE = '// RADIO_LIST_' + 'END'
                            $iB = $raText.IndexOf($mB, [System.StringComparison]::Ordinal)
                            $iE = if ($iB -ge 0) { $raText.IndexOf($mE, $iB, [System.StringComparison]::Ordinal) } else { -1 }
                            if ($iB -lt 0 -or $iE -lt 0) {
                                $raBody = '{"ok":false,"error":"Elenco radio non trovato nello script"}'
                            } else {
                                $raBlock = $raText.Substring($iB, $iE - $iB)
                                $raNames = @([regex]::Matches($raBlock, "name:\s*'([^']*)'") | ForEach-Object { $_.Groups[1].Value })
                                if ($raNames.Count -ge 30) {
                                    $raBody = '{"ok":false,"error":"Elenco pieno (massimo 30 radio)"}'
                                } elseif (@($raNames | Where-Object { $_ -ieq $raName }).Count -gt 0) {
                                    $raBody = '{"ok":false,"error":"Esiste gia una radio con questo nome"}'
                                } else {
                                    $raLineStart = $raText.LastIndexOf([char]10, $iE) + 1
                                    $raNl = if ($raText.Contains("`r`n")) { "`r`n" } else { "`n" }
                                    $raUrlJs = (($raUrls | ForEach-Object { "'" + $_ + "'" }) -join ', ')
                                    $raLine = "    { name: '" + $raName + "', urls: [" + $raUrlJs + "] }," + $raNl
                                    $raNew = $raText.Insert($raLineStart, $raLine)
                                    Copy-Item -LiteralPath $raTarget -Destination ($raTarget + ".bak") -Force
                                    $raTmp = $raTarget + ".radio.tmp"
                                    [System.IO.File]::WriteAllText($raTmp, $raNew, (New-Object System.Text.UTF8Encoding($true)))
                                    Move-Item -LiteralPath $raTmp -Destination $raTarget -Force
                                    Write-DashLog "Radio aggiunta all'elenco dello script: $raName"
                                    $raStatus = 200
                                    $raBody   = if (Update-RadioShellMemory $raNew) { '{"ok":true}' } else { '{"ok":true,"restart":true}' }
                                }
                            }
                        }
                    }
                } catch {
                    Write-DashLog "Errore in /api/radio-add: $($_.Exception.Message)"
                    $raStatus = 500
                    $raBody   = '{"ok":false,"error":"Impossibile scrivere nello script (vedi il log della dashboard)"}'
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($raBody)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $raStatus
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/api/radio-remove" -and $request.HttpMethod -eq "POST") {
                # Rimuove una radio dall'elenco scritto dentro questo stesso script: viene cancellata la sola riga della radio
                # tra i due marcatori RADIO_LIST (parte BEGIN e parte END). Stesse difese di /api/radio-add (header custom,
                # controllo Host/Origin). La radio e' identificata da posizione + nome: se non coincidono (elenco modificato
                # nel frattempo) non si cancella nulla. L'ultima radio rimasta non si puo' rimuovere. Il riavvio lo chiede la pagina.
                $rrStatus = 400
                $rrBody   = '{"ok":false,"error":"Richiesta non valida"}'
                try {
                    $hdrOk  = ([string]$request.Headers["X-Bunker-Radio"] -eq "1")
                    $hostOk = (@("127.0.0.1:$Port", "localhost:$Port") -contains [string]$request.UserHostName)
                    $origHdr = [string]$request.Headers["Origin"]
                    $origOk = ([string]::IsNullOrEmpty($origHdr) -or (@("http://127.0.0.1:$Port", "http://localhost:$Port") -contains $origHdr))
                    if (-not ($hdrOk -and $hostOk -and $origOk)) {
                        $rrStatus = 403
                        $rrBody   = '{"ok":false,"error":"Accesso negato"}'
                    } elseif ($request.ContentLength64 -gt 2048) {
                        $rrStatus = 413
                        $rrBody   = '{"ok":false,"error":"Richiesta troppo grande"}'
                    } else {
                        $rdr = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $raw = $rdr.ReadToEnd(); $rdr.Close()
                        $o = $raw | ConvertFrom-Json
                        $rrName = [string]$o.name
                        $rrIdx  = -1
                        if (-not [int]::TryParse([string]$o.index, [ref]$rrIdx)) { $rrIdx = -1 }
                        $rrTarget = if ($script:CurrentScriptPath) { $script:CurrentScriptPath } else { Join-Path $UbDir "UnboundBunkerDashboard.ps1" }
                        $rrText = [System.IO.File]::ReadAllText($rrTarget, [System.Text.Encoding]::UTF8)
                        $mB = '// RADIO_LIST_' + 'BEGIN'
                        $mE = '// RADIO_LIST_' + 'END'
                        $iB = $rrText.IndexOf($mB, [System.StringComparison]::Ordinal)
                        $iE = if ($iB -ge 0) { $rrText.IndexOf($mE, $iB, [System.StringComparison]::Ordinal) } else { -1 }
                        if ($iB -lt 0 -or $iE -lt 0) {
                            $rrBody = '{"ok":false,"error":"Elenco radio non trovato nello script"}'
                        } else {
                            $rrBlock = $rrText.Substring($iB, $iE - $iB)
                            $rrRows  = @([regex]::Matches($rrBlock, "(?m)^[ \t]*\{\s*name:\s*'([^'\r\n]*)'[^\r\n]*(?:\r?\n|$)"))
                            if ($rrRows.Count -le 1) {
                                $rrBody = '{"ok":false,"error":"Non si puo'' rimuovere l''ultima radio dell''elenco"}'
                            } elseif ($rrIdx -lt 0 -or $rrIdx -ge $rrRows.Count -or $rrRows[$rrIdx].Groups[1].Value -cne $rrName) {
                                $rrBody = '{"ok":false,"error":"La radio non corrisponde piu'' all''elenco nello script: ricarica la pagina e riprova"}'
                            } else {
                                $rrM = $rrRows[$rrIdx]
                                $rrNew = $rrText.Remove($iB + $rrM.Index, $rrM.Length)
                                Copy-Item -LiteralPath $rrTarget -Destination ($rrTarget + ".bak") -Force
                                $rrTmp = $rrTarget + ".radio.tmp"
                                [System.IO.File]::WriteAllText($rrTmp, $rrNew, (New-Object System.Text.UTF8Encoding($true)))
                                Move-Item -LiteralPath $rrTmp -Destination $rrTarget -Force
                                Write-DashLog "Radio rimossa dall'elenco dello script: $rrName"
                                $rrStatus = 200
                                $rrBody   = if (Update-RadioShellMemory $rrNew) { '{"ok":true}' } else { '{"ok":true,"restart":true}' }
                            }
                        }
                    }
                } catch {
                    Write-DashLog "Errore in /api/radio-remove: $($_.Exception.Message)"
                    $rrStatus = 500
                    $rrBody   = '{"ok":false,"error":"Impossibile scrivere nello script (vedi il log della dashboard)"}'
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($rrBody)
                $response.ContentType = "application/json; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.StatusCode = $rrStatus
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
                if (Test-WantsShell $request) {
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlShell)
                } else {
                    Set-ProActive
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPage)
                }
                $response.ContentType = "text/html; charset=utf-8"
                $response.Headers.Add("Cache-Control", "no-store")
                $response.ContentLength64 = $buffer.Length
                Write-HttpResponseSafe $response $buffer
            } elseif ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html") {
                if (Test-WantsShell $request) {
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlShell)
                } else {
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($HtmlPageLight)
                }
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
