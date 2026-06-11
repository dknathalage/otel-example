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

- No manual **span/metric** code in business logic. Telemetry comes from
  auto-instrumentation. **Exception (explicit):** SDK *bootstrap is
  configuration* — the browser OTel Web SDK requires hand-written setup
  (`instrument.client.ts`), and Pub/Sub context propagation requires a thin shim
  (see Workload §). These are wiring, not instrumentation of business logic. The
  ".NET apps + Next.js SSR have zero telemetry code" claim is scoped to those
  three; the browser bootstrap and the Pub/Sub propagation shim are the two
  named, deliberate exceptions.
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

### Pub/Sub trace-context propagation (named exception to "zero code")

.NET auto-instrumentation does **not** automatically carry W3C trace context
across the Google Pub/Sub client libraries. Because the headline deliverable —
"one trace, end-to-end, in all three UIs" — depends entirely on this, the
pipeline includes a deliberate thin shim:

- **Publish (API):** inject `traceparent`/`tracestate` from the current
  `Activity` into the Pub/Sub message **attributes**.
- **Consume (Worker):** extract those attributes and start the consume
  `Activity` as a child / linked span before handing off to auto-instrumented
  code.

This is ~15 lines total and is the only span-touching code in the .NET apps. It
is called out here so the "zero telemetry code" claim stays honest. If a
maintained auto-instr library later covers this, the shim is removed.

### Browser → Collector transport

Browser spans are sent **directly to the collector** OTLP/HTTP receiver (not
proxied through Next.js):

- A dedicated ingress host (e.g. `otel.<env>.<domain>`, and
  `localhost:<port>` mapped via kind extraPortMappings locally) routes to the
  collector's OTLP/HTTP port.
- The collector OTLP/HTTP receiver enables **CORS** with `allowed_origins` set
  to the web app origin(s) per env. Without this the browser exporter is
  rejected by the preflight.
- Same ingress shape local and GKE; only hostnames differ (Helm values).

## Components

### Applications (`apps/`)

| App | Stack | Instrumentation |
|-----|-------|-----------------|
| `web` | Next.js | Browser OTel Web SDK + node auto-instrumentation (SSR) |
| `api` | .NET minimal API | `OpenTelemetry.AutoInstrumentation` (profiler) |
| `worker` | .NET `BackgroundService` | `OpenTelemetry.AutoInstrumentation` (profiler) |

**No business-logic instrumentation code** (see Non-goals for the two named
exceptions: browser SDK bootstrap, Pub/Sub propagation shim). Instrumentation is
otherwise enabled entirely by environment + bundled auto-instrumentation:

- **.NET (api, worker):** auto-instrumentation copied into the image, enabled by
  env (`CORECLR_ENABLE_PROFILING=1`, `CORECLR_PROFILER`, the OTel auto-instr
  paths, `OTEL_EXPORTER_OTLP_ENDPOINT=<collector>`,
  `OTEL_SERVICE_NAME=<app>`). Apart from the Pub/Sub shim, no OTel SDK calls.

**Standard resource attributes** (set on every service via
`OTEL_RESOURCE_ATTRIBUTES`, and mirrored in the browser SDK Resource) so the
same trace correlates and filters identically across all three UIs:
`service.name`, `service.namespace=otel-poc`, `service.version`,
`deployment.environment=<local|gke>`.
- **Next.js server:** `NODE_OPTIONS=--require ./instrument.js` loads
  `@opentelemetry/auto-instrumentations-node`.
- **Browser:** OTel Web SDK (`@opentelemetry/sdk-trace-web`,
  `instrumentation-document-load`, `instrumentation-fetch`,
  `instrumentation-user-interaction`) exporting OTLP/http to the collector via
  ingress.

### OpenTelemetry Collector (`deploy/helm/otel-poc/`)

- `otelcol-contrib` Deployment (gateway pattern).
- **Receivers:** OTLP gRPC + HTTP. The HTTP receiver enables `cors`
  (`allowed_origins` = web origin per env) for direct browser export.
- **Processors:** `batch`; `resourcedetection` with the `gcp` detector — **GKE
  only** (skipped/no-op on kind, which has no metadata server); headroom for
  `tail_sampling` later.
- **Exporters (one concrete choice each):**
  - **Google Cloud:** `googlecloud` exporter (native traces + metrics + logs to
    Cloud Observability; richer than generic OTLP-to-GCP for logs).
  - **Dash0:** `otlphttp/dash0` with `Authorization: Bearer <token>` +
    `Dash0-Dataset` header.
  - **Coralogix:** the dedicated `coralogix` exporter (handles app/subsystem
    metadata + private-key auth across all three signals).
- **Pipelines:** one per signal (traces, metrics, logs), each fanning out to all
  enabled exporters. Pipeline membership is templated from `backends.*.enabled`
  (see Configuration §).
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

### Image build & distribution

- Three images (`web`, `api`, `worker`) built from per-app Dockerfiles. Tag =
  short git SHA; chart references images by `{repo}:{tag}` via Helm values.
- **local:** build locally, `kind load docker-image <img>:<tag>` into the kind
  cluster (no registry). A `Makefile`/`Taskfile` target wraps build + load.
- **gke:** push to **Artifact Registry** (provisioned by Tofu); pods pull via
  the node SA. Image push happens **before** Helm install.

### Deployment ordering (per env)

**local:** `tofu apply (kind)` → build + `kind load` images → `helm install`
(apps + collector + emulator/data containers). ADC (`gcloud auth
application-default login`) must exist for GSM reads.

**gke:** `tofu apply (gke)` provisions cluster + Artifact Registry + WIF + GSM
secrets + managed deps (Cloud SQL, Memorystore, Firestore, Pub/Sub) → build +
**push images to AR** → `helm install`. WIF binding and GSM secrets must exist
before pods start (pods read GSM at boot); managed deps must exist before app
env points at them.

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

Helm `values.yaml` exposes per-backend toggles. Each backend carries everything
the collector template needs to build its exporter:

```yaml
gcpProject: my-poc-project          # used for googlesecretmanager refs + GCP exporter
backends:
  google:
    enabled: true
    # auth via Workload Identity / ADC; no token needed
  dash0:
    enabled: true
    endpoint: https://ingress.<region>.dash0.com
    dataset: otel-poc
    tokenSecret: dash0-token        # GSM secret name
  coralogix:
    enabled: true
    domain: <coralogix-domain>
    appName: otel-poc
    keySecret: coralogix-key        # GSM secret name
```

The collector ConfigMap template:
1. Renders an exporter block for each `enabled` backend (pulling tokens via
   `${googlesecretmanager:projects/{{ gcpProject }}/secrets/<secret>}`).
2. For each of the three signal pipelines, sets `exporters:` to the list of
   enabled backends. A disabled backend is omitted from every pipeline and its
   exporter block is not rendered.

Disabling a backend touches only the collector config — apps and infra are
untouched.

## Deliverable

`docs/` comparison report:

- **Same trace rendered in all three UIs** (screenshots).
- Comparison matrix across axes: trace UX, log↔trace correlation, metrics
  rendering, ingest lag, browser/RUM support, **session replay (Coralogix only,
  not OTel)**, query/alerting, cost.
- **k6 load generator** to produce order volume for ingest/UX-under-load
  comparison. **Cost guard:** the 3× fan-out sends every signal to three (paid)
  backends; the load test runs bounded (capped RPS + duration), and the collector
  may apply head/probabilistic sampling for the load run to keep ingest cost
  predictable. Document the sampling rate used so the comparison is fair.

## Testing

- **App units:** minimal — pipeline handlers (order create, consume) only.
- **End-to-end validation:** an order produces the expected end-to-end span tree.
- **CI smoke:** collector configured with the **`file` exporter** (writes spans
  to a mounted path) alongside `debug`. The test submits an order, then reads the
  file exporter output and asserts the expected span names + parent/child links
  (incl. the Pub/Sub publish→consume continuity). No live backend credentials in
  CI; GSM/exporters stubbed out.

## Open Items / Future

- `tail_sampling` processor (left as a hook, not in initial scope).
- Per-backend dashboards-as-code where the vendor supports it.
