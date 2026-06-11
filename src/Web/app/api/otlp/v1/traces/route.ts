// Same-origin OTLP proxy so the browser exports traces without a cross-origin
// request (only `web` is exposed; the collector is private). Forwards the RAW
// OTLP/protobuf body to the in-cluster collector at
// `${OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces`, preserving content-type. The body
// is read as an ArrayBuffer so it is binary-safe (never JSON-parsed).
export async function POST(request: Request): Promise<Response> {
  const body = await request.arrayBuffer();
  const upstream = await fetch(
    `${process.env.OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces`,
    {
      method: 'POST',
      headers: {
        'content-type':
          request.headers.get('content-type') ?? 'application/x-protobuf',
      },
      body,
    },
  );

  const payload = await upstream.arrayBuffer();
  return new Response(payload, {
    status: upstream.status,
    headers: {
      'content-type':
        upstream.headers.get('content-type') ?? 'application/x-protobuf',
    },
  });
}
