require('dotenv').config();
const express = require('express');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;
app.use(cors());
app.use(express.json());

const useSupabase = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_KEY);
let supabase = null;
let db = null;

if (useSupabase) {
  const { createClient } = require('@supabase/supabase-js');
  supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_KEY);
} else {
  const Database = require('better-sqlite3');
  db = new Database(path.join(__dirname, 'parkadvisor.db'));
  db.exec(`CREATE TABLE IF NOT EXISTS parking_spots (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
    status TEXT NOT NULL DEFAULT 'OCCUPIED', available_in_minutes INTEGER DEFAULT 0,
    detection_method TEXT, confirmed_at TEXT, verification_deadline TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);
}

function getDistanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371e3;
  const p1 = lat1 * Math.PI / 180, p2 = lat2 * Math.PI / 180;
  const dp = (lat2 - lat1) * Math.PI / 180, dl = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function getSystemSettings() {
  const defaults = { reward_release: 10, fee_search: 5, penalty_false_release: 15, release_delta_minutes: 5 };
  if (!useSupabase) return defaults;
  const { data } = await supabase.from('system_settings').select('setting_key, setting_value');
  if (data) data.forEach(r => { defaults[r.setting_key] = Number(r.setting_value); });
  return defaults;
}

async function ensureAndAdjustUserCredits(externalUserId, deltaAmount, transactionType, spotId = null) {
  if (!useSupabase || !externalUserId) return null;
  let { data: user } = await supabase.from('users').select('*').eq('external_user_id', externalUserId).maybeSingle();
  if (!user) {
    const { data: created } = await supabase.from('users')
      .insert({ external_user_id: externalUserId, credits_balance: 50, auto_share_enabled: true, search_radius_m: 500 })
      .select().single();
    user = created;
  }
  if (!user) return null;
  const newBalance = (user.credits_balance || 0) + deltaAmount;
  await supabase.from('users').update({ credits_balance: newBalance, updated_at: new Date().toISOString() }).eq('id', user.id);
  if (deltaAmount !== 0) {
    await supabase.from('credit_transactions').insert({ user_id: user.id, amount: deltaAmount, transaction_type: transactionType, spot_id: spotId });
  }
  return newBalance;
}

async function processExpiredReleaseVerifications() {
  if (!useSupabase) return;
  const nowIso = new Date().toISOString();
  const { data: expired } = await supabase.from('parking_spots').select('*')
    .eq('status', 'LEAVING_SOON').not('verification_deadline', 'is', null).lt('verification_deadline', nowIso);
  if (!expired || expired.length === 0) return;

  const settings = await getSystemSettings();
  const penalty = Math.abs(settings.penalty_false_release || 15);
  for (const spot of expired) {
    await supabase.from('parking_spots').update({
      status: 'OCCUPIED', available_in_minutes: 0, confirmed_at: null, verification_deadline: null, updated_at: nowIso
    }).eq('id', spot.id);
    await ensureAndAdjustUserCredits(spot.user_id, -penalty, 'PENALTY_FALSE_RELEASE', spot.id);
  }
}
setInterval(() => processExpiredReleaseVerifications().catch(() => {}), 30000);

app.get('/', async (req, res) => {
  await processExpiredReleaseVerifications();
  res.json({ status: 'ok', service: 'ParkNow! API', storage: useSupabase ? 'supabase' : 'sqlite' });
});

app.get('/api/parking/nearby', async (req, res) => {
  try {
    await processExpiredReleaseVerifications();
    const { lat, lon, radius = 500 } = req.query;
    let rows = [];
    if (useSupabase) {
      const fifteenMinAgo = new Date(Date.now() - 15 * 60 * 1000).toISOString();
      await supabase.from('parking_spots').delete().eq('status', 'FREE').lt('updated_at', fifteenMinAgo);
      const { data, error } = await supabase.from('parking_spots').select('*').in('status', ['LEAVING_SOON', 'FREE']);
      if (error) throw error;
      rows = data || [];
    } else {
      rows = db.prepare("SELECT * FROM parking_spots WHERE status IN ('LEAVING_SOON', 'FREE')").all();
    }
    const formatted = rows.map(r => ({
      id: r.id, userId: r.user_id, latitude: r.latitude, longitude: r.longitude,
      status: r.status, availableInMinutes: r.status === 'LEAVING_SOON' && r.updated_at ? Math.max(1, (r.available_in_minutes || 1) - Math.floor((Date.now() - new Date(r.updated_at).getTime()) / 60000)) : r.available_in_minutes, updatedAt: r.updated_at,
      distanceMeters: (lat && lon) ? Math.round(getDistanceMeters(parseFloat(lat), parseFloat(lon), r.latitude, r.longitude)) : null
    }));
    const result = (lat && lon)
      ? formatted.filter(s => s.distanceMeters <= parseFloat(radius)).sort((a, b) => a.distanceMeters - b.distanceMeters)
      : formatted;
    res.json({ count: result.length, appliedRadius: Number(radius), spots: result });
  } catch (err) {
    res.status(500).json({ error: 'Errore interno del database' });
  }
});

app.post('/api/parking/park', async (req, res) => {
  try {
    const { userId, latitude, longitude, detectionMethod = 'SENSOR_FUSION' } = req.body;
    if (!userId || latitude == null || longitude == null) return res.status(400).json({ error: 'Parametri mancanti' });
    const spotId = `SPOT-${userId}-${Date.now()}`;
    const nowIso = new Date().toISOString();
    if (useSupabase) {
      await supabase.from('parking_spots').delete().eq('user_id', userId);
      const { error } = await supabase.from('parking_spots').insert({
        id: spotId, user_id: userId, latitude, longitude, status: 'OCCUPIED',
        available_in_minutes: 0, detection_method: detectionMethod, created_at: nowIso, updated_at: nowIso
      });
      if (error) throw error;
    }
    res.status(201).json({ success: true, spotId, status: 'OCCUPIED' });
  } catch (err) {
    res.status(500).json({ error: 'Errore registrazione parcheggio' });
  }
});

app.post('/api/parking/confirm-release', async (req, res) => {
  try {
    const { userId, availableInMinutes = 2 } = req.body;
    if (!userId) return res.status(400).json({ error: 'userId richiesto' });
    const settings = await getSystemSettings();
    const deltaMinutes = settings.release_delta_minutes || 5;
    const now = new Date();
    const deadline = new Date(now.getTime() + deltaMinutes * 60 * 1000).toISOString();
    if (useSupabase) {
      const { data, error } = await supabase.from('parking_spots').update({
        status: 'LEAVING_SOON', available_in_minutes: availableInMinutes,
        confirmed_at: now.toISOString(), verification_deadline: deadline, updated_at: now.toISOString()
      }).eq('user_id', userId).select();
      if (error) throw error;
      if (!data || data.length === 0) return res.status(404).json({ error: 'Nessuna auto parcheggiata' });
    }
    res.json({ success: true, status: 'LEAVING_SOON', deltaMinutes, verificationDeadline: deadline });
  } catch (err) {
    res.status(500).json({ error: 'Errore conferma rilascio' });
  }
});

app.post('/api/parking/leaving', async (req, res) => {
  try {
    const { userId, availableInMinutes = 2 } = req.body;
    if (useSupabase && userId) {
      await supabase.from('parking_spots').update({
        status: 'LEAVING_SOON', available_in_minutes: availableInMinutes, updated_at: new Date().toISOString()
      }).eq('user_id', userId);
    }
    res.json({ success: true, status: 'LEAVING_SOON', availableInMinutes });
  } catch (err) {
    res.status(500).json({ error: 'Errore leaving' });
  }
});

app.post('/api/parking/release', async (req, res) => {
  try {
    await processExpiredReleaseVerifications();
    const { userId } = req.body;
    if (!userId) return res.status(400).json({ error: 'userId richiesto' });
    const settings = await getSystemSettings();
    const reward = Math.abs(settings.reward_release || 10);
    let spotId = null;
    if (useSupabase) {
      const { data, error } = await supabase.from('parking_spots').update({
        status: 'FREE', available_in_minutes: 0, confirmed_at: null, verification_deadline: null, updated_at: new Date().toISOString()
      }).eq('user_id', userId).select();
      if (error) throw error;
      if (!data || data.length === 0) return res.status(404).json({ error: 'Nessuno stallo da liberare' });
      spotId = data[0].id;
    }
    const newBalance = await ensureAndAdjustUserCredits(userId, reward, 'RELEASE_REWARD', spotId);
    res.json({ success: true, status: 'FREE', creditsAwarded: reward, newBalance });
  } catch (err) {
    res.status(500).json({ error: 'Errore rilascio stallo' });
  }
});

app.get('/api/user/profile', async (req, res) => {
  try {
    await processExpiredReleaseVerifications();
    const { userId } = req.query;
    if (!userId) return res.status(400).json({ error: 'userId richiesto' });
    if (!useSupabase) return res.json({ external_user_id: userId, credits_balance: 50, auto_share_enabled: true, search_radius_m: 500 });
    let { data: user } = await supabase.from('users').select('*').eq('external_user_id', userId).maybeSingle();
    if (!user) {
      const { data: created } = await supabase.from('users')
        .insert({ external_user_id: userId, credits_balance: 50, auto_share_enabled: true, search_radius_m: 500 }).select().single();
      user = created;
    }
    res.json(user);
  } catch (err) {
    res.status(500).json({ error: 'Errore profilo' });
  }
});

app.post('/api/user/profile', async (req, res) => {
  try {
    const { userId, phoneNumber, carBrand, carModel, carColor, carPlate, autoShareEnabled = true, searchRadiusM = 500, homeWifiSsid, carBluetoothMac } = req.body;
    if (!userId) return res.status(400).json({ error: 'userId richiesto' });
    const cleanPlate = (carPlate || '').trim().toUpperCase();
    const visiblePart = cleanPlate.length >= 2 ? cleanPlate.slice(-2) : cleanPlate;
    const encryptedPart = cleanPlate ? Buffer.from(cleanPlate).toString('base64') : null;
    if (!useSupabase) return res.json({ success: true });
    const { data, error } = await supabase.from('users').upsert({
      external_user_id: userId,
      phone_number: phoneNumber && phoneNumber.trim() !== '' ? phoneNumber.trim() : null,
      car_brand: carBrand || null, car_model: carModel || null, car_color: carColor || null,
      car_plate_encrypted: encryptedPart, car_plate_visible: visiblePart || null,
      auto_share_enabled: Boolean(autoShareEnabled),
      search_radius_m: [100, 300, 500, 1000].includes(Number(searchRadiusM)) ? Number(searchRadiusM) : 500,
      home_wifi_ssid: homeWifiSsid || null, car_bluetooth_mac: carBluetoothMac || null,
      updated_at: new Date().toISOString()
    }, { onConflict: 'external_user_id' }).select().single();
    if (error) throw error;
    res.json({ success: true, profile: data });
  } catch (err) {
    res.status(500).json({ error: 'Errore salvataggio profilo' });
  }
});

app.get('/api/admin/settings', async (req, res) => res.json(await getSystemSettings()));
app.post('/api/admin/settings', async (req, res) => {
  try {
    if (useSupabase) {
      for (const [k, v] of Object.entries(req.body)) {
        await supabase.from('system_settings').upsert({ setting_key: k, setting_value: Number(v) }, { onConflict: 'setting_key' });
      }
    }
    res.json({ success: true, settings: await getSystemSettings() });
  } catch (err) {
    res.status(500).json({ error: 'Errore impostazioni admin' });
  }
});

app.listen(PORT, '0.0.0.0', () => console.log(`Server ParkNow! attivo sulla porta ${PORT}`));
