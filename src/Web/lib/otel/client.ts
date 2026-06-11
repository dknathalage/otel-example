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

  const url = process.env.NEXT_PUBLIC_OTLP_HTTP_URL; // e.g. https://otel.local/v1/traces
  if (!url) {
    // No collector endpoint configured; skip silently so the app still runs.
    return;
  }

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
      new FetchInstrumentation(),
      new UserInteractionInstrumentation(),
    ],
  });
}
