// Server-side proxy for order creation. The browser POSTs same-origin to
// /api/orders; this handler forwards to the private in-cluster API
// (INTERNAL_API_URL, e.g. http://api). The server-side fetch is auto-
// instrumented by @vercel/otel, so the W3C traceparent propagates
// Next -> API automatically and the trace nests cleanly.
export async function POST(request: Request): Promise<Response> {
  const body = await request.text();
  const upstream = await fetch(`${process.env.INTERNAL_API_URL}/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  });

  const payload = await upstream.text();
  return new Response(payload, {
    status: upstream.status,
    headers: {
      'content-type':
        upstream.headers.get('content-type') ?? 'application/json',
    },
  });
}
