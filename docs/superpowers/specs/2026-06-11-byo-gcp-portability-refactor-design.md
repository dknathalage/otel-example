# BYO-GCP Portability Refactor — Design

**Date:** 2026-06-11
**Status:** Approved (pending spec review)

## Problem

The OTel multi-backend POC is hardcoded to the author's GCP project
(`focal-fossa-dev`). Project id, region, Artifact Registry path, GSA email,
Cloud SQL connection string, and a Memorystore IP (`10.104.117.155`) are baked
into three separate config sites (OpenTofu/Terragrunt inputs, the `Taskfile`,
and the Helm `chart/values.yaml`). A different person cannot deploy the stack to
their own cluster without editing all three by hand, and several values are
*outputs* of `terragrunt apply` that they cannot know in advance.

## Goal

A person with **their own GCP project** clones the repo, sets ~2 values, runs a
documented flow, deploys all three backend releases (Google / Dash0 / Coralogix)
to their cluster, and manually verifies telemetry reaches each backend. No
`focal-fossa-dev` (or any author-specific value) remains anywhere in the repo.

## Scope decisions (from brainstorm)

- **Target deployer:** bring-your-own GCP project. Full managed stack and the
  Google backend are kept. Not targeting vanilla/cloud-free k8s.
- **Key supply:** keys stay in **Google Secret Manager**, seeded via tofu +
  `gcloud`, read by the collector through the GSM provider + Workload Identity.
  No direct-k8s-secret path.
- **Config unification:** **strip hardcoded defaults and document.** No single
  config file, no interactive wizard. Values become explicit (env vars / tofu
  outputs read live), and a top-level README lists every value and the flow.
- **Test:** **manual.** No traffic generator, no k6. "Test" = verify the deploy
  succeeded (pods Ready, collector exporting) and eyeball telemetry in each
  backend UI, documented step by step.

## Hardcoded sites inventory (must all be removed)

| File | Line | Value |
|------|------|-------|
| `infra/live/foundation/terragrunt.hcl` | 10–11 | `project`, `region` |
| `infra/live/autopilot/terragrunt.hcl` | 10–11 | `project`, `region` |
| `chart/values.yaml` | 9 | `gcpProject: focal-fossa-dev` |
| `chart/values.yaml` | 10 | `region: us-central1` |
| `chart/values.yaml` | 30 | `image.registry: …focal-fossa-dev/otel-poc` |
| `chart/values.yaml` | 67 | `gcpServiceAccount: otel-poc@focal-fossa-dev…` |
| `Taskfile.yml` | 15–17 | `REGISTRY`, `PROJECT`, `REGION` defaults |
| `Taskfile.yml` | 20–21 | `CLOUDSQL_CONN`, `REDIS_HOST` defaults |

Relevant existing tofu outputs (already present, to be consumed instead of
hardcoded): `gsa_email`, `artifact_registry`, `cloudsql_connection_name`,
`redis_host`, `redis_port`.

### Base-name (`otel-poc`) pinning inventory

The string `otel-poc` is the project/app identity and is pinned across all three
layers. It is generic (not author-specific) so `otel-poc` stays as the *default*,
but it must become a single configurable knob (§6). Sites:

| File | Detail |
|------|--------|
| `infra/modules/gcp-foundation/main.tf` | AR `repository_id` (28), GSA `account_id` (36), CloudSQL `name` (132), Redis `name`/`display_name` (169–170) — **hardcoded literals**, not even using the existing vars |
| `infra/modules/gcp-foundation/variables.tf` | `cluster_name` (14), `ksa_namespace_prefix` (26), `ksa_name` (32) — already vars, default `otel-poc` |
| `infra/modules/gcp-autopilot/variables.tf` | `cluster_name` (14) default `otel-poc` |
| `infra/live/terragrunt.hcl`, `live/foundation`, `live/autopilot` | `cluster_name = "otel-poc"` inputs |
| `chart/templates/_helpers.tpl` | release-prefix strip default (3), `service.namespace=otel-poc` (24), label `part-of: otel-poc` (47) |
| `chart/templates/ingress.yaml` | `name: otel-poc` (5) |
| `chart/values.yaml` | `serviceAccountName: otel-poc` (66), namespace `otel-poc-google` (7) |
| `chart/values-*.yaml` | `namespace: otel-poc-<provider>` literals; coralogix `appName: otel-poc`, dash0 `Dash0-Dataset: otel-poc` |
| `Taskfile.yml` | `CLUSTER` default (18), release name + `-n` namespace `otel-poc-<provider>` (67, 72) |

## Design

### 1. OpenTofu / Terragrunt — project & region required

In `infra/live/foundation/terragrunt.hcl` and `infra/live/autopilot/terragrunt.hcl`,
replace the literal inputs:

```hcl
project = get_env("GCP_PROJECT")
region  = get_env("GCP_REGION", "us-central1")
```

`get_env("GCP_PROJECT")` with no default makes terragrunt fail fast if the env
var is unset. (Implementation: confirm `infra/live/autopilot/terragrunt.hcl` has
the same literal `project`/`region` at lines 10–11 before applying the identical
edit — pattern is expected but verify.) `cluster_name`, `releases`, and `create_firestore` stay as literal
inputs (sane shared defaults, not author-specific). Module `variables.tf` files
are unchanged — `project` is already a required variable; `region` keeps its
`us-central1` default (a real region, not author-specific).

### 2. Taskfile — read tofu outputs, drop literal defaults

- `PROJECT` / `REGION`: drop the `| default "focal-fossa-dev…"`; they come from
  the environment (the same `GCP_PROJECT` / `GCP_REGION` the deployer exports for
  tofu) or an explicit CLI override.
- `REGISTRY`, `CLOUDSQL_CONN`, `REDIS_HOST`: stop hardcoding. Read live from the
  foundation state, e.g.

  ```yaml
  REGISTRY:      { sh: "cd infra/live/foundation && terragrunt output -raw artifact_registry" }
  CLOUDSQL_CONN: { sh: "cd infra/live/foundation && terragrunt output -raw cloudsql_connection_name" }
  REDIS_HOST:    { sh: "cd infra/live/foundation && terragrunt output -raw redis_host" }
  ```

  After `task apply:foundation`, `task install` / `task ship` auto-discover these
  — no manual entry, no stale IP. (These `sh` lookups run when the Taskfile is
  parsed; they require the foundation to be applied first, which the documented
  flow guarantees. If unapplied, the task fails with a clear terragrunt error.)

  **Cold-clone footgun:** because the lookups are parse-time, *any* task that
  references these vars fails before the foundation exists — including
  `task build`/`task images` (they use `REGISTRY`), which a reader may expect to
  "just build". Mitigation: keep `REGISTRY` derived from `GCP_PROJECT`/`GCP_REGION`
  env (`<region>-docker.pkg.dev/<project>/otel-poc`) rather than from
  `terragrunt output` — registry path is deterministic from project+region, so it
  needs no applied state. Only `CLOUDSQL_CONN` and `REDIS_HOST` (true runtime
  outputs) come from `terragrunt output`, and only `install`/`ship` reference
  them. Document per-task what each requires.

### 3. Helm chart — placeholders + derived GSA

- `chart/values.yaml`: blank out `gcpProject`, `region`, `image.registry`, and
  `gcpServiceAccount`, each with a comment that it is supplied at install time
  via `--set` (or a private values file). Overlays `values-*.yaml` are unchanged
  apart from the documented endpoint edits (see §4).
- Derive the GSA in `chart/templates/_helpers.tpl`: a helper that renders
  `<serviceAccountName>@<gcpProject>.iam.gserviceaccount.com` so the deployer
  only ever sets `gcpProject`. The literal email is removed. `serviceAccountName`
  defaults to `appName` (§6) — the tofu `ksa_name` the WIF binding targets, which
  also derives from the same base name, so they stay aligned by construction.
- The `install` task gains `--set` flags fed from env / tofu outputs:
  `appName`, `gcpProject`, `region`, `image.registry`,
  `components.api.cloudsql.connectionName`, `components.api.redis.host`. The
  blanked `values.yaml` literals are therefore never relied on at deploy time;
  they exist only as documented placeholders.

### 4. Keys — GSM seeding, documented

GSM stays. The foundation module already creates empty secret containers; the
deployer pushes their own key versions. Document the exact commands, e.g.:

```sh
printf '%s' "$DASH0_TOKEN"     | gcloud secrets versions add dash0-token    --data-file=- --project "$GCP_PROJECT"
printf '%s' "$CORALOGIX_KEY"   | gcloud secrets versions add coralogix-key  --data-file=- --project "$GCP_PROJECT"
```

(Exact secret names are taken from the foundation module at implementation time.)
Call out that **per-account values live in the overlays**, not GSM, and must be
edited by the deployer:

- `values-dash0.yaml` → `backend.endpoint` (their Dash0 AWS region) and
  `headers.Dash0-Dataset`.
- `values-coralogix.yaml` → their Coralogix `domain`.

### 5. Top-level README — the entry doc

New `README.md` at repo root. Sections:

1. **What this is** — one paragraph: multi-backend OTel POC, BYO-GCP.
2. **Prerequisites** — `gcloud` (authenticated), `tofu`, `terragrunt`, `helm`,
   Docker Desktop with Rosetta amd64 emulation, `go-task`.
3. **Deploy flow** (numbered):
   1. `export GCP_PROJECT=… GCP_REGION=…` (optional `APP_NAME=…` to rename
      everything from the default `otel-poc`)
   2. `task apply:foundation`
   3. Cluster: `task apply:autopilot` **or** `task creds:gke CLUSTER=…`
   4. Seed keys (gcloud commands) + edit overlay endpoints (§4)
   5. `task ship PROVIDER=google` (repeat for `dash0`, `coralogix`)
4. **Manual verification** ("test"): `kubectl get pods -n otel-poc-<provider>`
   (all Ready), tail the collector pod logs for successful export lines, then
   open each backend UI and confirm traces/metrics/logs arrive — with a note on
   what to look for per backend.
5. **Teardown:** `helm uninstall otel-poc-<provider> -n …` then
   `terragrunt destroy` in `live/autopilot` (if used) and `live/foundation`.

### 6. Single base-name knob — names controllable from config

Today `otel-poc` is the app/project identity, pinned across all three layers (see
the base-name inventory above) and partly hardcoded in tofu rather than even using
the existing vars. Introduce **one base-name knob** that all three layers derive
from; keep the already-separate per-field vars as optional fine-grained overrides.
`otel-poc` stays the default (generic, not author-specific), so existing behaviour
is unchanged unless the deployer overrides it.

**The knob:** `APP_NAME` env var → tofu `name`, Helm `appName`, Taskfile
`APP_NAME`. The SAME value must reach all three (the WIF binding couples tofu
`ksa_name`/`ksa_namespace_prefix` to chart `serviceAccountName`/namespace; a
mismatch breaks Workload Identity). Deriving them all from one value enforces this
by construction.

**OpenTofu (`gcp-foundation`):**
- Add `variable "name" { default = "otel-poc" }`.
- Wire the four hardcoded literals to `var.name`: AR `repository_id`, GSA
  `account_id`, CloudSQL instance `name`, Redis `name`/`display_name`.
- Existing override vars `cluster_name`, `ksa_name`, `ksa_namespace_prefix`: change
  their default from `"otel-poc"` to `""` and coalesce to the base name via a local,
  e.g. `local.cluster_name = coalesce(var.cluster_name, var.name)`. Empty → derive;
  set → override. Use the locals everywhere those names are referenced.
- `gcp-autopilot`: add the same `name` var + `cluster_name` coalesce local.
- `infra/live/terragrunt.hcl` (shared root inputs): set
  `name = get_env("APP_NAME", "otel-poc")` once so foundation and autopilot agree.
  Remove the literal `cluster_name = "otel-poc"` inputs (the module now derives it).

**Helm chart:**
- Add top-level `appName` value (default `otel-poc`).
- `_helpers.tpl`: release-prefix strip uses `appName` (replace the
  `nameOverride | default "otel-poc"` literal; keep `nameOverride` as an override).
  `service.namespace=<appName>`; label `part-of: <appName>`.
- `ingress.yaml`: `name: {{ .Values.appName }}`.
- `serviceAccountName` defaults to `appName` (coalesce in template; remove the
  literal).
- Drop the literal `namespace:` from `values.yaml` and every `values-*.yaml`. The
  `otel-stack.namespace` helper already falls back to `.Release.Namespace`, and the
  Taskfile installs with `-n <APP_NAME>-<PROVIDER>` — so the namespace follows the
  install target with no duplicated literal to drift. (Coralogix `appName` and
  Dash0 `Dash0-Dataset` overlay values fold into the chart `appName` / become
  documented overlay edits.)

**Taskfile:**
- Add `APP_NAME` var (default `otel-poc`).
- `CLUSTER` defaults to `{{.APP_NAME}}`.
- Release name and `-n` namespace become `{{.APP_NAME}}-{{.PROVIDER}}`.
- `REGISTRY` (env-derived, per §2) becomes
  `<region>-docker.pkg.dev/<project>/{{.APP_NAME}}`.
- `install`/`ship` pass `--set appName={{.APP_NAME}}`.

## Out of scope (YAGNI)

- Vanilla-k8s / in-cluster Postgres·Redis·Pub/Sub·Firestore path.
- Traffic generation / k6 load scenario.
- Single root config file or interactive bootstrap wizard.

## Acceptance

- `grep -rn focal-fossa-dev` over the repo (excluding tofu caches/state) returns
  nothing.
- A reader following only `README.md`, with their own GCP project, can deploy all
  three releases and reach the manual-verification step.
- `task ship PROVIDER=google` works with only `GCP_PROJECT` / `GCP_REGION`
  exported and the foundation applied — no other manual value entry.
- Setting `APP_NAME=foo` renames every resource consistently — tofu AR repo / GSA
  / CloudSQL / Redis / cluster / KSA, chart namespace / service account / labels /
  ingress, and Taskfile release+namespace — with WIF still binding. Unset →
  everything stays `otel-poc`. No remaining hardcoded `otel-poc` literal that
  ignores the knob.
