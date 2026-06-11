# OTel Multi-Backend POC — Design

**Date:** 2026-06-11
**Status:** Approved design, pre-implementation (revised after vendor-doc verification)

## Goal

Proof-of-concept comparing three OpenTelemetry backends — **Google Cloud
Observability**, **Dash0**, and **Coralogix** — using a single, identical
auto-instrumented application stack. Each backend gets its **own isolated
deployment** (one Helm release → one namespace → one collector exporting to one
backend). To compare, deploy all three releases and run the **same k6 scenario**
against each, then compare how each backend renders the resulting telemetry.

The application code never changes between providers. The only difference between
releases is one Helm value: `provider`.

### Comparison model (revised)

Earlier framing was "one trace fanned out to three UIs." Per the per-provider
isolation directive, the model is now **N isolated stacks, identical scenario**:
the same k6 script drives each namespace, producing equivalent (not byte-identical)
traces in each backend. Trade-off accepted: not literally the same trace object,
but fully isolated, apples-to-apples per-provider stacks.

### Non-goals

- No manual **span/metric** code in business logic. Telemetry comes from
  auto-instrumentation **plus** the shared `core.*` packages, which encapsulate
  the unavoidable manual bits (see below) in one reusable place so business code
  stays clean.
- No proprietary vendor browser SDKs. Frontend ships pure OTel Web SDK spans.
- **Session replay is out of scope** — not part of the OTel spec, Coralogix-only.
  Documented as a comparison axis, not built.

### Verified manual-instrumentation exceptions (from vendor docs)

Auto-instrumentation does **not** cover everything. These gaps are real and are
the reason the `core.*` packages exist:

- **GCP Pub/Sub** — .NET auto-instrumentation does **not** propagate W3C trace
  context across Pub/Sub. (Google's client-library auto-tracing covers Go/Java/
  Python/Node/C++ but **not .NET**.) → `core.pubsub` injects `traceparent` into
  message attributes on publish and extracts on consume, and emits the
  producer/consumer spans (`messaging.system=gcp_pubsub`).
- **GCP Firestore** — `Google.Cloud.Firestore` is **not auto-instrumented**
  (gRPC, not ADO.NET). → `core.firestore` emits manual client spans.
- **Postgres (Npgsql ≥6.0)** and **StackExchange.Redis** **are** auto-instrumented
  → `core.data` / `core.redis` are thin (connection + helpers), no manual spans.
- **ILogger logs** are captured and exported as OTLP automatically by the .NET
  agent → `core.logging` is conventions + enrichment, not an exporter.

## Architecture (per provider release)

```
Browser (Next.js client, OTel Web SDK)
        │ OTLP/http (CORS)
Next.js (instrumentation.ts + @vercel/otel) ──┐
        │ HTTP                                  │ OTLP
   .NET API (zero-code agent + core.*) ─────────┤
   ├─ core.data    → Postgres                    │
   ├─ core.redis   → Redis                        ▼
   └─ core.pubsub  → Pub/Sub publish ──►  OTel Collector
        │  (traceparent injected)         (one per namespace)
   .NET Worker (zero-code agent + core.*)  receivers: OTLP grpc+http(+CORS)
   ├─ core.pubsub  → Pub/Sub consume       processors: batch, resource
   └─ core.firestore → Firestore           exporter ──► ONE backend
                                            (google | dash0 | coralogix)
```

Three releases → three namespaces (`otel-poc-google`, `otel-poc-dash0`,
`otel-poc-coralogix`), each a full self-contained stack exporting to exactly one
backend.

## Workload — Order Pipeline

Distributed trace spanning browser → HTTP → cache → SQL → messaging → NoSQL:

1. **Browser** submits an order (OTel Web SDK: `document-load`, `fetch`,
   `user-interaction`) → OTLP/http to the namespace collector.
2. **Next.js SSR** forwards to the API.
3. **.NET API**: `core.data` writes order to **Postgres**; `core.redis` handles
   idempotency; `core.pubsub` publishes `OrderCreated` to **Pub/Sub** with
   injected trace context.
4. **.NET Worker**: `core.pubsub` consumes `OrderCreated` (extracts context),
   `core.firestore` writes the read-model to **Firestore**.
5. Next.js reads status (API → Firestore).

## Shared `core.*` packages

A set of small, single-purpose **.NET class libraries** under `src/core/`,
referenced by both `api` and `worker`. Each has one clear purpose, a narrow
public interface, and is independently testable. Business code depends on these,
never on the SDKs directly.

| Package | Purpose | Notes |
|---------|---------|-------|
| `Core.Secrets` | GSM-backed secret access. `ISecretProvider` → `GsmSecretProvider` over `Google.Cloud.SecretManager.V1`. Caches values. | WIF on GKE, ADC locally. Single auth path for all apps. |
| `Core.Telemetry` | Shared `ActivitySource`, the W3C `TextMapPropagator`, resource-attribute conventions, helpers to start manual spans. | Used by `core.pubsub`/`core.firestore` for the manual spans the agent can't produce. |
| `Core.Logging` | `ILogger` conventions + structured enrichment (order id, trace correlation scopes). | Agent exports these as OTLP logs automatically; this is config, not an exporter. |
| `Core.PubSub` | Publish/consume wrapper over `Google.Cloud.PubSub.V1`. **Injects `traceparent`/`tracestate` into message attributes on publish, extracts on consume**, emits producer/consumer spans. | THE home of the propagation shim. Depends on `Core.Telemetry`. |
| `Core.Firestore` | Wrapper over `Google.Cloud.Firestore` with **manual client spans** + consistent attributes. | Firestore is not auto-instrumented. Depends on `Core.Telemetry`. |
| `Core.Redis` | `StackExchange.Redis` connection mgmt + cache/idempotency helpers. | Auto-instrumented for traces; package is thin. |
| `Core.Data` | Postgres access (Npgsql/EF Core), orders repository + migrations. | Auto-instrumented; package is thin. |

**Contract for all apps:** apps inject these via DI, configure them from
`Core.Secrets` + env, and never call Google/Redis/Npgsql SDKs directly. New
services follow the same wiring.

**Next.js (TypeScript)** is not a .NET app, so it does not consume the `Core.*`
libraries. It mirrors the same *contracts* in a thin `web/lib/`: `lib/secrets.ts`
(server-side GSM read, same secret names) and `lib/otel/` (browser bootstrap).
Web touches no Pub/Sub/Firestore/Redis directly — it calls the API.

## Auto-instrumentation details (verified)

### .NET (api, worker) — zero-code agent

Bundled `OpenTelemetry.AutoInstrumentation` (v1.15.x), enabled by env. Canonical
container env:

```dockerfile
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so
ENV DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps
ENV DOTNET_SHARED_STORE=/otel-dotnet-auto/store
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318
ENV OTEL_SERVICE_NAME=<app>
ENV OTEL_RESOURCE_ATTRIBUTES=service.namespace=otel-poc,deployment.environment.name=<env>,service.version=<sha>
# OTEL_{TRACES,METRICS,LOGS}_EXPORTER default to otlp already
```

Install in Dockerfile via `otel-dotnet-auto-install.sh`; either `source
instrument.sh` in the entrypoint or set all env statically. Logs (ILogger) export
on by default. Covered out of the box: ASP.NET Core, HttpClient, Npgsql ≥6.0,
StackExchange.Redis 2.6.122–<3.0. **Not** covered: Pub/Sub, Firestore (→ handled
by `core.*`).

### Next.js — `instrumentation.ts` + `@vercel/otel` (server) + OTel Web SDK (browser)

- **Server (Next 15+ recommended):** root `instrumentation.ts` calling
  `registerOTel({ serviceName: 'web' })` from `@vercel/otel`. Reads standard
  `OTEL_*` env for the collector endpoint. (Not `NODE_OPTIONS=--require`.)
- **Browser:** pure OTel Web SDK — `@opentelemetry/sdk-trace-web`,
  `exporter-trace-otlp-http`, `instrumentation-document-load`, `-fetch`,
  `-user-interaction`, `context-zone`. Exports OTLP/http to the namespace
  collector ingress. Resource attrs mirror the .NET set.

## OpenTelemetry Collector (one per namespace, single backend)

- Distro: **Google-Built OpenTelemetry Collector** (bundles `googleclientauth` +
  the `googlesecretmanager` confmap provider) for the Google release; upstream
  `otelcol-contrib` is equivalent for Dash0/Coralogix. Using the Google-built
  distro everywhere keeps one image.
- **Receivers:** OTLP gRPC + HTTP. HTTP receiver enables CORS for browser export:
  ```yaml
  receivers:
    otlp:
      protocols:
        grpc: {}
        http:
          endpoint: 0.0.0.0:4318
          cors:
            allowed_origins: ["https://<web-origin-for-env>"]  # NOT plain "*"
            allowed_headers: ["*"]
  ```
- **Processors:** `batch`; `resource` to set `gcp.project_id` (Google release);
  `resourcedetection/gcp` is GKE-only (no-op on kind).
- **Exporter — exactly one, selected by `provider`:**

  **google** (preferred 2026 OTLP-native path):
  ```yaml
  extensions:
    googleclientauth: {}
  processors:
    resource/gcp:
      attributes:
        - { key: gcp.project_id, value: ${env:GCP_PROJECT}, action: upsert }
  exporters:
    otlphttp/google:
      endpoint: https://telemetry.googleapis.com
      encoding: proto
      auth:
        authenticator: googleclientauth
  ```

  **dash0:**
  ```yaml
  exporters:
    otlphttp/dash0:
      endpoint: https://ingress.<region>.aws.dash0.com   # base, no /v1 path
      headers:
        Authorization: "Bearer ${googlesecretmanager:projects/${env:GCP_PROJECT}/secrets/dash0-token/versions/latest}"
        Dash0-Dataset: "otel-poc"
  ```

  **coralogix** (dedicated exporter, one block serves all 3 signals):
  ```yaml
  exporters:
    coralogix:
      domain: "<region>.coralogix.com"          # e.g. eu2.coralogix.com
      private_key: "${googlesecretmanager:projects/${env:GCP_PROJECT}/secrets/coralogix-key/versions/latest}"
      application_name: "otel-poc"
      subsystem_name: "${env:OTEL_SERVICE_NAME}"
  ```

- **Pipelines:** traces, metrics, logs — each wired to the single selected
  exporter.
- **GSM provider syntax (verified):**
  `${googlesecretmanager:projects/PROJECT/secrets/NAME/versions/latest}` — the
  `/versions/<n|latest>` segment is required.

### Dash0 browser caveat (verified risk)

Dash0 documents only its proprietary `@dash0/sdk-web` for browser RUM. Pure OTel
Web SDK spans POST to the same `/v1/traces` ingress and **work mechanically**, but
this is **not an officially supported Dash0 path**. For the Dash0 release: use a
**dedicated ingest-only, dataset-scoped** token for the browser (it ships in
client JS), and set CSP `connect-src` to the Dash0 ingress. Documented as a known
risk in the comparison.

## Infrastructure (`infra/`)

OpenTofu modules wrapped by Terragrunt; two environments.

```
infra/
  modules/{local-kind,gke}/
  live/
    terragrunt.hcl          # root: shared state, provider, inputs
    local/                  # kind env
    gke/                    # gke env
```

- **local:** Tofu `kind` provider. Each namespace release runs its **own**
  in-namespace deps: Postgres, Redis, **Pub/Sub emulator**, **Firestore
  emulator** containers. Fully offline except GSM (real, via ADC).
- **gke:** Tofu provisions GKE, Artifact Registry, Workload Identity, GSM
  secrets, and the managed data services. To bound cost, the managed instances
  (Cloud SQL, Memorystore, Firestore) are **shared** across the three releases,
  but each release gets **logical isolation**: its own Pub/Sub topic+subscription,
  its own Postgres database/schema, and a namespaced Firestore collection prefix
  (all derived from the release name via Helm values).
- **Terragrunt** keeps inputs DRY across envs.

### Image build & distribution

- Three images (`web`, `api`, `worker`), per-app Dockerfiles, tag = short git SHA.
- **local:** build + `kind load docker-image <img>:<tag>`.
- **gke:** push to Artifact Registry before Helm install.

### Deployment ordering (per env)

**local:** `tofu apply (kind)` → build + `kind load` → `helm install` per
provider (each `--create-namespace`). ADC must exist for GSM reads.

**gke:** `tofu apply (gke)` (cluster + AR + WIF + GSM secrets + shared managed
deps) → build + push images → `helm install` per provider. WIF binding + GSM
secrets must exist before pods start; managed deps before app env points at them.

## Helm chart — single provider, owns its namespace

One chart `deploy/helm/otel-poc/`. **Each release targets exactly one provider
and creates its own namespace and all resources within it.**

```bash
helm install otel-poc-google ./deploy/helm/otel-poc \
  --set provider=google --namespace otel-poc-google --create-namespace
helm install otel-poc-dash0 ./deploy/helm/otel-poc \
  --set provider=dash0 --namespace otel-poc-dash0 --create-namespace
helm install otel-poc-coralogix ./deploy/helm/otel-poc \
  --set provider=coralogix --namespace otel-poc-coralogix --create-namespace
```

The chart renders, into the release namespace: the three app Deployments +
Services, the collector Deployment + ConfigMap (with the one provider's exporter),
the Ingress (apps + browser-OTLP host), the ServiceAccount + WIF annotation, and
— on `local` — the dep containers (Postgres/Redis/Pub-Sub-emulator/Firestore-
emulator).

`values.yaml` shape:

```yaml
provider: google            # google | dash0 | coralogix  (the only swap)
env: local                  # local | gke
gcpProject: my-poc-project
image: { registry: ..., tag: <sha> }

providers:
  google: {}                                  # auth via WIF/ADC, no token
  dash0:
    region: us-west-2
    dataset: otel-poc
    tokenSecret: dash0-token                  # GSM secret name
  coralogix:
    domain: eu2.coralogix.com
    keySecret: coralogix-key                  # GSM secret name

deps:                        # rendered only when env=local
  enabled: true
```

The collector ConfigMap template selects the exporter block by `.Values.provider`
and wires it into all three pipelines. Switching providers = a different release
with a different `provider` value; nothing else changes.

## Secrets — Google Secret Manager everywhere

- Tofu provisions GSM secrets (`dash0-token`, `coralogix-key`, DB creds), the GCP
  service account, the WIF binding, and IAM
  `roles/secretmanager.secretAccessor`.
- **Apps (`Core.Secrets`):** GSM client at startup — WIF on GKE, ADC locally.
- **Collector:** `googlesecretmanager` confmap provider, same auth path, with the
  `/versions/latest` syntax.
- **Accepted trade-off:** local is not fully offline — it needs a dev GCP project
  + `gcloud` ADC. Pub/Sub + Firestore are emulated locally; only secrets (and, on
  GKE, the managed data services) are real.

## Deliverable

`docs/` comparison report:

- The **same k6 scenario** run against each provider namespace; equivalent traces
  shown in each backend UI (screenshots).
- Matrix across axes: trace UX, log↔trace correlation, metrics rendering, ingest
  lag, browser/RUM support (note Dash0 pure-OTel = unsupported path), **session
  replay (Coralogix only, not OTel)**, query/alerting, cost.
- **k6 load generator**, run per namespace. **Cost guard:** bounded RPS +
  duration; collector may apply head/probabilistic sampling for load runs —
  document the rate so comparison is fair.

## Testing

- **App units:** pipeline handlers + the `core.pubsub` inject/extract shim
  (assert `traceparent` survives a publish→consume round-trip) + `core.firestore`
  span emission.
- **End-to-end:** an order produces the expected span tree including Pub/Sub
  publish→consume continuity.
- **CI smoke:** collector with the `file` exporter (+ `debug`); submit an order,
  read the file output, assert span names + parent/child links. No live backend
  credentials in CI; GSM/exporters stubbed.

## Open items / future

- `tail_sampling` processor (hook, not initial scope).
- Per-backend dashboards-as-code where the vendor supports it.
- If a maintained .NET Pub/Sub auto-instr or Google .NET client-library OTel
  tracing ships, retire the `core.pubsub` propagation shim.
