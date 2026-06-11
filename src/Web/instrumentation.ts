import { registerOTel } from '@vercel/otel';

export function register() {
  // Server-side OTel. Exporter endpoint comes from OTEL_EXPORTER_OTLP_ENDPOINT.
  registerOTel({ serviceName: 'web' });
}
