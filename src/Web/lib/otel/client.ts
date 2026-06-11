'use client';

import {
  WebTracerProvider,
  BatchSpanProcessor,
} from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ZoneContextManager } from '@opentelemetry/context-zone';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { resourceFromAttributes } from '@opentelemetry/resources';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_NAMESPACE,
} from '@opentelemetry/semantic-conventions';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';

let initialized = false;

/**
 * Bootstraps the browser OpenTelemetry Web SDK and ships spans to the
 * collector's OTLP/http traces endpoint (NEXT_PUBLIC_OTLP_HTTP_URL).
 *
 * This is the ONLY browser-side place OpenTelemetry is wired up; business
 * and UI components must never import OTel directly.
 */
export function initBrowserOtel(): void {
  if (initialized || typeof window === 'undefined') {
    return;
  }
  initialized = true;

  // Default to the same-origin Next.js OTLP proxy (app/api/otlp/v1/traces),
  // which forwards to the private in-cluster collector. Same-origin means no
  // CORS and automatic traceparent propagation.
  const url = process.env.NEXT_PUBLIC_OTLP_HTTP_URL || '/api/otlp/v1/traces';

  const provider = new WebTracerProvider({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: 'web-browser',
      [ATTR_SERVICE_NAMESPACE]: 'otel-poc',
    }),
    spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url }))],
  });

  provider.register({ contextManager: new ZoneContextManager() });

  // ONLY fetch instrumentation: it captures the order POST as the browser-root
  // span that connects to the API/worker chain. DocumentLoad (page-load asset
  // resourceFetch spans) and UserInteraction are deliberately omitted — they're
  // page-load RUM noise, not part of the browser→data order trace.
  registerInstrumentations({
    instrumentations: [
      new FetchInstrumentation({
        propagateTraceHeaderCorsUrls: [/.*/],
        clearTimingResources: true,
        // Don't trace the span-export POSTs to the OTLP proxy — telemetry about
        // telemetry.
        ignoreUrls: [/\/api\/otlp/],
      }),
    ],
  });
}
