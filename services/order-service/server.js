// Auto-instrumentation —> this is the ONLY OTel code you need to write
require('@opentelemetry/auto-instrumentations-node/register');

const express = require('express');
const axios = require('axios');

const app = express();
app.use(express.json());

const INVENTORY_URL = process.env.INVENTORY_SERVICE_URL || 'http://localhost:3001';
const SHIPPING_URL  = process.env.SHIPPING_SERVICE_URL  || 'http://localhost:3002';

const orders = [];

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/orders', (req, res) => res.json(orders));

app.post('/orders', async (req, res) => {
  const { item, quantity } = req.body;

  if (!item || !quantity) {
    return res.status(400).json({ error: 'item and quantity are required' });
  }

  const order = {
    id: `ord-${Date.now()}`,
    item,
    quantity,
    status: 'pending',
    createdAt: new Date().toISOString(),
  };

  try {
    const start = Date.now();
    const stockRes = await axios.get(`${INVENTORY_URL}/stock/${item}`);
    const latency = Date.now() - start;

    const { available } = stockRes.data;

    if (available < quantity) {
      order.status = 'rejected';
      order.reason = `only ${available} in stock`;
    } else {
      order.status = 'confirmed';
      await axios.post(`${SHIPPING_URL}/ship`, { orderId: order.id, item, quantity }).catch(() => {});
    }

    order.latencyMs = latency;
  } catch (err) {
    order.status = 'error';
    order.reason = err.response?.data?.error || err.message;
    order.inventoryStatusCode = err.response?.status;
  }

  orders.push(order);
  // 404 from inventory → item does not exist → 422 Unprocessable Entity
  // other upstream errors → 502 Bad Gateway
  const inventoryStatus = order.inventoryStatusCode;
  const statusCode = order.status !== 'error' ? 200
    : inventoryStatus === 404 ? 422
    : 502;
  res.status(statusCode).json(order);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`order-service listening on :${PORT}`));
