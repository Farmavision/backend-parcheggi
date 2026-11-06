require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { createClient } = require('@supabase/supabase-js');
const cors = require('cors');

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: "*" } });

app.use(express.json());
app.use(cors());

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_KEY);

io.on('connection', (socket) => {
    console.log(`Nuovo utente connesso: ${socket.id}`);
    socket.on('join_zone', (data) => {
        socket.join('active_searchers');
        console.log(`Utente in ricerca: Lat ${data.lat}, Lng ${data.lng}`);
    });
});

app.post('/api/parking/drop', async (req, res) => {
    const { owner_id, lat, lng } = req.body;
    try {
        const { data, error } = await supabase.rpc('insert_parking', {
            p_owner_id: owner_id, p_lng: lng, p_lat: lat
        });
        if (error) throw error;
        res.status(200).json({ success: true, message: "Parcheggio registrato" });
    } catch (error) {
        console.error(error);
        res.status(500).json({ error: "Errore salvataggio parcheggio" });
    }
});
// Endpoint per cercare posti auto vicini
app.get('/api/parking/nearby', async (req, res) => {
  const { lat, lng, radius } = req.query;

  if (!lat || !lng) {
    return res.status(400).json({ error: 'Latitudine e longitudine sono obbligatorie' });
  }

  try {
    const { data, error } = await supabase.rpc('get_nearby_spots', {
      user_lat: parseFloat(lat),
      user_lng: parseFloat(lng),
      radius_meters: radius ? parseFloat(radius) : 1000
    });

    if (error) {
      console.error(error);
      return res.status(500).json({ error: 'Errore ricerca posti' });
    }

    res.json({ success: true, count: data.length, spots: data });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Errore interno del server' });
  }
});
// Endpoint per aggiornare lo stato del parcheggio (pre-rilascio o rilascio definitivo)
app.post('/api/parking/release', async (req, res) => {
  const { parking_id, owner_id, status, eta_minutes } = req.body;

  if (!parking_id || !owner_id || !status) {
    return res.status(400).json({ error: 'Parametri mancanti: parking_id, owner_id e status sono obbligatori' });
  }

  try {
    const { error } = await supabase.rpc('update_parking_status', {
      p_parking_id: parking_id,
      p_owner_id: owner_id,
      p_new_status: status,
      p_eta_minutes: eta_minutes || null
    });

    if (error) {
      console.error(error);
      return res.status(500).json({ error: 'Errore aggiornamento stato parcheggio' });
    }

    // Notifica in tempo reale via WebSocket a tutti gli utenti in ascolto
    io.emit('spot_status_changed', {
      parking_id,
      status,
      eta_minutes: eta_minutes || null
    });

    res.json({ success: true, message: `Stato parcheggio aggiornato a ${status}` });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Errore interno del server' });
  }
});
const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
    console.log(`🚀 Server Backend in esecuzione sulla porta ${PORT}`);
});