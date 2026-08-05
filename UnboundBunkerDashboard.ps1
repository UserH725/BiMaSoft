# ======================================================================================= #
# UNBOUND BUNKER - DASHBOARD LIVE (sola lettura)                                          #
# Script indipendente, non tocca alcun file di configurazione ne' processo esistente.     #
# Espone una pagina HTML su http://127.0.0.1:8954/ con auto-refresh ogni 1 secondi.       #
# Il pannello "Versioni Componenti" fa eccezione per la parte Cloud: i valori Locali sono #
# sempre live, i valori Cloud (letti da GitHub) si aggiornano al massimo ogni 30 minuti,   #
# o subito con un refresh manuale della pagina (F5), per rispettare il rate limit di       #
# api.github.com (60 richieste/ora senza autenticazione).                                 #
# Legge: unbound-control stats_noreset, unbound.log (RPZ), hardware.conf,                 #
#        session_totale.dat, bunker_health.json - tutti in sola lettura.                  #
# ======================================================================================= #

# === CONFIGURAZIONE ===
$UbDir  = "C:\Program Files\Unbound"
$Port   = 8954
$Prefix = "http://127.0.0.1:$Port/"

$UcExe      = Join-Path $UbDir "unbound-control.exe"
$HwConf     = Join-Path $UbDir "hardware.conf"
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

# Cache delle versioni CLOUD (GitHub). I valori locali sono letture da disco/processo,
# economiche, e vengono quindi ricalcolati live ad ogni chiamata. I valori cloud invece
# arrivano da chiamate di rete: raw.githubusercontent.com e' servito da CDN e regge bene,
# ma api.github.com (usato per l'ultima release di Unbound) ha un rate limit molto piu'
# stretto senza autenticazione: 60 richieste/ora. Per restare ampiamente sotto quel limite
# anche con la dashboard aperta di continuo, i valori cloud vengono ricontrollati al
# massimo ogni 30 minuti, oppure subito con -Force (refresh manuale della pagina, F5).
# Se una singola chiamata fallisce (rete assente, rate limit, timeout) si mantiene
# l'ultimo valore noto invece di azzerarlo a N/D, cosi' un guasto transitorio non
# "sporca" la dashboard.
$script:CloudVersionsCache       = $null
$script:CloudVersionsCacheTime   = [DateTime]::MinValue
$script:CloudVersionsCacheTtlSec = 1800

function Get-BunkerVersions {
    param([switch]$Force)

    $result = [ordered]@{
        unbound_local = "N/D"
        unbound_cloud = "N/D"
        conf_local    = "N/D"
        conf_cloud    = "N/D"
        bat_local     = "N/D"
        bat_cloud     = "N/D"
    }

    # --- LOCALE: sempre ricalcolato, e' una lettura da disco/processo, non da rete ---

    # 1. Unbound Engine (locale)
    $ubExe = Join-Path $UbDir "unbound.exe"
    if (Test-Path $ubExe) {
        try {
            $raw = & $ubExe -h 2>&1 | Out-String
            if ($raw -match 'Version\s+([0-9\.]+)') { $result.unbound_local = $matches[1] }
        } catch {}
    }

    # 2. File service.conf (locale)
    $svcVerFile = Join-Path $UbDir "versione_service_conf.txt"
    if (Test-Path $svcVerFile) {
        try { $result.conf_local = (Get-Content -LiteralPath $svcVerFile -Raw).Trim() } catch {}
    }

    # 3. Script BAT Manager (locale)
    $batFile = Join-Path $UbDir "UnboundBunkerManager.BAT"
    if (Test-Path $batFile) {
        try {
            $line = Get-Content -LiteralPath $batFile | Where-Object { $_ -match 'set .LOCAL_VER=([0-9]+\.[0-9]+)' } | Select-Object -First 1
            if ($line -match '([0-9]+\.[0-9]+)') { $result.bat_local = $matches[1] }
        } catch {}
    }

    # --- CLOUD: chiamate di rete, ricontrollate solo se la cache e' scaduta (o -Force) ---
    $cloudStale = $Force -or (-not $script:CloudVersionsCache) -or
        ((Get-Date) - $script:CloudVersionsCacheTime).TotalSeconds -ge $script:CloudVersionsCacheTtlSec

    if ($cloudStale) {
        if (-not $script:CloudVersionsCache) {
            $script:CloudVersionsCache = [ordered]@{ unbound_cloud = "N/D"; conf_cloud = "N/D"; bat_cloud = "N/D" }
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            $json = (Invoke-WebRequest -Uri 'https://api.github.com/repos/NLnetLabs/unbound/releases/latest' -UseBasicParsing -TimeoutSec 4).Content | ConvertFrom-Json
            $v = $json.tag_name
            if ($v -match 'release-(.*)') { $script:CloudVersionsCache.unbound_cloud = $matches[1] }
            elseif ($v) { $script:CloudVersionsCache.unbound_cloud = $v }
        } catch {
            Write-DashLog "Get-BunkerVersions: check cloud Unbound Engine fallito (probabile rate limit api.github.com, 60 richieste/ora senza autenticazione): $($_.Exception.Message)"
        }

        try {
            $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_service.txt' -UseBasicParsing -TimeoutSec 4).Content.Trim()
            if ($v) { $script:CloudVersionsCache.conf_cloud = $v }
        } catch {
            Write-DashLog "Get-BunkerVersions: check cloud service.conf fallito: $($_.Exception.Message)"
        }

        try {
            $v = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/UserH725/BiMaSoft/refs/heads/main/version_bat.txt' -UseBasicParsing -TimeoutSec 4).Content.Trim()
            if ($v) { $script:CloudVersionsCache.bat_cloud = $v }
        } catch {
            Write-DashLog "Get-BunkerVersions: check cloud BAT Manager fallito: $($_.Exception.Message)"
        }

        $script:CloudVersionsCacheTime = Get-Date
    }

    $result.unbound_cloud = $script:CloudVersionsCache.unbound_cloud
    $result.conf_cloud    = $script:CloudVersionsCache.conf_cloud
    $result.bat_cloud     = $script:CloudVersionsCache.bat_cloud

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
    param([switch]$ForceVersions)
    $hw       = Get-HardwareTier
    $versioni = Get-BunkerVersions -Force:$ForceVersions
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
        versioni    = $versioni
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
<title>Unbound Bunker - Dashboard Live - by Mauro Bigoni</title>
<style>
  :root { --bg:#0b0f14; --panel:#121820; --border:#1f2b38; --text:#d7e2ec; --dim:#7f93a6;
          --green:#208b4c; --green-bright:#3ddc84; --red:#c0392b; --red-bright:#ff5c5c;
          --amber:#d35400; --accent:#4fb3ff; }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: "Consolas","Cascadia Mono",monospace;
         margin: 0; padding: 20px; }
  
  .header-container {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 16px;
  }
  .header-left { flex: 1; }
  
  .clock-box {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 8px 16px;
    text-align: right;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
  }
  .clock-time {
    font-size: 2em;
    font-weight: bold;
    color: var(--accent);
    line-height: 1.1;
    letter-spacing: 1px;
  }
  .clock-date {
    font-size: 0.95em;
    color: var(--dim);
    margin-top: 2px;
    text-transform: capitalize;
  }

  /* TITOLO INGRANDITO E ANIMAZIONE ACCENTUATA (SHIMMER + NEON PULSE) */
  h1 { 
    font-size: 2em; 
    font-weight: bold;
    margin: 0 0 6px 0;
    background: linear-gradient(90deg, #d7e2ec 0%, #0099ff 20%, #ffffff 50%, #0099ff 80%, #d7e2ec 100%);
    background-size: 200% auto;
    color: #d7e2ec;
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    animation: intenseShimmer 2.5s ease-in-out infinite;
    display: inline-block;
  }

  @keyframes intenseShimmer {
    0% { 
      background-position: 0% center;
      filter: drop-shadow(0 0 2px rgba(79, 179, 255, 0.2));
    }
    50% { 
      background-position: 100% center;
      filter: drop-shadow(0 0 14px rgba(79, 179, 255, 0.85));
    }
    100% { 
      background-position: 200% center;
      filter: drop-shadow(0 0 2px rgba(79, 179, 255, 0.2));
    }
  }

  .sub { color: var(--dim); font-size: 0.85em; margin-bottom: 18px; }
  
  /* BADGES AD ALTA VISIBILITÀ */
  .badges { display:flex; gap:14px; flex-wrap:wrap; margin-bottom: 22px; }
  .badge { 
    padding: 10px 18px; 
    border-radius: 6px; 
    font-size: 1.15em; 
    font-weight: bold; 
    letter-spacing: 0.5px;
    display: inline-flex;
    align-items: center;
    box-shadow: 0 4px 10px rgba(0,0,0,0.4);
  }
  .ok { 
    background-color: rgba(32, 139, 76, 0.25); 
    color: var(--green-bright); 
    border: 2px solid var(--green-bright); 
    text-shadow: 0 0 8px rgba(61, 220, 132, 0.4);
  }
  .bad { 
    background-color: rgba(192, 57, 43, 0.3); 
    color: #ffffff; 
    border: 2px solid var(--red-bright); 
    text-shadow: 0 0 8px rgba(255, 92, 92, 0.6);
    box-shadow: 0 0 12px rgba(255, 92, 92, 0.3);
  }

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
  .esito-warn { color: var(--red-bright); font-weight: bold; }
  .esito-ok { color: var(--green-bright); }
  .muted { color: var(--dim); }
</style>
</head>
<body>

<div class="header-container">
  <div class="header-left">
    <h1>🛡️ UNBOUND BUNKER - Dashboard Live - by Mauro Bigoni</h1>
    <div class="sub" id="subheader">Connessione in corso...</div>
  </div>
  <div class="clock-box">
    <div class="clock-time" id="clockTime">--:--:--</div>
    <div class="clock-date" id="clockDate">-----------------</div>
  </div>
</div>

<div class="badges" id="badges"></div>

<div class="panel">
  <h2>ℹ️ Versioni Componenti (Locale vs Cloud)</h2>
  <div class="stats-grid" id="statsVersioni"></div>
</div>

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

function updateClock() {
  const now = new Date();
  const optionsTime = { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false };
  const optionsDate = { weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric' };

  document.getElementById('clockTime').textContent = now.toLocaleTimeString('it-IT', optionsTime);
  document.getElementById('clockDate').textContent = now.toLocaleDateString('it-IT', optionsDate);
}

setInterval(updateClock, 1000);
updateClock();

async function refresh(forceVersions) {
  try {
    const url = forceVersions ? '/api/status?force=1' : '/api/status';
    const res = await fetch(url, { cache: 'no-store' });
    const d = await res.json();

    document.getElementById('subheader').textContent =
      'Host: ' + d.host + ' | Profilo RAM: ' + (d.hardware.profilo || 'N/D') +
      (d.hardware.ram_gb ? ' (' + d.hardware.ram_gb + ' GB)' : '') +
      ' | Aggiornato: ' + d.generato_il;

    const badges = document.getElementById('badges');
    badges.innerHTML = '';
    const bEngine = document.createElement('span');
    bEngine.className = 'badge ' + (d.engine_attivo ? 'ok' : 'bad');
    bEngine.textContent = d.engine_attivo ? '🟢 SERVIZIO UNBOUND ATTIVO' : '🔴 SERVIZIO UNBOUND FERMO';
    badges.appendChild(bEngine);
    
    const bSalute = document.createElement('span');
    bSalute.className = 'badge ' + (d.salute_sistema.anomalie_rilevate ? 'bad' : 'ok');
    bSalute.textContent = d.salute_sistema.anomalie_rilevate ? '⚠️ ANOMALIE RILEVATE' : '✅ NESSUNA ANOMALIA';
    badges.appendChild(bSalute);

    const v = d.versioni || {};
    const verDiv = document.getElementById('statsVersioni');
    if (verDiv) {
      verDiv.innerHTML = `
        <div class="stat">
          <div class="lbl">Engine Unbound</div>
          <div class="val" style="font-size:1.1em;">${v.unbound_local || 'N/D'}</div>
          <div class="muted">Cloud: ${v.unbound_cloud || 'N/D'}</div>
        </div>
        <div class="stat">
          <div class="lbl">Script BAT</div>
          <div class="val" style="font-size:1.1em;">v${v.bat_local || 'N/D'}</div>
          <div class="muted">Cloud: v${v.bat_cloud || 'N/D'}</div>
        </div>
        <div class="stat">
          <div class="lbl">File CONF</div>
          <div class="val" style="font-size:1.1em;">v${v.conf_local || 'N/D'}</div>
          <div class="muted">Cloud: v${v.conf_cloud || 'N/D'}</div>
        </div>
      `;
    }

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

refresh(true);   // caricamento pagina / refresh manuale (F5): forza il ricontrollo versioni
setInterval(refresh, 1000);   // polling normale: le versioni arrivano dalla cache server (si rinnova da sola ogni 10s)
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
