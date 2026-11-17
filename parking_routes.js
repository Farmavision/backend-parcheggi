const https = require('https');

function fetchBuffer(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers, timeout: 5000 }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(fetchBuffer(res.headers.location, headers));
      }
      if (res.statusCode !== 200) return reject(new Error('HTTP ' + res.statusCode));
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ buffer: Buffer.concat(chunks), type: res.headers['content-type'] || 'image/jpeg' }));
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
      let r = await supabase.from('users').select('*').eq('id', uid).maybeSingle();
      if (!r.data) r = await supabase.from('users').select('*').eq('user_id', uid).maybeSingle();
      return r.data || null;
    }
    try { return db.prepare('SELECT * FROM users WHERE id = ?').get(uid) || null; } catch (_) { return null; }
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
      const user = await findUser(userId);
      const curBal = user ? Number(user.credits_balance ?? user.credits ?? 50) : 50;
      if (curBal < fee) return res.status(400).json({ error: 'Crediti insufficienti' });
      const newBalance = curBal - fee;

      if (useSupabase) {
        if (user) {
          const col = 'credits_balance' in user ? 'credits_balance' : 'credits';
          const keyCol = 'id' in user ? 'id' : 'user_id';
          await supabase.from('users').update({ [col]: newBalance }).eq(keyCol, user[keyCol]);
        }
        await supabase.from('parking_spots').update({ status: 'RESERVED', updated_at: new Date().toISOString() }).eq('id', spotId);
      } else {
        db.prepare("UPDATE parking_spots SET status = 'RESERVED', updated_at = CURRENT_TIMESTAMP WHERE id = ?").run(spotId);
      }

      const owner = await findUser(spot.user_id);
      const rawPlate = String(owner?.license_plate || owner?.plate || '').replace(/\s+/g, '');
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
            plateVisible: rawPlate.length >= 2 ? rawPlate.slice(-2) : rawPlate,
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
    const { lat, lon } = req.query;
    const key = process.env.GOOGLE_MAPS_API_KEY;
    if (!lat || !lon || !key) return res.status(404).end();
    try {
      const url = `https://maps.googleapis.com/maps/api/streetview?size=640x360&location=${lat},${lon}&fov=90&pitch=0&source=outdoor&key=${key}`;
      const { buffer, type } = await fetchBuffer(url);
      res.set('Content-Type', type);
      res.send(buffer);
    } catch (_) {
      res.status(404).end();
    }
  });
};
