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
   (`otel-poc-google`, `otel-poc-dash0`, `otel-poc-coralogix` — the **existing**
   `ksa_namespace_prefix`-`<release>` scheme the Workload Identity bindings already use);
   a values file is self-contained (points to its backend AND its namespace).
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
release everything shares one project/region/namespace/backend.

The install (release) name stays `otel-poc-<backend>` and the deploy namespace stays
`otel-poc-<backend>` — the **existing** convention the tofu Workload Identity binding
(`otel-poc-<release>/otel-poc`), the per-release Pub/Sub topics (`for_each` over
`releases`), and the `otel-poc.release` helper (which trims the `otel-poc-` prefix to get
`<backend>`) all already depend on. The release-keyed helpers
(`orders-<backend>`, `orders_<backend>` db, `<backend>:` prefix) line up automatically.
**Do not** invent a new `otel-<backend>` namespace scheme — it would break WIF and every
pod's GCP auth.

```
helm upgrade --install otel-poc-dash0 ./chart -f chart/values-dash0.yaml \
  -n otel-poc-dash0 --create-namespace
helm upgrade --install otel-poc-coralogix ./chart -f chart/values-coralogix.yaml \
  -n otel-poc-coralogix --create-namespace
helm upgrade --install otel-poc-google ./chart \
  -n otel-poc-google --create-namespace          # base values = google
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
  values.yaml             # GKE defaults; backend: googleAuthOtlp; namespace: otel-poc-google
  values-dash0.yaml       # backend: otlphttp (dash0) ; namespace: otel-poc-dash0
  values-coralogix.yaml   # backend: coralogix        ; namespace: otel-poc-coralogix
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
nameOverride: ""           # overrides the chart name inside the fullname/release helper
namespace: ""              # rendered into every resource's metadata.namespace; falls back
                           # to .Release.Namespace when empty. MUST equal the install -n.
gcpProject: ""
region: us-central1        # GCP region — resource attributes only. NOT the dash0 AWS
                           # region (that lives literally in backend.endpoint below).

# ── Backend: the ONE backend this release exports to ──
# endpoint is a full literal URL (no tpl/region interpolation) — keeps the dash0 AWS
# region out of the GCP `region` value above.
backend:
  type: googleAuthOtlp     # googleAuthOtlp | otlphttp | coralogix
  endpoint: https://telemetry.googleapis.com
  # otlphttp-only (e.g. dash0 — note AWS region us-west-2 baked into the host):
  # endpoint: https://ingress.us-west-2.aws.dash0.com
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

# ── Image defaults (global) ── keeps the CI `--set image.tag=<git-sha>` flow working.
# Per-component blocks supply only `repo`; registry/tag inherit unless overridden.
image:
  registry: otel-poc        # local: otel-poc ; GKE: <region>-docker.pkg.dev/<proj>/otel-poc
  tag: dev

# ── Components: uniform common keys + component-specific blocks ──
# The image helper renders <registry>/<repo>:<tag>, with optional per-component
# registry/tag overrides falling back to the global `image` block above.
components:
  api:
    enabled: true
    image: { repo: api }        # registry+tag inherit global image.*
    replicas: 1
    resources: {}
    cloudsql: { connectionName: "", user: otel, password: "" }
    redis:    { host: "", port: 6379 }
    pubsub:   { enabled: true }
  worker:
    enabled: true
    image: { repo: worker }
    replicas: 1
    resources: {}
  web:
    enabled: true
    image: { repo: web }
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

# ── Workload Identity ──
# KSA name is PINNED to `otel-poc` (the tofu `ksa_name` the WIF binding targets) — it is
# NOT derived from the chart/release name. gcpServiceAccount is the GSA email annotated
# onto the KSA; the annotation is always rendered (the old env=local|gke guard is gone).
serviceAccountName: otel-poc
gcpServiceAccount: ""
```

## Backend Rendering (collector-configmap)

The template switches on `backend.type` — three known exporter shapes:

- **`googleAuthOtlp`** → `otlphttp/be` with the `googleclientauth` service extension,
  plus the `resource/gcp` and `resourcedetection/gcp` processors. These two processors go
  on the **traces and metrics** pipelines only (the logs pipeline keeps just `batch`,
  matching current behavior). `resourcedetection/gcp` is now always on for this backend
  type (the old `env=gke` guard is removed).
- **`otlphttp`** → `otlphttp/be` with the literal `endpoint`, optional `headers`, and
  optional bearer auth where `auth.secretRef` resolves to a GSM reference
  `${googlesecretmanager:projects/<gcpProject>/secrets/<secretRef>/versions/latest}`.
  The endpoint is used **as a literal** (no `tpl`/region interpolation).
- **`coralogix`** → native `coralogix` exporter with `domain`, `application_name`,
  `subsystem_name: ${env:HOSTNAME}`, and `private_key` from the GSM reference.

The `${googlesecretmanager:...}` and `${env:HOSTNAME}` tokens are **collector runtime
references**, not Helm values — the `secretRef` helper emits the literal `${...}` and
that output must NOT be passed through `tpl` (Helm leaves `$` alone, but double-rendering
would mangle it).

Pipeline processors per backend type:

| pipeline | googleAuthOtlp            | otlphttp / coralogix |
|----------|--------------------------|----------------------|
| traces   | batch, resource/gcp, resourcedetection/gcp | batch |
| metrics  | batch, resource/gcp, resourcedetection/gcp | batch |
| logs     | batch                    | batch |

(`debug` exporter is prepended to every pipeline's exporter list when `collector.debug`.)

Adding a vendor on OTLP/HTTP (e.g. Grafana Cloud) = a new overlay file, zero template
edits. A genuinely new exporter protocol = one new `backend.type` branch.

## Namespace Pinning

Every rendered resource sets:

```yaml
metadata:
  namespace: {{ .Values.namespace | default .Release.Namespace }}
```

so a values file pins its own namespace. Overlays set `namespace: otel-poc-<backend>`.
The install **must** pass the matching `-n otel-poc-<backend>` — Helm rejects a manifest
whose `metadata.namespace` differs from the release namespace, so the two must always
agree. The redundancy is intentional: it makes the values file self-documenting and keeps
the namespace aligned with the tofu WIF binding.

## Component Templates

Components keep **separate template files** (their pod specs genuinely differ — api has
the cloud-sql-proxy sidecar + redis + pubsub env, web has browser-facing URLs), not a
generic deployment loop. The `components.<name>` map only unifies the common keys
(enabled/image/replicas/resources) read via a shared helper. Each component template is
wrapped in `{{- if .Values.components.<name>.enabled }}`. The image helper renders
`<registry>/<repo>:<tag>`, taking `repo` from the component block and `registry`/`tag`
from the global `image` block unless the component overrides them.

`cloudsql-secret.yaml` is gated on `components.api.enabled` (only the api needs Postgres)
and reads the password from `components.api.cloudsql.password`. `api.yaml` reads
`connectionName`/`user`/`password` from `components.api.cloudsql.*` and references the
`cloudsql` k8s secret by name as today.

## Helpers (`_helpers.tpl`)

Reworked from the `otel-poc.*` prefix to `otel-stack.*`. Retain the release-keyed
derivations (already correct): the `release` helper trims the `otel-poc-` prefix (or
`nameOverride` when set) from `.Release.Name`; `topic` → `orders-<release>`,
`subscription` → `orders-<release>-sub`, `pgdb` → `orders_<release>`, `prefix` →
`<release>:`. Replace the `provider` label with `backend.type`. Add:
- an **`image`** helper: `(<component>.image.registry | default .Values.image.registry)/
  <component>.image.repo:(<component>.image.tag | default .Values.image.tag)`.
- a **`secretRef`** helper: emits the literal
  `${googlesecretmanager:projects/<gcpProject>/secrets/<name>/versions/latest}`.

The KSA name is the constant `otel-poc` (via `.Values.serviceAccountName`), **not** the
release/name helper — the WIF binding targets it by that exact name.

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
3. Rewrite `values.yaml` to the schema above (global `image` block, `backend`,
   `components`, `namespace`, `serviceAccountName`); add `values-dash0.yaml`,
   `values-coralogix.yaml` (each pins `backend` + `namespace: otel-poc-<backend>`).
4. Rewrite `collector-configmap.yaml` with the `backend.type` switch and the
   per-pipeline processor table; drop the `env`/`provider` conditionals. Endpoint is
   literal (no `tpl`).
5. Add `metadata.namespace: {{ .Values.namespace | default .Release.Namespace }}` to
   every resource template (api, worker, web, collector, configmap, serviceaccount,
   ingress, cloudsql-secret).
6. Convert `api.yaml`/`worker.yaml`/`web.yaml` to read `components.<name>.*` with
   `enabled` guards and the `image` helper.
7. Update `cloudsql-secret.yaml`: gate on `components.api.enabled`, read password from
   `components.api.cloudsql.password`.
8. Rewrite `serviceaccount.yaml`: KSA name pinned to `.Values.serviceAccountName`
   (`otel-poc`), drop the `env=gke` guard so the
   `iam.gke.io/gcp-service-account: {{ .Values.gcpServiceAccount }}` annotation is always
   rendered.
9. Rework `_helpers.tpl` (`otel-stack.*`, `image` + `secretRef` helpers, `backend.type`
   label, `release` helper trimming `otel-poc-`/`nameOverride`).
10. Add `google_secret_manager_secret_version` resources + sensitive `dash0_token` /
    `coralogix_key` vars in `gcp-foundation` (`count`-skip when empty).
11. Rewrite `Taskfile.yml`: the `install` task currently references a **deleted**
    `values-local.yaml` and `--set provider=`/`--set image.tag=` against the old schema.
    Replace with one install per backend overlay using the new path/namespace and the
    global `--set image.tag={{.TAG}}` (still valid — image tag stayed global). Drop the
    `kind-load` task (kind path gone). Keep the `TAG=git-sha` CI flow.

## Testing / Verification

- `helm template ./chart` for each of the three value sets renders valid manifests
  (no unresolved templates, correct namespace, correct single exporter per release).
- `helm lint ./chart`.
- `tofu validate` / `terragrunt validate` on `gcp-foundation` after adding the version
  resources.
- A `--set components.web.enabled=false` render omits the web Deployment/Service only.
```
