require('dotenv').config();
const express = require('express');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// Configurazione Storage: usa Supabase se configurato su Render, altrimenti SQLite locale
const useSupabase = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_KEY);
let supabase = null;
let db = null;

if (useSupabase) {
  const { createClient } = require('@supabase/supabase-js');
  supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_KEY);
  console.log('Storage attivo: Supabase PostgreSQL');
} else {
  const Database = require('better-sqlite3');
  const dbPath = path.join(__dirname, 'parkadvisor.db');
  db = new Database(dbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS parking_spots (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      status TEXT NOT NULL DEFAULT 'OCCUPIED',
      available_in_minutes INTEGER DEFAULT 0,
      detection_method TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
  console.log('Storage attivo: SQLite locale');
}

function getDistanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371e3;
  const φ1 = lat1 * Math.PI / 180;
  const φ2 = lat2 * Math.PI / 180;
  const Δφ = (lat2 - lat1) * Math.PI / 180;
  const Δλ = (lon2 - lon1) * Math.PI / 180;

  const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

// 1. Health check per Render e monitoraggio uptime H24
app.get('/', (req, res) => {
  res.json({
    status: 'ok',
    service: 'ParkNow! API',
    storage: useSupabase ? 'supabase' : 'sqlite'
  });
});

// 2. GET /api/parking/nearby - Restituisce SOLO stalli FREE o LEAVING_SOON (non scaduti)
app.get('/api/parking/nearby', async (req, res) => {
  try {
    const { lat, lon, radius = 1500 } = req.query;
    let rows = [];

    if (useSupabase) {
      const fifteenMinAgo = new Date(Date.now() - 15 * 60 * 1000).toISOString();
      await supabase
        .from('parking_spots')
        .delete()
        .eq('status', 'FREE')
        .lt('updated_at', fifteenMinAgo);

      const { data, error } = await supabase
        .from('parking_spots')
        .select('*')
        .in('status', ['LEAVING_SOON', 'FREE']);
      if (error) throw error;
      rows = data || [];
    } else {
      db.prepare(`
        DELETE FROM parking_spots 
        WHERE status = 'FREE' 
        AND datetime(updated_at) < datetime('now', '-15 minutes')
      `).run();

      rows = db.prepare(`
        SELECT * FROM parking_spots 
        WHERE status IN ('LEAVING_SOON', 'FREE')
      `).all();
    }

    const formattedSpots = rows.map(row => {
      const distance = (lat && lon)
        ? Math.round(getDistanceMeters(parseFloat(lat), parseFloat(lon), row.latitude, row.longitude))
        : null;

      return {
        id: row.id,
        userId: row.user_id,
        latitude: row.latitude,
        longitude: row.longitude,
        status: row.status,
        availableInMinutes: row.available_in_minutes,
        distanceMeters: distance,
        updatedAt: row.updated_at
      };
    });

    const result = (lat && lon)
      ? formattedSpots
          .filter(s => s.distanceMeters <= parseFloat(radius))
          .sort((a, b) => a.distanceMeters - b.distanceMeters)
      : formattedSpots;

    res.json({ count: result.length, spots: result });
  } catch (err) {
    console.error('Errore GET /nearby:', err);
    res.status(500).json({ error: 'Errore interno del database' });
  }
});

// 3. POST /api/parking/park
app.post('/api/parking/park', async (req, res) => {
  try {
    const { userId, latitude, longitude, detectionMethod = 'SENSOR_FUSION' } = req.body;

    if (!userId || latitude == null || longitude == null) {
      return res.status(400).json({ error: 'Parametri richiesti: userId, latitude, longitude' });
    }

    const spotId = `SPOT-${userId}-${Date.now()}`;
    const nowIso = new Date().toISOString();

    if (useSupabase) {
      await supabase.from('parking_spots').delete().eq('user_id', userId);
      const { error } = await supabase.from('parking_spots').insert({
        id: spotId,
        user_id: userId,
        latitude,
        longitude,
        status: 'OCCUPIED',
        available_in_minutes: 0,
        detection_method: detectionMethod,
        created_at: nowIso,
        updated_at: nowIso
      });
      if (error) throw error;
    } else {
      db.prepare('DELETE FROM parking_spots WHERE user_id = ?').run(userId);
      db.prepare(`
        INSERT INTO parking_spots (id, user_id, latitude, longitude, status, available_in_minutes, detection_method)
        VALUES (?, ?, ?, ?, 'OCCUPIED', 0, ?)
      `).run(spotId, userId, latitude, longitude, detectionMethod);
    }

    console.log(`[PARK] Utente ${userId} parcheggiato a (${latitude}, ${longitude}) via ${detectionMethod}`);
    res.status(201).json({ success: true, spotId, status: 'OCCUPIED' });
  } catch (err) {
    console.error('Errore POST /park:', err);
    res.status(500).json({ error: 'Errore registrazione parcheggio' });
  }
});

// 4. POST /api/parking/leaving
app.post('/api/parking/leaving', async (req, res) => {
  try {
    const { userId, availableInMinutes = 2 } = req.body;

    if (!userId) {
      return res.status(400).json({ error: 'Parametro richiesto: userId' });
    }

    if (useSupabase) {
      const { data, error } = await supabase
        .from('parking_spots')
        .update({
          status: 'LEAVING_SOON',
          available_in_minutes: availableInMinutes,
          updated_at: new Date().toISOString()
        })
        .eq('user_id', userId)
        .select();
      if (error) throw error;
      if (!data || data.length === 0) {
        return res.status(404).json({ error: 'Nessuna auto parcheggiata trovata per questo utente' });
      }
    } else {
      const info = db.prepare(`
        UPDATE parking_spots 
        SET status = 'LEAVING_SOON', available_in_minutes = ?, updated_at = CURRENT_TIMESTAMP 
        WHERE user_id = ?
      `).run(availableInMinutes, userId);

      if (info.changes === 0) {
        return res.status(404).json({ error: 'Nessuna auto parcheggiata trovata per questo utente' });
      }
    }

    console.log(`[LEAVING_SOON] Utente ${userId} entro 100m dall'auto. Libero tra ${availableInMinutes} min.`);
    res.json({ success: true, status: 'LEAVING_SOON', availableInMinutes });
  } catch (err) {
    console.error('Errore POST /leaving:', err);
    res.status(500).json({ error: 'Errore aggiornamento stato leaving' });
  }
});

// 5. POST /api/parking/release
app.post('/api/parking/release', async (req, res) => {
  try {
    const { userId } = req.body;

    if (!userId) {
      return res.status(400).json({ error: 'Parametro richiesto: userId' });
    }

    if (useSupabase) {
      const { data, error } = await supabase
        .from('parking_spots')
        .update({
          status: 'FREE',
          available_in_minutes: 0,
          updated_at: new Date().toISOString()
        })
        .eq('user_id', userId)
        .select();
      if (error) throw error;
      if (!data || data.length === 0) {
        return res.status(404).json({ error: 'Nessuno stallo da liberare per questo utente' });
      }
    } else {
      const info = db.prepare(`
        UPDATE parking_spots 
        SET status = 'FREE', available_in_minutes = 0, updated_at = CURRENT_TIMESTAMP 
        WHERE user_id = ?
      `).run(userId);

      if (info.changes === 0) {
        return res.status(404).json({ error: 'Nessuno stallo da liberare per questo utente' });
      }
    }

    console.log(`[FREE] Utente ${userId} ripartito. Stallo ora LIBERO sulla mappa.`);
    res.json({ success: true, status: 'FREE' });
  } catch (err) {
    console.error('Errore POST /release:', err);
    res.status(500).json({ error: 'Errore rilascio stallo' });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server ParkNow! attivo sulla porta ${PORT}`);
});
