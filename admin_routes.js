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
    res.type('html').send(`<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ParkNow! Admin</title>
<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:24px auto;padding:0 16px;background:#f4f6f8;color:#1b2430}
.card{background:#fff;border-radius:12px;padding:18px;margin-bottom:16px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
h1,h2{margin-top:0;color:#1b5e20}label{display:block;font-size:13px;font-weight:600;margin:10px 0 4px}
input[type=text],input[type=number],input[type=password]{width:100%;padding:9px;border:1px solid #ccd3db;border-radius:8px;box-sizing:border-box}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}button{background:#1b5e20;color:#fff;border:0;padding:11px 16px;border-radius:8px;font-weight:700;cursor:pointer}
button.sec{background:#1565c0}button.del{background:#c62828;padding:6px 10px}.zone{border:1px solid #e0e6ed;padding:10px;border-radius:8px;margin-top:8px;display:flex;justify-content:space-between;align-items:center}
</style></head><body><h1>ParkNow! — Pannello Amministratore</h1>
<div class="card" id="loginCard"><label>PIN Amministratore</label><input id="pinInput" type="password" placeholder="Inserisci PIN (default: 2026)"><br><br><button onclick="unlock()">Accedi</button></div>
<div id="panel" style="display:none">
<div class="card"><h2>Limitazione Zone Geografiche</h2><label><input type="checkbox" id="geofence_enabled"> Attiva funzionamento SOLO nelle zone abilitate</label>
<div id="zonesList"></div><hr><div class="grid"><div><label>Nome Zona</label><input id="zName" type="text" placeholder="Es. Roma - Tuscolano"></div><div><label>Raggio (km)</label><input id="zRad" type="number" step="0.1" value="1.5"></div><div><label>Latitudine</label><input id="zLat" type="number" step="0.00001"></div><div><label>Longitudine</label><input id="zLon" type="number" step="0.00001"></div></div><br><button class="sec" onclick="addZone()">+ Aggiungi Zona</button></div>
<div class="card"><h2>Parametri Operativi</h2><div class="grid" id="paramsGrid"></div></div>
<button onclick="saveAll()" style="width:100%;font-size:16px">Salva Tutte le Impostazioni</button></div>
<script>
let PIN='', CFG={params:{},zones:[]};
const LABELS={initial_credits:'Crediti iniziali',search_fee:'Costo prenotazione (crediti)',release_reward:'Premio rilascio (crediti)',cancellation_penalty:'Penale annullamento',release_delta_minutes:'Preavviso uscita (min)',reservation_hold_minutes:'Max attesa prenotazione (min)',free_spot_ttl_minutes:'Durata stallo libero (min)',polling_interval_seconds:'Polling stato (sec)',search_radius_meters:'Raggio ricerca (m)',arrival_verification_meters:'Tolleranza GPS arrivo (m)',self_booking_block_enabled:'Blocco auto-prenotazione (1=Sì, 0=No)',geofence_radius_m:'Rgeofence — Raggio Geofence auto (m)',delta_gps_m:'DeltaGps — Margine GPS alta precisione (m)',t_grazia_min:'Tgrazia — Tempo di grazia riarmo geofence (min)',t_countdown_sec:'Tcountdown — Countdown ripartenza In Auto (s)',t_stallo_libero_sec:'Tstallo_libero — Durata P verde lampeggiante (s)',t_stallo_forselibero_sec:'Tstallo_forselibero — Durata icona rossa ? (s)',n_passi:'Npassi — Soglia passi uscita Casa/Lavoro senza Wi-Fi',t0_passi_sec:'T0passi — Reset contatore passi Casa/Lavoro (sec)'};
async function unlock(){PIN=document.getElementById('pinInput').value;const r=await fetch('/api/admin/verify-pin',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pin:PIN})});if(!r.ok)return alert('PIN errato');document.getElementById('loginCard').style.display='none';document.getElementById('panel').style.display='block';load();}
async function load(){const r=await fetch('/api/admin/config');CFG=await r.json();document.getElementById('geofence_enabled').checked=Number(CFG.params.geofence_enabled)===1;const g=document.getElementById('paramsGrid');g.innerHTML='';for(const[k,lbl]of Object.entries(LABELS)){g.innerHTML+='<div><label>'+lbl+'</label><input type="number" id="p_'+k+'" value="'+(CFG.params[k]??0)+'"></div>';}renderZones();}
function renderZones(){const el=document.getElementById('zonesList');el.innerHTML='';CFG.zones.forEach((z,i)=>{el.innerHTML+='<div class="zone"><div><input type="checkbox" '+(z.active?'checked':'')+' onchange="CFG.zones['+i+'].active=this.checked"> <b>'+z.name+'</b> ('+z.lat+', '+z.lon+' · '+z.radius_km+' km)</div><button class="del" onclick="CFG.zones.splice('+i+',1);renderZones()">Elimina</button></div>';});}
function addZone(){const name=document.getElementById('zName').value.trim(),lat=parseFloat(document.getElementById('zLat').value),lon=parseFloat(document.getElementById('zLon').value),radius_km=parseFloat(document.getElementById('zRad').value)||1.5;if(!name||!isFinite(lat)||!isFinite(lon))return alert('Compila nome e coordinate');CFG.zones.push({id:'z_'+Date.now(),name,lat,lon,radius_km,active:true});renderZones();}
async function saveAll(){CFG.params.geofence_enabled=document.getElementById('geofence_enabled').checked?1:0;for(const k of Object.keys(LABELS)){CFG.params[k]=Number(document.getElementById('p_'+k).value);}const r=await fetch('/api/admin/config',{method:'POST',headers:{'Content-Type':'application/json','x-admin-pin':PIN},body:JSON.stringify(CFG)});if(r.ok)alert('Configurazione salvata!');else alert('Errore salvataggio');}
</script></body></html>`);
  });
};
