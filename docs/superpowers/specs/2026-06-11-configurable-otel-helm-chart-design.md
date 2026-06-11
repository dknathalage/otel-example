# Configurable OTel Helm Chart — Design

**Date:** 2026-06-11
**Status:** Approved (pending spec review)

## Problem

The current chart (`deploy/helm/otel-poc`) hardcodes backend (collector exporter) logic
in template `if/else` branches keyed off a `provider` string, mixes a now-dead
`env: local|gke` switch into the collector config, and exposes per-provider knobs
inconsistently (some in `providers.*`, some baked into template literals). It is not
positioned as a reusable chart, and component (api/worker/web/collector) settings are
not uniformly configurable.

## Goals

1. **Add a backend easily** — a new vendor on the same wire protocol (OTLP/HTTP) is pure
   values; a genuinely new exporter protocol is a single template branch.
2. **One backend per release** — each release exports to exactly one backend (the
   per-provider-namespace directive). No fan-out within a release.
3. **Clean per-component config** — api/worker/web/collector each expose
   enabled/image/replicas/resources uniformly, plus their component-specific blocks.
4. **Reusable chart** — relocate to repo-root `/chart`, GKE as the baseline.
5. **Per-provider namespaces** — each backend overlay targets its own namespace
   (`otel-google`, `otel-dash0`, `otel-coralogix`); a values file is self-contained
   (points to its backend AND its namespace).
6. **Secrets in IaC** — backend credentials live in Google Secret Manager, provisioned
   by OpenTofu/Terragrunt, never by Helm.

## Non-Goals

- Multi-backend fan-out within one release.
- Local/kind support (already dropped).
- Splitting the microservice set across clusters in one release (a release = full set →
  one namespace; deploy many releases for many targets).
- Non-GCP secret backends (`k8s` secret source) — GSM-only, since everything is
  GKE + Workload Identity.

## Deployment Model

One chart deploys the **full set** (api + worker + web + collector) into **one
namespace**. Install it **many times** — once per backend/namespace target. Within a
release everything shares one project/region/namespace/backend. The install name is the
backend key (`google`/`dash0`/`coralogix`) so existing release-keyed helpers
(`orders-<release>`, `orders_<release>` db, `<release>:` prefix) and the per-release
Pub/Sub topics provisioned in tofu line up automatically.

```
helm install dash0 ./chart -f chart/values-dash0.yaml -n otel-dash0 --create-namespace
helm install coralogix ./chart -f chart/values-coralogix.yaml -n otel-coralogix --create-namespace
helm install google ./chart -n otel-google --create-namespace   # base values = google
```

## Approach (chosen: flat chart)

A single flat chart — no subcharts, no umbrella. Templates select the one backend by
`backend.type` and read uniform component keys from a `components.<name>` map via
helpers. Chosen over umbrella/subcharts and library-chart approaches because the set is
always deployed together to one namespace, so subchart value plumbing buys nothing.

## Layout

```
/chart/
  Chart.yaml              # name: otel-stack
  values.yaml             # GKE defaults; backend: googleAuthOtlp; namespace: otel-google
  values-dash0.yaml       # backend: otlphttp (dash0) ; namespace: otel-dash0
  values-coralogix.yaml   # backend: coralogix        ; namespace: otel-coralogix
  templates/
    _helpers.tpl
    serviceaccount.yaml
    collector.yaml
    collector-configmap.yaml
    api.yaml  worker.yaml  web.yaml
    ingress.yaml
    cloudsql-secret.yaml
```

`git mv deploy/helm/otel-poc chart`, then rename + refactor. `values-gke.yaml` is
deleted — GKE is the baseline, folded into `values.yaml` (`resourcedetection/gcp` always
on, Workload Identity SA, ingress class, GSM confmap provider). The `env: local|gke`
switch is removed from values and the collector template.

## Values Schema

```yaml
# ── Release target (per-install) ──
nameOverride: ""
namespace: ""              # rendered into every resource's metadata.namespace;
                           # falls back to .Release.Namespace when empty
gcpProject: ""
region: ""                 # used in resource attrs + endpoint templating (tpl)

# ── Backend: the ONE backend this release exports to ──
backend:
  type: googleAuthOtlp     # googleAuthOtlp | otlphttp | coralogix
  endpoint: https://telemetry.googleapis.com
  # otlphttp-only:
  # headers: { Dash0-Dataset: otel-poc }
  # auth: { header: Authorization, scheme: Bearer, secretRef: dash0-token }
  # coralogix-only:
  # domain: eu2.coralogix.com
  # appName: otel-poc
  # auth: { secretRef: coralogix-key }

# ── Collector ──
collector:
  enabled: true
  image: us-docker.pkg.dev/cloud-ops-agents-artifacts/google-cloud-opentelemetry-collector/otelcol-google:0.151.0
  debug: false
  pipelines: [traces, metrics, logs]
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { cpu: 500m, memory: 512Mi }

# ── Components: uniform common keys + component-specific blocks ──
components:
  api:
    enabled: true
    image: { registry: otel-poc, repo: api, tag: dev }
    replicas: 1
    resources: {}
    cloudsql: { connectionName: "", user: otel, password: "" }
    redis:    { host: "", port: 6379 }
    pubsub:   { enabled: true }
  worker:
    enabled: true
    image: { registry: otel-poc, repo: worker, tag: dev }
    replicas: 1
    resources: {}
  web:
    enabled: true
    image: { registry: otel-poc, repo: web, tag: dev }
    replicas: 1
    resources: {}
    apiUrl: "http://localhost/api"
    otlpHttpUrl: "http://localhost/otlp/v1/traces"

# ── Ingress / browser ──
ingress:
  enabled: true
  className: ""
  host: localhost
webOrigin: "http://localhost:3000"

gcpServiceAccount: ""       # GSA email bound to KSA via Workload Identity
```

## Backend Rendering (collector-configmap)

The template switches on `backend.type` — three known exporter shapes:

- **`googleAuthOtlp`** → `otlphttp/be` with `googleclientauth` extension + auto-adds the
  `resource/gcp` and `resourcedetection/gcp` processors and the `googleclientauth`
  service extension.
- **`otlphttp`** → `otlphttp/be` with `endpoint` (rendered through `tpl` so it can embed
  `{{ .Values.region }}`), optional `headers`, and optional bearer auth where
  `auth.secretRef` resolves to a GSM reference
  `${googlesecretmanager:projects/<gcpProject>/secrets/<secretRef>/versions/latest}`.
- **`coralogix`** → native `coralogix` exporter with `domain`, `application_name`,
  `subsystem_name: ${env:HOSTNAME}`, and `private_key` from the GSM reference.

Adding a vendor on OTLP/HTTP (e.g. Grafana Cloud) = a new overlay file, zero template
edits. A genuinely new exporter protocol = one new `backend.type` branch.

## Namespace Pinning

Every rendered resource sets:

```yaml
metadata:
  namespace: {{ .Values.namespace | default .Release.Namespace }}
```

so a values file pins its own namespace. Overlays set `namespace: otel-<backend>`. The
matching `-n` on the install keeps Helm's release storage in the same namespace.

## Component Templates

Components keep **separate template files** (their pod specs genuinely differ — api has
the cloud-sql-proxy sidecar + redis + pubsub env, web has browser-facing URLs), not a
generic deployment loop. The `components.<name>` map only unifies the common keys
(enabled/image/replicas/resources) read via a shared helper. Each component template is
wrapped in `{{- if .Values.components.<name>.enabled }}`. Image reference becomes
`{{ .registry }}/{{ .repo }}:{{ .tag }}` per component.

## Helpers (`_helpers.tpl`)

Reworked from the `otel-poc.*` prefix to `otel-stack.*`. Retain the release-keyed
derivations (already correct): `topic` → `orders-<release>`, `subscription` →
`orders-<release>-sub`, `pgdb` → `orders_<release>`, `prefix` → `<release>:`. Replace the
`provider` label with `backend.type`. Add an `image` helper taking a component's image
block, and a `secretRef` helper that builds the GSM confmap reference from `gcpProject` +
a secret name.

## Secrets (OpenTofu / Terragrunt)

GSM secret **containers** already exist in `gcp-foundation` (`dash0-token`,
`coralogix-key`). Add the **versions** so credentials are fully IaC-managed:

```hcl
variable "dash0_token"   { type = string, sensitive = true, default = "" }
variable "coralogix_key" { type = string, sensitive = true, default = "" }

resource "google_secret_manager_secret_version" "dash0_token" {
  count       = var.dash0_token == "" ? 0 : 1
  secret      = google_secret_manager_secret.dash0_token.id
  secret_data = var.dash0_token
}
resource "google_secret_manager_secret_version" "coralogix_key" {
  count       = var.coralogix_key == "" ? 0 : 1
  secret      = google_secret_manager_secret.coralogix_key.id
  secret_data = var.coralogix_key
}
```

Values supplied via `TF_VAR_dash0_token` / `TF_VAR_coralogix_key` (or a sops/gitignored
tfvars) — never committed plaintext. `count`-skip keeps the apply clean before a token is
available. The collector reads them at runtime via the `googlesecretmanager` confmap
provider under Workload Identity. The chart references secret **names** only.

## Migration Steps

1. `git mv deploy/helm/otel-poc chart`; rename `Chart.yaml` name → `otel-stack`.
2. Delete `values-gke.yaml`; fold GKE defaults into `values.yaml`.
3. Rewrite `values.yaml` to the schema above; add `values-dash0.yaml`,
   `values-coralogix.yaml`.
4. Rewrite `collector-configmap.yaml` with the `backend.type` switch + `tpl` endpoint;
   drop the `env`/`provider` conditionals.
5. Add `metadata.namespace` to every resource template.
6. Convert `api.yaml`/`worker.yaml`/`web.yaml` to read `components.<name>.*` with
   `enabled` guards and the per-component image block.
7. Rework `_helpers.tpl` (`otel-stack.*`, image + secretRef helpers, backend-type label).
8. Add `secret_manager_secret_version` resources + sensitive vars in `gcp-foundation`.
9. Update `Taskfile.yml` / deploy commands referencing the old chart path and the
   removed `--set env=...` / `--set provider=...` flags.

## Testing / Verification

- `helm template ./chart` for each of the three value sets renders valid manifests
  (no unresolved templates, correct namespace, correct single exporter per release).
- `helm lint ./chart`.
- `tofu validate` / `terragrunt validate` on `gcp-foundation` after adding the version
  resources.
- A `--set components.web.enabled=false` render omits the web Deployment/Service only.
```
