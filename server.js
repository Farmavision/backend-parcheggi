const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// Dati mock con coordinate realistiche attorno alla tua posizione GPS rilevata
let parkingSpots = [
  {
    id: 'PARK-001',
    name: 'Stallo A - Via Roma',
    latitude: 41.85795,
    longitude: 12.55860,
    isOccupied: false,
    sensorBleId: 'AA:BB:CC:01'
  },
  {
    id: 'PARK-002',
    name: 'Stallo B - Via Roma',
    latitude: 41.85820,
    longitude: 12.55910,
    isOccupied: true,
    sensorBleId: 'AA:BB:CC:02'
  },
  {
    id: 'PARK-003',
    name: 'Stallo C - Piazza',
    latitude: 41.85750,
    longitude: 12.55800,
    isOccupied: false,
    sensorBleId: 'AA:BB:CC:03'
  }
];

// Endpoint verifica stato
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', serverTime: new Date().toISOString() });
});

// Endpoint per recuperare i parcheggi disponibili
app.get('/api/parking/nearby', (req, res) => {
  const { lat, lon } = req.query;
  const available = parkingSpots.filter(spot => !spot.isOccupied);
  res.json({
    userPosition: { lat: parseFloat(lat), lon: parseFloat(lon) },
    totalAvailable: available.length,
    spots: available
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server ParkAdvisor attivo sulla porta ${PORT}`);
});
