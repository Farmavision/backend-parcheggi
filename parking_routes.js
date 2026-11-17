const https = require('https');

function fetchBuffer(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers, timeout: 6000 }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(fetchBuffer(res.headers.location, headers));
      }
      if (res.statusCode !== 200) return reject(new Error('HTTP ' + res.statusCode));
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        resolve({ buffer: Buffer.concat(chunks), type: res.headers['content-type'] || 'image/jpeg' });
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
  });
}

async function reverseGeocode(lat, lon) {
  try {
    const url = `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat}&lon=${lon}&accept-language=it`;
    const { buffer } = await fetchBuffer(url, { 'User-Agent': 'ParkNowApp/1.0' });
    const data = JSON.parse(buffer.toString('utf8'));
    if (data && data.address) {
      const road = data.address.road || data.address.pedestrian || data.address.square || '';
      const num = data.address.house_number ? `, ${data.address.house_number}` : '';
      const city = data.address.city || data.address.town || data.address.village || '';
      const shortAddr = [road + num, city].filter(Boolean).join(' - ');
      if (shortAddr) return shortAddr;
    }
    if (data && data.display_name) return data.display_name.split(',').slice(0, 3).join(',').trim();
  } catch (_) {}
  return `${Number(lat).toFixed(5)}, ${Number(lon).toFixed(5)}`;
}

function computeWait(spot) {
  if (!spot || spot.status === 'FREE') return { isFreeNow: true, rem: 0 };
  const baseMin = Number(spot.available_in_minutes || 0);
  let rem = baseMin;
  if (spot.confirmed_at && baseMin > 0) {
    const elapsed = Math.floor((Date.now() - new Date(spot.confirmed_at).getTime()) / 60000);
    rem = Math.max(0, baseMin - elapsed);
  }
  return { isFreeNow: rem <= 0, rem: Math.max(0, rem) };
}

module.exports = function registerParkingRoutes(app, { useSupabase, supabase, db, getSystemSettings }) {
  async function findUser(uid) {
    if (!uid) return null;
    if (useSupabase) {
      for (const col of ['external_user_id', 'id', 'user_id']) {
        const r = await supabase.from('users').select('*').eq(col, uid).maybeSingle();
        if (r.data) return { row: r.data, keyCol: col };
      }
      return null;
    }
    try {
      const row = db.prepare('SELECT * FROM users WHERE external_user_id = ? OR id = ?').get(uid, uid);
      return row ? { row, keyCol: 'id' } : null;
    } catch (_) { return null; }
  }

  app.post('/api/parking/reserve', async (req, res) => {
    try {
      const { userId, spotId } = req.body || {};
      if (!userId || !spotId) return res.status(400).json({ error: 'Dati mancanti' });

      const spot = useSupabase
        ? (await supabase.from('parking_spots').select('*').eq('id', spotId).maybeSingle()).data
        : db.prepare('SELECT * FROM parking_spots WHERE id = ?').get(spotId);

      if (!spot) return res.status(404).json({ error: 'Stallo non trovato' });
      if (spot.status !== 'FREE' && spot.status !== 'LEAVING_SOON') {
        return res.status(409).json({ error: 'Stallo non più disponibile' });
      }

      const settings = await getSystemSettings();
      const fee = Number(settings.fee_search ?? settings.search_fee ?? 5);
      const foundUser = await findUser(userId);
      const user = foundUser ? foundUser.row : null;
      const curBal = user ? Number(user.credits_balance ?? user.credits ?? 50) : 50;
      if (curBal < fee) return res.status(400).json({ error: 'Crediti insufficienti' });
      const newBalance = curBal - fee;

      if (useSupabase) {
        if (user) {
          const balCol = 'credits_balance' in user ? 'credits_balance' : 'credits';
          const kCol = foundUser.keyCol;
          await supabase.from('users').update({ [balCol]: newBalance }).eq(kCol, user[kCol]);
        }
        await supabase.from('parking_spots')
          .update({ status: 'RESERVED', updated_at: new Date().toISOString() })
          .eq('id', spotId);
      } else {
        db.prepare("UPDATE parking_spots SET status = 'RESERVED', updated_at = CURRENT_TIMESTAMP WHERE id = ?")
          .run(spotId);
      }

      const foundOwner = await findUser(spot.user_id);
      const owner = foundOwner ? foundOwner.row : null;
      const visRaw = String(owner?.car_plate_visible || owner?.license_plate || owner?.plate || '')
        .replace(/\*/g, '')
        .replace(/\s+/g, '');
      const { isFreeNow, rem } = computeWait(spot);
      const address = await reverseGeocode(spot.latitude, spot.longitude);

      res.json({
        success: true,
        newBalance,
        spot: {
          id: spot.id,
          latitude: Number(spot.latitude),
          longitude: Number(spot.longitude),
          isFreeNow,
          availableInMinutes: rem,
          address,
          ownerCar: {
            brand: String(owner?.car_brand || owner?.brand || ''),
            model: String(owner?.car_model || owner?.model || ''),
            color: String(owner?.car_color || owner?.color || ''),
            plateVisible: visRaw.length >= 2 ? visRaw.slice(-2) : visRaw,
          },
        },
      });
    } catch (err) {
      console.error('Errore /api/parking/reserve:', err);
      res.status(500).json({ error: 'Errore interno prenotazione' });
    }
  });

  app.get('/api/parking/spot/:spotId', async (req, res) => {
    try {
      const { spotId } = req.params;
      const spot = useSupabase
        ? (await supabase.from('parking_spots').select('*').eq('id', spotId).maybeSingle()).data
        : db.prepare('SELECT * FROM parking_spots WHERE id = ?').get(spotId);
      if (!spot) return res.json({ isFreeNow: false, isCancelled: true, availableInMinutes: 0 });
      const { isFreeNow, rem } = computeWait(spot);
      res.json({ isFreeNow, isCancelled: spot.status === 'CANCELLED', availableInMinutes: rem });
    } catch (_) {
      res.status(500).json({ error: 'Errore stato stallo' });
    }
  });

  app.get('/api/parking/streetview', async (req, res) => {
    const lat = Number(req.query.lat);
    const lon = Number(req.query.lon);
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) return res.status(400).end();

    const key = process.env.GOOGLE_MAPS_API_KEY;
    if (key) {
      try {
        const gUrl = `https://maps.googleapis.com/maps/api/streetview?size=640x360&location=${lat},${lon}&fov=90&pitch=0&source=outdoor&key=${key}`;
        const { buffer, type } = await fetchBuffer(gUrl);
        res.set('Content-Type', type);
        return res.send(buffer);
      } catch (_) {}
    }

    try {
      const dLat = 0.00055;
      const dLon = 0.00095 / Math.max(0.2, Math.cos((lat * Math.PI) / 180));
      const bbox = `${lon - dLon},${lat - dLat},${lon + dLon},${lat + dLat}`;
      const arcUrl = `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?bbox=${bbox}&bboxSR=4326&imageSR=4326&size=640,360&format=jpg&f=image`;
      const { buffer, type } = await fetchBuffer(arcUrl, { 'User-Agent': 'ParkNowApp/1.0' });
      if (type.startsWith('image/')) {
        res.set('Content-Type', type);
        return res.send(buffer);
      }
    } catch (_) {}

    try {
      const z = 18;
      const n = Math.pow(2, z);
      const x = Math.floor(((lon + 180) / 360) * n);
      const rad = (lat * Math.PI) / 180;
      const y = Math.floor(((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * n);
      const tileUrl = `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/${z}/${y}/${x}`;
      const { buffer, type } = await fetchBuffer(tileUrl, { 'User-Agent': 'ParkNowApp/1.0' });
      res.set('Content-Type', type);
      return res.send(buffer);
    } catch (_) {
      return res.status(404).end();
    }
  });
};
