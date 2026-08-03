# ======================================================================================= #
# UNBOUND BUNKER - DASHBOARD LIVE (sola lettura)                                          #
# Script indipendente, non tocca alcun file di configurazione ne' processo esistente.     #
# Espone una pagina HTML su http://127.0.0.1:8954/ con auto-refresh ogni 1 secondi.       #
# Legge: unbound-control stats_noreset, unbound.log (RPZ), hardware.conf,                 #
#        session_totale.dat, bunker_health.json - tutti in sola lettura.                  #
# ======================================================================================= #

# === CONFIGURAZIONE ===
$UbDir  = "C:\Program Files\Unbound"
$Port   = 8954
$Prefix = "http://127.0.0.1:$Port/"

$UcExe      = Join-Path $UbDir "unbound-control.exe"
$HwConf     = Join-Path $UbDir "hardware.conf"
$RpzLog     = Join-Path $UbDir "unbound.log"
$SessionDat = Join-Path $UbDir "session_totale.dat"
$HealthJson = Join-Path $UbDir "bunker_health.json"
$LogFile    = Join-Path $UbDir "dashboard_error.log"

function Write-DashLog {
    param($msg)
    try { "[$((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))] $msg" | Out-File -LiteralPath $LogFile -Append -Encoding utf8 } catch {}
}

trap {
    Write-DashLog "ERRORE NON GESTITO: $($_.Exception.Message) | Riga: $($_.InvocationInfo.ScriptLineNumber)"
    continue
}

$RpzListe = @(
    @{ Tag = "hagezi-pro-plus";   Nome = "HaGeZi Pro Plus";        Emoji = "🥇" }
    @{ Tag = "hagezi-tif";        Nome = "HaGeZi TIF";             Emoji = "🥈" }
    @{ Tag = "hagezi-tif-ips";    Nome = "HaGeZi TIF-IPS";         Emoji = "🥉" }
    @{ Tag = "spamhaus-drop-v4";  Nome = "Spamhaus DROP v4";       Emoji = "🛡️" }
    @{ Tag = "spamhaus-drop-v6";  Nome = "Spamhaus DROP v6";       Emoji = "🛡️" }
    @{ Tag = "hagezi-dyndns";     Nome = "HaGeZi DynDNS";          Emoji = "🌐" }
    @{ Tag = "hagezi-hoster";     Nome = "HaGeZi Badware Hoster";  Emoji = "📦" }
    @{ Tag = "hagezi-spamtlds";   Nome = "HaGeZi Most Abused TLDs";Emoji = "🚫" }
)

# === FUNZIONI DI RACCOLTA DATI (tutte in sola lettura) ===

function Get-HardwareTier {
    $result = [ordered]@{ ram_gb = $null; profilo = "N/D" }
    if (Test-Path $HwConf) {
        try {
            $line = Get-Content -LiteralPath $HwConf | Where-Object { $_ -match "Rilevati:\s*(\d+)\s*GB RAM.*Profilo:\s*(\S+)" } | Select-Object -First 1
            if ($line -match "Rilevati:\s*(\d+)\s*GB RAM.*Profilo:\s*(\S+)") {
                $result.ram_gb = [int]$matches[1]
                $result.profilo = $matches[2]
            }
        } catch {}
    }
    return $result
}

function Get-EngineStatus {
    $svc = Get-Service -Name "unbound" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { return $true }
    return $false
}

function Get-LiveStats {
    $base = [ordered]@{
        query_totali        = 0
        cache_hits          = 0
        cache_efficienza_pct = 0
        uptime_secondi      = 0
    }
    $estese = [ordered]@{}

    if (Test-Path $UcExe) {
        try {
            $raw = & $UcExe stats_noreset 2>$null
            foreach ($ln in $raw) {
                if ($ln -match "^([a-zA-Z0-9_.\-]+)=(.+)$") {
                    $k = $matches[1]
                    $v = $matches[2].Trim()
                    $estese[$k] = $v
                    if ($k -eq "total.num.queries")   { $base.query_totali   = [double]$v }
                    if ($k -eq "total.num.cachehits")  { $base.cache_hits     = [double]$v }
                    if ($k -eq "time.up")              { $base.uptime_secondi = [double]$v }
                }
            }
            if ($base.query_totali -gt 0) {
                $base.cache_efficienza_pct = [math]::Round(($base.cache_hits / $base.query_totali) * 100, 1)
            }
        } catch {}
    }
    return @{ base = $base; estese = $estese }
}

function Get-RpzBreakdown {
    $liste = @()
    $blkTotale = 0
    $rpzLines = $null
    if (Test-Path $RpzLog) {
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
        $liste += @{
            tag       = $lista.Tag
            nome      = $lista.Nome
            emoji     = $lista.Emoji
            conteggio = $conteggioLista
            domini    = $domini
        }
        $blkTotale += $conteggioLista
    }
    return @{ totale = $blkTotale; liste = $liste }
}

function Get-SessionTotal {
    if (Test-Path $SessionDat) {
        try {
            $obj = Get-Content -LiteralPath $SessionDat -Raw | ConvertFrom-Json
            return $obj
        } catch { return $null }
    }
    return $null
}

function Get-HealthSnapshot {
    if (Test-Path $HealthJson) {
        try {
            $obj = Get-Content -LiteralPath $HealthJson -Raw | ConvertFrom-Json
            return $obj
        } catch { return $null }
    }
    return $null
}

function Get-BunkerStatusJson {
    $hw       = Get-HardwareTier
    $engineOn = Get-EngineStatus
    $stats    = Get-LiveStats
    $rpz      = Get-RpzBreakdown
    $sessione = Get-SessionTotal
    $salute   = Get-HealthSnapshot

    $pctBlocchi = 0
    if ($stats.base.query_totali -gt 0) {
        $pctBlocchi = [math]::Round(($rpz.totale / $stats.base.query_totali) * 100, 1)
    }

    $anomalie = $false
    if ($salute -and $salute.fasi) {
        foreach ($f in $salute.fasi) {
            if ($f.esito -match "WARN|ERR|ERRORE|ALLARME|FALLITO") { $anomalie = $true; break }
        }
    }

    $obj = [ordered]@{
        generato_il = (Get-Date).ToString("dd.MM.yyyy HH:mm:ss")
        host        = $env:COMPUTERNAME
        hardware    = $hw
        engine_attivo = $engineOn
        dall_ultimo_report = [ordered]@{
            query_totali         = $stats.base.query_totali
            cache_hits           = $stats.base.cache_hits
            cache_efficienza_pct = $stats.base.cache_efficienza_pct
            uptime_secondi       = $stats.base.uptime_secondi
            blocchi_totali       = $rpz.totale
            blocchi_pct          = $pctBlocchi
            liste                = $rpz.liste
            statistiche_estese   = $stats.estese
        }
        totale_sessione = $sessione
        salute_sistema  = [ordered]@{
            anomalie_rilevate = $anomalie
            dettaglio         = $salute
        }
    }
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

# === PAGINA HTML (statica, con polling JS ogni 5s su /api/status) ===

$HtmlPage = @'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Unbound Bunker - Dashboard Live</title>
<style>
  :root { --bg:#0b0f14; --panel:#121820; --border:#1f2b38; --text:#d7e2ec; --dim:#7f93a6;
          --green:#3ddc84; --red:#ff5c5c; --amber:#ffb454; --accent:#4fb3ff; }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: "Consolas","Cascadia Mono",monospace;
         margin: 0; padding: 20px; }
  h1 { font-size: 1.3em; margin: 0 0 4px 0; }
  .sub { color: var(--dim); font-size: 0.85em; margin-bottom: 18px; }
  .badges { display:flex; gap:10px; flex-wrap:wrap; margin-bottom: 18px; }
  .badge { padding: 4px 10px; border-radius: 4px; font-size: 0.8em; border:1px solid var(--border); }
  .ok { color: var(--green); border-color: var(--green); }
  .bad { color: var(--red); border-color: var(--red); }
  .panel { background: var(--panel); border:1px solid var(--border); border-radius:8px;
           padding:16px; margin-bottom:18px; }
  .panel h2 { margin:0 0 12px 0; font-size:1.05em; color: var(--accent); border-bottom:1px solid var(--border); padding-bottom:8px; }
  .stats-grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(160px,1fr)); gap:12px; margin-bottom:14px; }
  .stat { background:#0e141b; border:1px solid var(--border); border-radius:6px; padding:10px; }
  .stat .val { font-size:1.4em; font-weight:bold; }
  .stat .lbl { color: var(--dim); font-size:0.75em; }
  table { width:100%; border-collapse: collapse; font-size:0.85em; }
  th, td { text-align:left; padding:4px 8px; border-bottom:1px solid var(--border); }
  th { color: var(--dim); font-weight:normal; }
  details { margin-top:6px; }
  summary { cursor:pointer; color: var(--accent); }
  .esito-warn { color: var(--red); }
  .esito-ok { color: var(--green); }
  .muted { color: var(--dim); }
</style>
</head>
<body>
<h1>🛡️ UNBOUND BUNKER - Dashboard Live</h1>
<div class="sub" id="subheader">Connessione in corso...</div>
<div class="badges" id="badges"></div>

<div class="panel">
  <h2>📊 Dall'ultimo report Telegram</h2>
  <div class="stats-grid" id="statsUltimoReport"></div>
  <div id="listeRpz"></div>
</div>

<div class="panel">
  <h2>♾️ Totale sessione (dall'ultimo avvio)</h2>
  <div class="stats-grid" id="statsSessione"></div>
</div>

<div class="panel">
  <h2>⚕️ Stato di salute del sistema</h2>
  <table id="tabellaSalute"><thead><tr><th>Fase</th><th>Azione</th><th>Esito</th></tr></thead><tbody></tbody></table>
</div>

<script>
function fmt(n) {
  if (n === undefined || n === null) return "-";
  return Number(n).toLocaleString('it-IT');
}

async function refresh() {
  try {
    const res = await fetch('/api/status', { cache: 'no-store' });
    const d = await res.json();

    document.getElementById('subheader').textContent =
      'Host: ' + d.host + ' | Profilo RAM: ' + (d.hardware.profilo || 'N/D') +
      (d.hardware.ram_gb ? ' (' + d.hardware.ram_gb + ' GB)' : '') +
      ' | Aggiornato: ' + d.generato_il;

    const badges = document.getElementById('badges');
    badges.innerHTML = '';
    const bEngine = document.createElement('span');
    bEngine.className = 'badge ' + (d.engine_attivo ? 'ok' : 'bad');
    bEngine.textContent = d.engine_attivo ? '🟢 Servizio Unbound attivo' : '🔴 Servizio Unbound FERMO';
    badges.appendChild(bEngine);
    const bSalute = document.createElement('span');
    bSalute.className = 'badge ' + (d.salute_sistema.anomalie_rilevate ? 'bad' : 'ok');
    bSalute.textContent = d.salute_sistema.anomalie_rilevate ? '⚠️ Anomalie rilevate' : '✅ Nessuna anomalia';
    badges.appendChild(bSalute);

    const r = d.dall_ultimo_report;
    const statsDiv = document.getElementById('statsUltimoReport');
    statsDiv.innerHTML = `
      <div class="stat"><div class="val">${fmt(r.query_totali)}</div><div class="lbl">Query totali</div></div>
      <div class="stat"><div class="val">${fmt(r.cache_efficienza_pct)}%</div><div class="lbl">Efficienza cache</div></div>
      <div class="stat"><div class="val">${fmt(r.blocchi_totali)}</div><div class="lbl">Blocchi totali (${fmt(r.blocchi_pct)}%)</div></div>
    `;

    const listeDiv = document.getElementById('listeRpz');
    listeDiv.innerHTML = '';
    (r.liste || []).forEach(l => {
      const det = document.createElement('details');
      det.open = true;
      const sum = document.createElement('summary');
      sum.textContent = `${l.emoji} ${l.nome}: ${fmt(l.conteggio)} blocchi`;
      det.appendChild(sum);
      if (l.domini && l.domini.length) {
        const tbl = document.createElement('table');
        tbl.innerHTML = '<thead><tr><th>Dominio</th><th>Conteggio</th></tr></thead>';
        const tbody = document.createElement('tbody');
        l.domini.forEach(dm => {
          const tr = document.createElement('tr');
          tr.innerHTML = `<td>${dm.dominio}${dm.wildcard ? ' <span class="muted">(wildcard)</span>' : ''}</td><td>${fmt(dm.conteggio)}</td>`;
          tbody.appendChild(tr);
        });
        tbl.appendChild(tbody);
        det.appendChild(tbl);
      } else {
        const p = document.createElement('div');
        p.className = 'muted';
        p.textContent = 'Nessun blocco in questa finestra';
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
        <div class="stat"><div class="val muted" style="font-size:0.9em">${s.dal || '-'}</div><div class="lbl">Dal</div></div>
      `;
    } else {
      sessDiv.innerHTML = '<div class="muted">Nessun dato di sessione ancora disponibile</div>';
    }

    const tbody = document.querySelector('#tabellaSalute tbody');
    tbody.innerHTML = '';
    const fasi = (d.salute_sistema.dettaglio && d.salute_sistema.dettaglio.fasi) || [];
    if (fasi.length === 0) {
      tbody.innerHTML = '<tr><td colspan="3" class="muted">Nessun dato di salute ancora disponibile</td></tr>';
    } else {
      fasi.forEach(f => {
        const isWarn = /WARN|ERR|ERRORE|ALLARME|FALLITO/.test(f.esito || '');
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${f.fase}</td><td>${f.azione || ''}</td><td class="${isWarn ? 'esito-warn' : 'esito-ok'}">${f.esito || ''}</td>`;
        tbody.appendChild(tr);
      });
    }
  } catch (e) {
    document.getElementById('subheader').textContent = 'Errore di connessione alla dashboard: ' + e;
  }
}

refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>
'@

# === SERVER HTTP LOCALE (loopback only) ===

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
        Write-DashLog "Listener avviato con successo su $Prefix"
        break
    } catch {
        Write-DashLog "Tentativo fallito su $tryPrefix : $($_.Exception.Message)"
        $listener.Prefixes.Clear()
    }
}

if (-not $startedOk) {
    Write-DashLog "ERRORE: impossibile avviare il listener su nessun prefisso tentato ($($triedPrefixes -join ', '))."
    Write-Host "[ERRORE] Impossibile avviare il listener. Dettagli in: $LogFile"
    Write-Host "Prova ad eseguire come amministratore, oppure verifica che la porta $Port non sia gia' occupata."
    Write-Host "In alternativa: netsh http add urlacl url=$Prefix user=$env:USERNAME"
    exit 1
}

Write-Host "[OK] Unbound Bunker Dashboard in ascolto su $Prefix (Ctrl+C per fermare)"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        try {
            if ($request.Url.AbsolutePath -eq "/api/status") {
                $json = Get-BunkerStatusJson
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
