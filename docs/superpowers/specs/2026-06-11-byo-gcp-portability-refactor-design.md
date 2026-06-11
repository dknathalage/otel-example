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

## Design

### 1. OpenTofu / Terragrunt — project & region required

In `infra/live/foundation/terragrunt.hcl` and `infra/live/autopilot/terragrunt.hcl`,
replace the literal inputs:

```hcl
project = get_env("GCP_PROJECT")
region  = get_env("GCP_REGION", "us-central1")
```

`get_env("GCP_PROJECT")` with no default makes terragrunt fail fast if the env
var is unset. `cluster_name`, `releases`, and `create_firestore` stay as literal
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

### 3. Helm chart — placeholders + derived GSA

- `chart/values.yaml`: blank out `gcpProject`, `region`, `image.registry`, and
  `gcpServiceAccount`, each with a comment that it is supplied at install time
  via `--set` (or a private values file). Overlays `values-*.yaml` are unchanged
  apart from the documented endpoint edits (see §4).
- Derive the GSA in `chart/templates/_helpers.tpl`: a helper that renders
  `<serviceAccountName>@<gcpProject>.iam.gserviceaccount.com` so the deployer
  only ever sets `gcpProject`. The literal email is removed. `serviceAccountName`
  stays pinned to `otel-poc` (the tofu `ksa_name` the WIF binding targets).
- The `install` task gains `--set` flags fed from env / tofu outputs:
  `gcpProject`, `region`, `image.registry`, `components.api.cloudsql.connectionName`,
  `components.api.redis.host`. The blanked `values.yaml` literals are therefore
  never relied on at deploy time; they exist only as documented placeholders.

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
   1. `export GCP_PROJECT=… GCP_REGION=…`
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
