export interface CreateOrderResult {
  id: string;
}

export async function createOrder(
  sku: string,
  quantity: number,
): Promise<CreateOrderResult> {
  // Same-origin: posts to the Next.js server proxy (app/api/orders/route.ts),
  // which forwards to the private in-cluster API. No CORS / cross-origin.
  const res = await fetch('/api/orders', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sku, quantity }),
  });
  if (!res.ok) {
    throw new Error(`order request failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}
