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
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { UserInteractionInstrumentation } from '@opentelemetry/instrumentation-user-interaction';

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

  registerInstrumentations({
    instrumentations: [
      new DocumentLoadInstrumentation(),
      // Browser fetches (orders + OTLP export) are now same-origin via the
      // Next.js server proxies, so traceparent propagation is automatic. The
      // propagateTraceHeaderCorsUrls allow-list is harmless and left in place.
      new FetchInstrumentation({
        propagateTraceHeaderCorsUrls: [/.*/],
        clearTimingResources: true,
      }),
      new UserInteractionInstrumentation(),
    ],
  });
}
