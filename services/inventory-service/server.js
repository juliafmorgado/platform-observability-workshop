// Auto-instrumentation —> this is the ONLY OTel code you need to write
require('@opentelemetry/auto-instrumentations-node/register');

const express = require('express');

const app = express();
app.use(express.json());

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/stock/:item', async (req, res) => {
  const { item } = req.params;

  // Simulated slowness
  if (item === 'slow-item') {
    await sleep(2000);
    return res.json({ item, available: 50 });
  }

  // Simulated failure
  if (item === 'broken-item') {
    return res.status(500).json({ error: 'database connection lost' });
  }

  res.json({ item, available: 50 });
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => console.log(`inventory-service listening on :${PORT}`));
