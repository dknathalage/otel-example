'use client';

import { useState } from 'react';
import { createOrder } from '@/lib/api';

type Status =
  | { state: 'idle' }
  | { state: 'submitting' }
  | { state: 'success'; id: string }
  | { state: 'error'; message: string };

export default function Home() {
  const [sku, setSku] = useState('SKU-001');
  const [quantity, setQuantity] = useState(1);
  const [status, setStatus] = useState<Status>({ state: 'idle' });

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus({ state: 'submitting' });
    try {
      const result = await createOrder(sku, quantity);
      setStatus({ state: 'success', id: result.id });
    } catch (err) {
      setStatus({
        state: 'error',
        message: err instanceof Error ? err.message : 'unknown error',
      });
    }
  }

  return (
    <main
      style={{
        maxWidth: 480,
        margin: '4rem auto',
        padding: '0 1.5rem',
        fontFamily: 'system-ui, sans-serif',
      }}
    >
      <h1>Submit an order</h1>
      <p style={{ color: '#666' }}>
        Posts to the orders API and emits OpenTelemetry from the browser.
      </p>

      <form
        onSubmit={handleSubmit}
        style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}
      >
        <label style={{ display: 'flex', flexDirection: 'column', gap: '0.25rem' }}>
          SKU
          <input
            value={sku}
            onChange={(e) => setSku(e.target.value)}
            required
            style={{ padding: '0.5rem' }}
          />
        </label>

        <label style={{ display: 'flex', flexDirection: 'column', gap: '0.25rem' }}>
          Quantity
          <input
            type="number"
            min={1}
            value={quantity}
            onChange={(e) => setQuantity(Number(e.target.value))}
            required
            style={{ padding: '0.5rem' }}
          />
        </label>

        <button
          type="submit"
          disabled={status.state === 'submitting'}
          style={{ padding: '0.6rem', cursor: 'pointer' }}
        >
          {status.state === 'submitting' ? 'Submitting…' : 'Submit order'}
        </button>
      </form>

      {status.state === 'success' && (
        <p style={{ color: 'green', marginTop: '1rem' }}>
          Order accepted: {status.id}
        </p>
      )}
      {status.state === 'error' && (
        <p style={{ color: 'crimson', marginTop: '1rem' }}>Failed: {status.message}</p>
      )}
    </main>
  );
}
