export interface CreateOrderResult {
  id: string;
}

export async function createOrder(
  sku: string,
  quantity: number,
): Promise<CreateOrderResult> {
  const res = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sku, quantity }),
  });
  if (!res.ok) {
    throw new Error(`order request failed: ${res.status} ${res.statusText}`);
  }
  return res.json();
}
