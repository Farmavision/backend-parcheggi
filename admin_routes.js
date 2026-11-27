const fs = require('fs');
const path = require('path');

const LOCAL_ZONES_FILE = path.join(__dirname, 'service_zones.json');

const PARAM_DEFAULTS = {
  initial_credits: 50,
  search_fee: 5,
  release_reward: 4,
  cancellation_penalty: 2,
  release_delta_minutes: 5,
  reservation_hold_minutes: 10,
  free_spot_ttl_minutes: 15,
  polling_interval_seconds: 5,
  search_radius_meters: 500,
  arrival_verification_meters: 25,
  self_booking_block_enabled: 0,
  geofence_enabled: 0,
  geofence_radius_m: 100,
  delta_gps_m: 150,
  t_grazia_min: 5,
  t_countdown_sec: 30,
  t_stallo_libero_sec: 60,
  t_stallo_forselibero_sec: 120,
  n_passi: 50,
  t0_passi_sec: 30,
};

function haversineKm(lat1, lon1, lat2, lon2) {
  const toRad = (v) => (v * Math.PI) / 180;
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

module.exports = function registerAdminRoutes(app, { useSupabase, supabase, db, getSystemSettings }) {
  const getAdminPin = () => String(process.env.ADMIN_PIN || '2026').trim();

  async function loadZones() {
    if (useSupabase) {
      try {
        const { data } = await supabase
          .from('users')
          .select('car_model')
          .eq('external_user_id', '__SYSTEM_ADMIN_ZONES__')
          .maybeSingle();
        if (data && data.car_model) {
          const parsed = JSON.parse(data.car_model);
          if (Array.isArray(parsed)) return parsed;
        }
      } catch (_) {}
    }
    try {
      if (fs.existsSync(LOCAL_ZONES_FILE)) {
        const parsed = JSON.parse(fs.readFileSync(LOCAL_ZONES_FILE, 'utf8'));
        if (Array.isArray(parsed)) return parsed;
      }
    } catch (_) {}
    return [];
  }

  async function saveZones(zones) {
    const clean = (Array.isArray(zones) ? zones : [])
      .map((z, idx) => ({
        id: String(z.id || `zone_${Date.now()}_${idx}`),
        name: String(z.name || `Zona ${idx + 1}`).trim(),
        lat: Number(z.lat),
        lon: Number(z.lon),
        radius_km: Math.max(0.1, Number(z.radius_km || 1.5)),
        active: Boolean(z.active),
      }))
      .filter((z) => Number.isFinite(z.lat) && Number.isFinite(z.lon));

    try {
      fs.writeFileSync(LOCAL_ZONES_FILE, JSON.stringify(clean, null, 2), 'utf8');
    } catch (_) {}

    if (useSupabase) {
      await supabase.from('users').upsert(
        {
          external_user_id: '__SYSTEM_ADMIN_ZONES__',
          car_brand: 'SYSTEM_CONFIG',
          car_model: JSON.stringify(clean),
        },
        { onConflict: 'external_user_id' }
      );
    }
    return clean;
  }

  async function getFullConfig() {
    const raw = await getSystemSettings();
    const params = { ...PARAM_DEFAULTS, ...raw };
    if (raw.fee_search !== undefined && raw.search_fee === undefined) params.search_fee = Number(raw.fee_search);
    if (raw.reward_release !== undefined && raw.release_reward === undefined) params.release_reward = Number(raw.reward_release);
    const zones = await loadZones();
    return { params, zones };
  }

  async function isPointAllowed(lat, lon) {
    const cfg = await getFullConfig();
    if (Number(cfg.params.geofence_enabled) !== 1) return { allowed: true, zones: cfg.zones };
    const activeZones = cfg.zones.filter((z) => z.active);
    if (activeZones.length === 0) return { allowed: false, zones: [] };
    const inside = activeZones.some((z) => haversineKm(lat, lon, z.lat, z.lon) <= z.radius_km);
    return { allowed: inside, zones: activeZones };
  }

  app.locals.adminConfig = { getFullConfig, isPointAllowed };

  function requirePin(req, res, next) {
    const pin = String(req.headers['x-admin-pin'] || req.body?.pin || '').trim();
    if (!pin || pin !== getAdminPin()) {
      return res.status(401).json({ error: 'PIN Amministratore non valido' });
    }
    next();
  }

  // Controllo geografico automatico sulle rotte operative parcheggio
  app.use('/api/parking', async (req, res, next) => {
    try {
      const src = { ...(req.query || {}), ...(req.body || {}) };
      const lat = Number(src.lat ?? src.latitude);
      const lon = Number(src.lon ?? src.longitude);
      if (Number.isFinite(lat) && Number.isFinite(lon)) {
        const check = await isPointAllowed(lat, lon);
        if (!check.allowed) {
          return res.status(403).json({
            error: 'ParkNow! non è ancora attivo in questa zona geografica.',
            code: 'OUT_OF_SERVICE_ZONE',
            activeZones: check.zones.map((z) => ({ name: z.name, lat: z.lat, lon: z.lon, radius_km: z.radius_km })),
          });
        }
      }
      next();
    } catch (_) {
      next();
    }
  });

  app.get('/api/config/public', async (req, res) => {
    try {
      const cfg = await getFullConfig();
      res.json({
        geofence_enabled: Number(cfg.params.geofence_enabled) === 1,
        search_fee: Number(cfg.params.search_fee),
        release_reward: Number(cfg.params.release_reward),
        release_delta_minutes: Number(cfg.params.release_delta_minutes),
        search_radius_meters: Number(cfg.params.search_radius_meters),
        polling_interval_seconds: Number(cfg.params.polling_interval_seconds),
        geofence_radius_m: Number(cfg.params.geofence_radius_m || 100),
        delta_gps_m: Number(cfg.params.delta_gps_m || 150),
        activeZones: cfg.zones.filter((z) => z.active),
      });
    } catch (_) {
      res.status(500).json({ error: 'Errore lettura configurazione pubblica' });
    }
  });

  app.post('/api/admin/verify-pin', (req, res) => {
    const pin = String(req.body?.pin || '').trim();
    if (pin && pin === getAdminPin()) return res.json({ valid: true });
    return res.status(401).json({ valid: false, error: 'PIN errato' });
  });

  app.get('/api/admin/config', async (req, res) => {
    try {
      res.json(await getFullConfig());
    } catch (err) {
      res.status(500).json({ error: 'Errore lettura parametri amministratore' });
    }
  });

  app.post('/api/admin/config', requirePin, async (req, res) => {
    try {
      const { params, zones } = req.body || {};
      if (params && typeof params === 'object') {
        const merged = { ...params };
        if (merged.search_fee !== undefined) merged.fee_search = Number(merged.search_fee);
        if (merged.release_reward !== undefined) merged.reward_release = Number(merged.release_reward);
        for (const [k, v] of Object.entries(merged)) {
          const num = Number(v);
          if (!Number.isFinite(num)) continue;
          if (useSupabase) {
            await supabase
              .from('system_settings')
              .upsert({ setting_key: k, setting_value: num }, { onConflict: 'setting_key' });
          } else if (db) {
            try {
              db.prepare(
                'INSERT INTO system_settings (setting_key, setting_value) VALUES (?, ?) ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value'
              ).run(k, num);
            } catch (_) {}
          }
        }
      }
      if (Array.isArray(zones)) {
        await saveZones(zones);
      }
      res.json({ success: true, ...(await getFullConfig()) });
    } catch (err) {
      console.error('Errore POST /api/admin/config:', err);
      res.status(500).json({ error: 'Errore salvataggio configurazione amministratore' });
    }
  });

  app.get('/admin', (req, res) => {
    res.type('html').send(`<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ParkNow! Hub Admin</title>
<style>
body{font-family:system-ui,sans-serif;max-width:1040px;margin:20px auto;padding:0 16px;background:#f4f6f8;color:#1b2430}
.card{background:#fff;border-radius:12px;padding:18px;margin-bottom:16px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
h1,h2,h3{margin-top:0;color:#1b5e20}h3{font-size:15px;margin-bottom:8px}
label{display:block;font-size:13px;font-weight:600;margin:8px 0 4px}
input[type=text],input[type=number],input[type=password],select{width:100%;padding:9px;border:1px solid #ccd3db;border-radius:8px;box-sizing:border-box}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:12px}
.kpi{background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;padding:12px;text-align:center}
.kpi b{display:block;font-size:24px;margin-bottom:2px}
.bar{display:flex;height:12px;border-radius:8px;overflow:hidden;background:#e2e8f0;margin-bottom:14px}
.tabs{display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap}
.tab{background:#e2e8f0;color:#1e293b;border:0;padding:10px 16px;border-radius:8px;font-weight:700;cursor:pointer}
.tab.active{background:#1b5e20;color:#fff}
button{background:#1b5e20;color:#fff;border:0;padding:10px 15px;border-radius:8px;font-weight:700;cursor:pointer}
button.sec{background:#1565c0}button.warn{background:#ef6c00}button.del{background:#c62828;padding:6px 10px;font-size:12px}
button.sm{padding:6px 10px;font-size:12px}
.zone{border:1px solid #e0e6ed;padding:10px;border-radius:8px;margin-top:8px;display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap}
table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px}
th,td{border-bottom:1px solid #e2e8f0;padding:8px 6px;text-align:left;vertical-align:top}
th{background:#f8fafc;font-weight:700}
.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:700;color:#fff}
.b-occ{background:#455a64}.b-leav{background:#ef6c00}.b-free{background:#2e7d32}.b-susp{background:#c62828}.b-beta{background:#1565c0}
.pos{color:#2e7d32;font-weight:700}.neg{color:#c62828;font-weight:700}
.mono{font-family:ui-monospace,monospace;font-size:12px;color:#475569;word-break:break-word}
@media(max-width:640px){.kpis{grid-template-columns:repeat(2,1fr)}}
</style></head><body>
<h1>ParkNow! — Hub Amministratore Web</h1>
<div class="card" id="loginCard">
  <label>PIN Amministratore</label>
  <input id="pinInput" type="password" placeholder="Inserisci PIN (default: 2026)" onkeydown="if(event.key==='Enter')unlock()">
  <br><br><button onclick="unlock()">Accedi</button>
</div>

<div id="panel" style="display:none">
  <div class="tabs">
    <button class="tab active" id="btn_tab_users" onclick="showTab('users')">Log Utenti &amp; Crediti</button>
    <button class="tab" id="btn_tab_spots" onclick="showTab('spots')">Stalli Real-Time</button>
    <button class="tab" id="btn_tab_params" onclick="showTab('params')">Parametri &amp; Zone</button>
  </div>

  <!-- TAB 1: LOG UTENTI -->
  <div id="tab_users">
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
        <h2 style="margin:0">Utenti Registrati</h2>
        <div style="display:flex;gap:8px;flex:1;max-width:420px">
          <input id="userSearch" type="text" placeholder="Cerca per ID, email, telefono, targa..." onkeydown="if(event.key==='Enter')loadUsers()">
          <button class="sec" onclick="loadUsers()">Cerca</button>
        </div>
      </div>
      <div id="usersTableWrap" style="overflow-x:auto;margin-top:10px">Caricamento...</div>
    </div>

    <div class="card" id="userDetailCard" style="display:none">
      <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px">
        <h2 style="margin:0" id="udTitle">Dettaglio Utente</h2>
        <div style="display:flex;gap:8px">
          <button class="sec sm" onclick="loadUserDetail(ACTIVE_UID)">Aggiorna</button>
          <button class="del sm" onclick="document.getElementById('userDetailCard').style.display='none'">Chiudi</button>
        </div>
      </div>
      <div id="udSummary" style="margin:10px 0"></div>

      <div class="grid" style="margin-top:12px">
        <div style="border:1px solid #e2e8f0;border-radius:10px;padding:12px">
          <h3>Modifica Profilo &amp; Stato</h3>
          <label>Email</label><input id="udEmail" type="text">
          <label>Telefono</label><input id="udPhone" type="text">
          <label><input type="checkbox" id="udBeta"> Beta Tester</label>
          <label><input type="checkbox" id="udSusp"> Account Sospeso</label>
          <br><button class="sec" onclick="saveUserProfile()">Salva Utente</button>
        </div>
        <div style="border:1px solid #e2e8f0;border-radius:10px;padding:12px">
          <h3>Rettifica Crediti</h3>
          <label>Importo (+/-)</label><input id="adjDelta" type="number" placeholder="Es. 20 oppure -10">
          <label>Causale</label>
          <select id="adjReason">
            <option value="ADMIN_ADJUSTMENT">ADMIN_ADJUSTMENT</option>
            <option value="BETA_BONUS">BETA_BONUS</option>
            <option value="REFUND">REFUND</option>
            <option value="PENALTY_CORRECTION">PENALTY_CORRECTION</option>
          </select>
          <label>Nota obbligatoria (min 3 car.)</label><input id="adjNote" type="text" placeholder="Motivazione rettifica">
          <br><br><button onclick="adjustUserCredits()">Applica Rettifica</button>
        </div>
      </div>

      <div style="margin-top:18px">
        <h3>Storico Ledger Crediti (<span id="ledgerCount">0</span>)</h3>
        <div id="udLedgerWrap" style="overflow-x:auto"></div>
      </div>

      <div style="margin-top:18px">
        <h3>Log Eventi &amp; Audit (<span id="auditCount">0</span>)</h3>
        <div id="udAuditWrap" style="overflow-x:auto"></div>
      </div>
    </div>
  </div>

  <!-- TAB 2: STALLI REAL-TIME -->
  <div id="tab_spots" style="display:none">
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;margin-bottom:12px">
        <h2 style="margin:0">Stalli Real-Time</h2>
        <button class="sec sm" onclick="loadSpots()">Aggiorna ora</button>
      </div>
      <div class="kpis">
        <div class="kpi"><b id="kTotal">0</b>Totale</div>
        <div class="kpi"><b id="kOcc" style="color:#455a64">0</b>Occupati</div>
        <div class="kpi"><b id="kLeav" style="color:#ef6c00">0</b>In Rilascio</div>
        <div class="kpi"><b id="kFree" style="color:#2e7d32">0</b>Liberi</div>
      </div>
      <div class="bar" id="spotsBar"></div>
      <div id="spotsTableWrap" style="overflow-x:auto">Caricamento...</div>
    </div>
  </div>

  <!-- TAB 3: PARAMETRI & ZONE -->
  <div id="tab_params" style="display:none">
    <div class="card"><h2>Limitazione Zone Geografiche</h2><label><input type="checkbox" id="geofence_enabled"> Attiva funzionamento SOLO nelle zone abilitate</label>
    <div id="zonesList"></div><hr><div class="grid"><div><label>Nome Zona</label><input id="zName" type="text" placeholder="Es. Roma - Tuscolano"></div><div><label>Raggio (km)</label><input id="zRad" type="number" step="0.1" value="1.5"></div><div><label>Latitudine</label><input id="zLat" type="number" step="0.00001"></div><div><label>Longitudine</label><input id="zLon" type="number" step="0.00001"></div></div><br><button class="sec" onclick="addZone()">+ Aggiungi Zona</button></div>
    <div class="card"><h2>Parametri Operativi &amp; Algoritmo</h2><div class="grid" id="paramsGrid"></div></div>
    <button onclick="saveAll()" style="width:100%;font-size:16px">Salva Tutte le Impostazioni</button>
  </div>
</div>

<script>
let PIN='', CFG={params:{},zones:[]}, ACTIVE_UID='';
const LABELS={initial_credits:'Crediti iniziali',search_fee:'Costo prenotazione (crediti)',release_reward:'Premio rilascio (crediti)',cancellation_penalty:'Penale annullamento',release_delta_minutes:'Preavviso uscita (min)',reservation_hold_minutes:'Max attesa prenotazione (min)',free_spot_ttl_minutes:'Durata stallo libero (min)',polling_interval_seconds:'Polling stato (sec)',search_radius_meters:'Raggio ricerca (m)',arrival_verification_meters:'Tolleranza GPS arrivo (m)',self_booking_block_enabled:'Blocco auto-prenotazione (1=Sì, 0=No)',geofence_radius_m:'Rgeofence — Raggio Geofence auto (m)',delta_gps_m:'DeltaGps — Margine GPS alta precisione (m)',t_grazia_min:'Tgrazia — Tempo di grazia riarmo geofence (min)',t_countdown_sec:'Tcountdown — Countdown ripartenza In Auto (s)',t_stallo_libero_sec:'Tstallo_libero — Durata P verde lampeggiante (s)',t_stallo_forselibero_sec:'Tstallo_forselibero — Durata icona rossa ? (s)',n_passi:'Npassi — Soglia passi uscita Casa/Lavoro senza Wi-Fi',t0_passi_sec:'T0passi — Reset contatore passi Casa/Lavoro (sec)'};

function esc(v){return String(v??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function fmtDate(iso){if(!iso)return '-';try{return new Date(iso).toLocaleString('it-IT');}catch(_){return String(iso);}}
function statusBadge(st){const s=String(st||'').toUpperCase();if(s==='OCCUPIED')return '<span class="badge b-occ">OCCUPATO</span>';if(s==='LEAVING_SOON')return '<span class="badge b-leav">IN RILASCIO</span>';if(s==='FREE')return '<span class="badge b-free">LIBERO</span>';return '<span class="badge b-occ">'+esc(s)+'</span>';}

function showTab(name){
  ['users','spots','params'].forEach(t=>{
    document.getElementById('tab_'+t).style.display=(t===name)?'block':'none';
    document.getElementById('btn_tab_'+t).classList.toggle('active',t===name);
  });
  if(name==='users')loadUsers();
  if(name==='spots')loadSpots();
  if(name==='params')loadConfig();
}

async function unlock(){
  PIN=document.getElementById('pinInput').value.trim();
  const r=await fetch('/api/admin/verify-pin',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pin:PIN})});
  if(!r.ok)return alert('PIN errato');
  document.getElementById('loginCard').style.display='none';
  document.getElementById('panel').style.display='block';
  loadConfig();
  loadUsers();
}

async function loadConfig(){
  const r=await fetch('/api/admin/config');
  CFG=await r.json();
  document.getElementById('geofence_enabled').checked=Number(CFG.params.geofence_enabled)===1;
  const g=document.getElementById('paramsGrid');g.innerHTML='';
  for(const[k,lbl]of Object.entries(LABELS)){
    g.innerHTML+='<div><label>'+lbl+'</label><input type="number" id="p_'+k+'" value="'+(CFG.params[k]??0)+'"></div>';
  }
  renderZones();
}
function renderZones(){
  const el=document.getElementById('zonesList');el.innerHTML='';
  CFG.zones.forEach((z,i)=>{
    el.innerHTML+='<div class="zone"><div><input type="checkbox" '+(z.active?'checked':'')+' onchange="CFG.zones['+i+'].active=this.checked"> <b>'+esc(z.name)+'</b> ('+z.lat+', '+z.lon+' · '+z.radius_km+' km)</div><button class="del" onclick="CFG.zones.splice('+i+',1);renderZones()">Elimina</button></div>';
  });
}
function addZone(){
  const name=document.getElementById('zName').value.trim(),lat=parseFloat(document.getElementById('zLat').value),lon=parseFloat(document.getElementById('zLon').value),radius_km=parseFloat(document.getElementById('zRad').value)||1.5;
  if(!name||!isFinite(lat)||!isFinite(lon))return alert('Compila nome e coordinate');
  CFG.zones.push({id:'z_'+Date.now(),name,lat,lon,radius_km,active:true});renderZones();
}
async function saveAll(){
  CFG.params.geofence_enabled=document.getElementById('geofence_enabled').checked?1:0;
  for(const k of Object.keys(LABELS)){CFG.params[k]=Number(document.getElementById('p_'+k).value);}
  const r=await fetch('/api/admin/config',{method:'POST',headers:{'Content-Type':'application/json','x-admin-pin':PIN},body:JSON.stringify(CFG)});
  if(r.ok)alert('Configurazione salvata!');else alert('Errore salvataggio');
}

async function loadSpots(){
  const wrap=document.getElementById('spotsTableWrap');
  wrap.innerHTML='Caricamento stalli...';
  const r=await fetch('/api/admin/spots-summary',{headers:{'x-admin-pin':PIN}});
  if(!r.ok){wrap.innerHTML='Errore caricamento stalli';return;}
  const d=await r.json();
  const c=d.counts||{total:0,occupied:0,leavingSoon:0,free:0};
  document.getElementById('kTotal').textContent=c.total;
  document.getElementById('kOcc').textContent=c.occupied;
  document.getElementById('kLeav').textContent=c.leavingSoon;
  document.getElementById('kFree').textContent=c.free;
  const tot=c.total||1;
  document.getElementById('spotsBar').innerHTML=
    '<div style="width:'+(c.occupied*100/tot)+'%;background:#455a64"></div>'+
    '<div style="width:'+(c.leavingSoon*100/tot)+'%;background:#ef6c00"></div>'+
    '<div style="width:'+(c.free*100/tot)+'%;background:#2e7d32"></div>';
  const list=d.spots||[];
  if(!list.length){wrap.innerHTML='<p>Nessuno stallo presente nel database.</p>';return;}
  let html='<table><thead><tr><th>Utente</th><th>Stato</th><th>Coordinate</th><th>ETA</th><th>Aggiornato</th><th>Azioni</th></tr></thead><tbody>';
  for(const s of list){
    const sid=esc(s.id);
    html+='<tr><td><b>'+esc(s.user_id)+'</b><div class="mono">'+sid+'</div></td>'+
      '<td>'+statusBadge(s.status)+'</td>'+
      '<td class="mono">'+Number(s.latitude||0).toFixed(5)+', '+Number(s.longitude||0).toFixed(5)+'</td>'+
      '<td>'+(s.available_in_minutes??0)+' min</td>'+
      '<td>'+fmtDate(s.updated_at)+'</td>'+
      '<td style="white-space:nowrap"><button class="warn sm" onclick="forceSpot(\\''+sid+'\\',false)">Libera</button> <button class="del sm" onclick="forceSpot(\\''+sid+'\\',true)">Elimina</button></td></tr>';
  }
  html+='</tbody></table>';
  wrap.innerHTML=html;
}

async function forceSpot(spotId, removeSpot){
  if(!confirm(removeSpot?'Eliminare definitivamente questo stallo?':'Forzare questo stallo in stato LIBERO?'))return;
  const r=await fetch('/api/admin/spots/force-release',{method:'POST',headers:{'Content-Type':'application/json','x-admin-pin':PIN},body:JSON.stringify({spotId,removeSpot})});
  if(r.ok)loadSpots();else alert('Errore operazione stallo');
}

async function loadUsers(){
  const wrap=document.getElementById('usersTableWrap');
  const q=encodeURIComponent(document.getElementById('userSearch').value.trim());
  wrap.innerHTML='Caricamento utenti...';
  const r=await fetch('/api/admin/users?q='+q,{headers:{'x-admin-pin':PIN}});
  if(!r.ok){wrap.innerHTML='Errore caricamento utenti';return;}
  const d=await r.json();
  const list=d.users||[];
  if(!list.length){wrap.innerHTML='<p>Nessun utente trovato.</p>';return;}
  let html='<table><thead><tr><th>Utente</th><th>Email / Tel</th><th>Crediti</th><th>Auto</th><th>Stallo Attivo</th><th>Azioni</th></tr></thead><tbody>';
  for(const u of list){
    const uid=esc(u.external_user_id);
    const flags=(u.is_beta_tester?' <span class="badge b-beta">BETA</span>':'')+(u.is_suspended?' <span class="badge b-susp">SOSPESO</span>':'');
    const car=[u.car_brand,u.car_model,u.car_plate_visible?('**'+u.car_plate_visible):''].filter(Boolean).join(' ');
    html+='<tr><td><b>'+uid+'</b>'+flags+'</td>'+
      '<td>'+esc(u.email||'-')+'<div class="mono">'+esc(u.phone_number||'')+'</div></td>'+
      '<td><b>'+u.credits_balance+' cr</b></td>'+
      '<td>'+esc(car||'-')+'</td>'+
      '<td>'+(u.active_spot?statusBadge(u.active_spot.status):'-')+'</td>'+
      '<td><button class="sec sm" onclick="loadUserDetail(\\''+uid+'\\')">Apri Log</button></td></tr>';
  }
  html+='</tbody></table>';
  wrap.innerHTML=html;
}

async function loadUserDetail(uid){
  ACTIVE_UID=uid;
  const card=document.getElementById('userDetailCard');
  card.style.display='block';
  document.getElementById('udTitle').textContent='Log & Dettaglio: '+uid;
  document.getElementById('udLedgerWrap').innerHTML='Caricamento...';
  document.getElementById('udAuditWrap').innerHTML='Caricamento...';
  const r=await fetch('/api/admin/users/'+encodeURIComponent(uid)+'/detail',{headers:{'x-admin-pin':PIN}});
  if(!r.ok){document.getElementById('udSummary').innerHTML='Errore caricamento dettaglio';return;}
  const d=await r.json();
  const u=d.user||{};
  document.getElementById('udEmail').value=u.email||'';
  document.getElementById('udPhone').value=u.phone_number||'';
  document.getElementById('udBeta').checked=Boolean(u.is_beta_tester);
  document.getElementById('udSusp').checked=Boolean(u.is_suspended);
  document.getElementById('udSummary').innerHTML=
    'Saldo attuale: <b>'+(u.credits_balance??0)+' crediti</b> · Stallo attivo: '+(d.activeSpot?statusBadge(d.activeSpot.status):'Nessuno')+' · Ultimo aggiornamento: '+fmtDate(u.updated_at);

  const ledger=d.ledger||[];
  document.getElementById('ledgerCount').textContent=ledger.length;
  if(!ledger.length){document.getElementById('udLedgerWrap').innerHTML='<p>Nessun movimento crediti.</p>';}
  else{
    let lh='<table><thead><tr><th>Data</th><th>Delta</th><th>Saldo</th><th>Causale</th><th>Nota</th><th>Attore</th></tr></thead><tbody>';
    for(const l of ledger){
      const dl=Number(l.delta||0);
      lh+='<tr><td>'+fmtDate(l.created_at)+'</td><td class="'+(dl>=0?'pos':'neg')+'">'+(dl>=0?'+':'')+dl+'</td><td>'+(l.balance_after??'-')+'</td><td><b>'+esc(l.reason_code)+'</b></td><td>'+esc(l.note||'-')+'</td><td>'+esc(l.actor||'-')+'</td></tr>';
    }
    lh+='</tbody></table>';
    document.getElementById('udLedgerWrap').innerHTML=lh;
  }

  const logs=d.auditLogs||[];
  document.getElementById('auditCount').textContent=logs.length;
  if(!logs.length){document.getElementById('udAuditWrap').innerHTML='<p>Nessun evento registrato.</p>';}
  else{
    let ah='<table><thead><tr><th>Data</th><th>Evento</th><th>Sorgente</th><th>Dettagli</th></tr></thead><tbody>';
    for(const a of logs){
      const meta=a.meta?JSON.stringify(a.meta):'';
      ah+='<tr><td>'+fmtDate(a.created_at)+'</td><td><b>'+esc(a.event_type)+'</b></td><td>'+esc(a.trigger_source||'-')+'</td><td class="mono">'+esc(meta)+'</td></tr>';
    }
    ah+='</tbody></table>';
    document.getElementById('udAuditWrap').innerHTML=ah;
  }
  card.scrollIntoView({behavior:'smooth'});
}

async function saveUserProfile(){
  if(!ACTIVE_UID)return;
  const body={
    email:document.getElementById('udEmail').value.trim(),
    phoneNumber:document.getElementById('udPhone').value.trim(),
    isBetaTester:document.getElementById('udBeta').checked,
    isSuspended:document.getElementById('udSusp').checked
  };
  const r=await fetch('/api/admin/users/'+encodeURIComponent(ACTIVE_UID)+'/update',{method:'POST',headers:{'Content-Type':'application/json','x-admin-pin':PIN},body:JSON.stringify(body)});
  const d=await r.json();
  if(!r.ok)return alert(d.error||'Errore salvataggio utente');
  if(d.schemaWarning)alert(d.schemaWarning);else alert('Utente aggiornato!');
  loadUsers();loadUserDetail(ACTIVE_UID);
}

async function adjustUserCredits(){
  if(!ACTIVE_UID)return;
  const delta=Number(document.getElementById('adjDelta').value);
  const reasonCode=document.getElementById('adjReason').value;
  const note=document.getElementById('adjNote').value.trim();
  const r=await fetch('/api/admin/users/'+encodeURIComponent(ACTIVE_UID)+'/adjust-credits',{method:'POST',headers:{'Content-Type':'application/json','x-admin-pin':PIN},body:JSON.stringify({delta,reasonCode,note})});
  const d=await r.json();
  if(!r.ok)return alert(d.error||'Errore rettifica crediti');
  document.getElementById('adjDelta').value='';
  document.getElementById('adjNote').value='';
  alert('Rettifica applicata! Nuovo saldo: '+d.newBalance+' crediti');
  loadUsers();loadUserDetail(ACTIVE_UID);
}
</script></body></html>`);
  });
};
