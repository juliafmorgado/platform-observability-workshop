// Notice that no OTel is required here. The operator will inject it.
const express = require('express');

const app = express();
app.use(express.json());

const carriers = ['FedEx', 'UPS', 'DHL', 'USPS'];

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.post('/ship', (req, res) => {
  const { orderId, item, quantity } = req.body;

  if (!orderId) {
    return res.status(400).json({ error: 'orderId is required' });
  }

  const carrier = carriers[Math.floor(Math.random() * carriers.length)];
  const tracking = `TRK-${Date.now()}`;
  const eta = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString().split('T')[0];

  res.json({ orderId, item, quantity, carrier, tracking, eta });
});

app.get('/shipments/:orderId', (req, res) => {
  res.json({
    orderId: req.params.orderId,
    status: 'in_transit',
    carrier: 'FedEx',
    tracking: `TRK-${req.params.orderId}`,
  });
});

const PORT = process.env.PORT || 3002;
app.listen(PORT, () => console.log(`shipping-service listening on :${PORT}`));
