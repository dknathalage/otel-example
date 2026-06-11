# OTel Multi-Backend POC — Design

**Date:** 2026-06-11
**Status:** Approved design, pre-implementation

## Goal

Proof-of-concept comparing three OpenTelemetry backends — **Google Cloud
Observability**, **Dash0**, and **Coralogix** — using a single, identical
auto-instrumented application stack. The apps never know which backend(s)
receive their telemetry; the only swap point is the OpenTelemetry Collector
exporter configuration. Same OTLP data (traces + metrics + logs) fans out to
all three so the same trace can be viewed side-by-side in three UIs.

### Non-goals

- No manual/code-level instrumentation. Auto-instrumentation only.
- No proprietary vendor browser SDKs. Frontend ships pure OTel Web SDK spans.
- **Session replay is explicitly out of scope** — it is not part of the
  OpenTelemetry spec and only Coralogix offers it. It is documented as a
  comparison *axis* ("who supports it"), not built.

## Architecture

```
Browser (Next.js client, OTel Web SDK)
        │ OTLP/http
Next.js (SSR, node auto-instr) ──┐
        │ HTTP                    │ OTLP
   .NET API (auto-instr) ─────────┤
   ├─ Postgres (orders)           │
   ├─ Redis (cache/idempotency)   ▼
   └─ Pub/Sub publish ──►  OTel Collector (gateway)
        │                   receivers: OTLP grpc+http
   .NET Worker (auto-instr)  processors: batch, resourcedetection
   ├─ Pub/Sub consume        exporters ──┬─► Google Cloud Observability
   └─ Firestore (read-model)             ├─► Dash0
                                         └─► Coralogix
```

**Swap point = Collector exporter config only.** Each backend is individually
toggleable via Helm values. Applications emit OTLP to a single in-cluster
collector endpoint and are unaware of downstream backends.

## Workload — Order Pipeline

A realistic distributed trace spanning HTTP, cache, messaging, SQL, and NoSQL:

1. **Browser** (Next.js client) submits an order. OTel Web SDK emits
   `document-load`, `fetch`, and `user-interaction` spans → OTLP/http via
   ingress to the collector.
2. **Next.js SSR** (node auto-instrumentation) forwards to the API.
3. **.NET API** (minimal API, auto-instrumented):
   - Writes the order to **Postgres**.
   - Uses **Redis** for cache / idempotency keys.
   - Publishes `OrderCreated` to **Pub/Sub**.
4. **.NET Worker** (`BackgroundService`, auto-instrumented):
   - Consumes `OrderCreated` from **Pub/Sub**.
   - Processes and writes the read-model / status to **Firestore**.
5. Next.js reads order status (API → Firestore).

Resulting span tree exercises: browser spans, HTTP server/client, Redis,
Postgres, Pub/Sub publish + subscribe (cross-service context propagation),
Firestore. This variety stresses each backend's trace UX and correlation.

## Components

### Applications (`apps/`)

| App | Stack | Instrumentation |
|-----|-------|-----------------|
| `web` | Next.js | Browser OTel Web SDK + node auto-instrumentation (SSR) |
| `api` | .NET minimal API | `OpenTelemetry.AutoInstrumentation` (profiler) |
| `worker` | .NET `BackgroundService` | `OpenTelemetry.AutoInstrumentation` (profiler) |

**Zero telemetry code in app source.** Instrumentation is enabled entirely by
environment + bundled auto-instrumentation:

- **.NET (api, worker):** auto-instrumentation copied into the image, enabled by
  env (`CORECLR_ENABLE_PROFILING=1`, `CORECLR_PROFILER`, the OTel auto-instr
  paths, `OTEL_EXPORTER_OTLP_ENDPOINT=<collector>`,
  `OTEL_SERVICE_NAME=<app>`). No OTel SDK calls in code.
- **Next.js server:** `NODE_OPTIONS=--require ./instrument.js` loads
  `@opentelemetry/auto-instrumentations-node`.
- **Browser:** OTel Web SDK (`@opentelemetry/sdk-trace-web`,
  `instrumentation-document-load`, `instrumentation-fetch`,
  `instrumentation-user-interaction`) exporting OTLP/http to the collector via
  ingress.

### OpenTelemetry Collector (`deploy/helm/otel-poc/`)

- `otelcol-contrib` Deployment (gateway pattern).
- **Receivers:** OTLP gRPC + HTTP.
- **Processors:** `batch`, `resourcedetection` (gcp), headroom for
  `tail_sampling` later.
- **Exporters:** Google Cloud (`googlecloud`/OTLP telemetry endpoint),
  `otlphttp/dash0`, `otlp/coralogix` (or `coralogix` exporter).
- **Pipelines:** one per signal (traces, metrics, logs), each fanning out to all
  three enabled exporters.
- Exporter auth tokens resolved via the `googlesecretmanager` config provider:
  `${googlesecretmanager:projects/PROJECT/secrets/dash0-token}` etc.

### Infrastructure (`infra/`)

OpenTofu modules wrapped by Terragrunt for two environments.

```
infra/
  modules/
    local-kind/    # kind cluster via tofu kind provider
    gke/           # GKE + Artifact Registry + WIF + managed deps + GSM
  live/
    terragrunt.hcl # root: shared remote state, provider, inputs
    local/         # env=local inputs
    gke/           # env=gke inputs
```

- **local:** Tofu `kind` provider stands up a local cluster. Pipeline deps run
  in-cluster as containers: Postgres, Redis, **Pub/Sub emulator**, **Firestore
  emulator**. Apps point at emulator endpoints.
- **gke:** Tofu provisions GKE, Artifact Registry, Workload Identity
  Federation, real **Pub/Sub** topics/subscriptions, **Firestore** DB, **Cloud
  SQL** (Postgres), **Memorystore** (Redis), and **GSM** secrets. Apps point at
  real endpoints.
- **Terragrunt** keeps inputs DRY across the two envs; same Helm chart deploys
  to both.

### Secrets — Google Secret Manager everywhere

- Tofu provisions GSM secrets (Dash0 token, Coralogix key, DB creds), the GCP
  service account, the WIF binding, and IAM `roles/secretmanager.secretAccessor`.
- **Apps + worker:** GCP Secret Manager client at startup.
  - GKE: Workload Identity (k8s SA → GCP SA).
  - Local: Application Default Credentials (`gcloud auth
    application-default login`) against a dev GCP project — **same** GSM, same
    secret names.
- **Collector:** `googlesecretmanager` config provider, same auth path.
- **Accepted trade-off:** local is not fully offline — it needs a real dev GCP
  project + ADC. Pub/Sub and Firestore remain emulated locally; only secrets
  (and, on GKE, the managed data services) are real.

## Configuration & Swap Mechanics

Helm `values.yaml` exposes per-backend toggles:

```yaml
backends:
  google:    { enabled: true }
  dash0:     { enabled: true,  endpoint: ..., tokenSecret: dash0-token }
  coralogix: { enabled: true,  endpoint: ..., keySecret: coralogix-key }
```

Disabling a backend drops its exporter from the collector pipelines. Apps and
infra are untouched.

## Deliverable

`docs/` comparison report:

- **Same trace rendered in all three UIs** (screenshots).
- Comparison matrix across axes: trace UX, log↔trace correlation, metrics
  rendering, ingest lag, browser/RUM support, **session replay (Coralogix only,
  not OTel)**, query/alerting, cost.
- **k6 load generator** to produce order volume for ingest/UX-under-load
  comparison.

## Testing

- **App units:** minimal — pipeline handlers (order create, consume) only.
- **End-to-end validation:** an order produces the expected end-to-end span tree.
- **CI smoke:** collector configured with the `debug`/logging exporter; a
  submitted order asserts the spans flow through the collector — no live backend
  credentials required in CI.

## Open Items / Future

- `tail_sampling` processor (left as a hook, not in initial scope).
- Per-backend dashboards-as-code where the vendor supports it.
