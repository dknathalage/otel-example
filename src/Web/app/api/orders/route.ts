import { context, propagation } from '@opentelemetry/api';

// Server-side proxy for order creation. The browser POSTs same-origin to
// /api/orders; this handler forwards to the private in-cluster API
// (INTERNAL_API_URL, e.g. http://api).
//
// NOTE: @vercel/otel does NOT inject the W3C traceparent on the outgoing fetch
// to arbitrary (non-Vercel) URLs, so the API would start a brand-new trace and
// the browser→web trace would be disconnected from api→worker. We inject the
// active context explicitly so the API continues THIS (browser-rooted) trace.
export async function POST(request: Request): Promise<Response> {
  const body = await request.text();
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  propagation.inject(context.active(), headers);
  const upstream = await fetch(`${process.env.INTERNAL_API_URL}/orders`, {
    method: 'POST',
    headers,
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
