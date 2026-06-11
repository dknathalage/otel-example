# otel-example — multi-backend OpenTelemetry POC

A single auto-instrumented microservice stack (Next.js web + .NET API + .NET
worker, order pipeline over Postgres → Redis → Pub/Sub → Firestore) deployed
three times — once per observability backend (**Google Cloud Observability**,
**Dash0**, **Coralogix**) — so the *same* telemetry can be compared side by side.

This is **bring-your-own-GCP**: you deploy into your own GCP project and cluster,
supply your own backend keys, and nothing in the repo is tied to the author's
project. The base name (`otel-poc`) and project/region are all configurable.

## Prerequisites

- [`gcloud`](https://cloud.google.com/sdk/docs/install), authenticated
  (`gcloud auth login` + `gcloud auth application-default login`)
- [OpenTofu](https://opentofu.org) + [Terragrunt](https://terragrunt.gruntwork.io)
- [Helm](https://helm.sh) and `kubectl`
- [go-task](https://taskfile.dev) (`task`)
- Docker Desktop with **Rosetta amd64 emulation** enabled (GKE nodes are amd64;
  Rosetta — unlike qemu — does not crash .NET's MSBuild when cross-building on an
  arm64 Mac). The .NET apps publish inside the image (multi-stage build).

## Configuration

Everything is driven by a few environment variables — no file editing required
for the common path:

| Variable | Required | Default | Used by |
|----------|----------|---------|---------|
| `GCP_PROJECT` | **yes** | — | tofu (project), Taskfile (registry, `--set gcpProject`) |
| `GCP_REGION` | no | `us-central1` | tofu region, image registry, resource attrs |
| `APP_NAME` | no | `otel-poc` | the single base name for every resource: Artifact Registry repo, GSA, Cloud SQL, Redis, the cluster, the KSA, the Helm namespaces (`<APP_NAME>-<provider>`), release names, and labels |

`APP_NAME` is one knob shared by OpenTofu and Helm. The Workload Identity binding
couples the tofu KSA name/namespace to the chart's service account/namespace, so
they **must** match — deriving both from `APP_NAME` keeps them aligned. Override
individual names via the per-field tofu vars (`cluster_name`, `ksa_name`,
`ksa_namespace_prefix`) or Helm values (`serviceAccountName`, `namespace`,
`gcpServiceAccount`) only if you need them to diverge.

## Deploy

```sh
export GCP_PROJECT=my-project
export GCP_REGION=us-central1        # optional
# export APP_NAME=my-stack           # optional, defaults to otel-poc
```

### 1. Foundation (Artifact Registry, GSA + Workload Identity, GSM secret
containers, Pub/Sub, Firestore, Cloud SQL, Memorystore)

```sh
task apply:foundation
```

The WIF bindings reference KSA principal strings, so they are valid even before
the cluster exists.

### 2. Cluster — pick one

```sh
task apply:autopilot                                   # create a GKE Autopilot cluster
# — or — point kubeconfig at an existing cluster:
task creds:gke CLUSTER=<existing-cluster>              # CLUSTER defaults to $APP_NAME
```

### 3. Seed backend keys into Secret Manager

The foundation created empty GSM secret containers (`dash0-token`,
`coralogix-key`). Push your keys as new versions:

```sh
printf '%s' "$DASH0_TOKEN"   | gcloud secrets versions add dash0-token   --data-file=- --project "$GCP_PROJECT"
printf '%s' "$CORALOGIX_KEY" | gcloud secrets versions add coralogix-key --data-file=- --project "$GCP_PROJECT"
```

(The Google backend uses Workload Identity directly — no key.)

Then edit the per-account values in the overlays (these are account-specific and
cannot be derived):

- `chart/values-dash0.yaml` → `backend.endpoint` (your Dash0 AWS region) and
  `headers.Dash0-Dataset`.
- `chart/values-coralogix.yaml` → your Coralogix `domain`.

### 4. Build, push, and deploy each backend

```sh
task ship PROVIDER=google      # login + build amd64 + push + helm install
task ship PROVIDER=dash0
task ship PROVIDER=coralogix
```

Each release lands in its own namespace `<APP_NAME>-<provider>`. Image registry,
project, region, Cloud SQL connection name, and Redis host are all wired in
automatically (the last two are read from `terragrunt output`).

## Verify (manual test)

For each provider:

```sh
kubectl get pods -n <APP_NAME>-<provider>           # all should be Ready
kubectl logs -n <APP_NAME>-<provider> deploy/collector -f   # look for successful export lines
```

Then exercise the app (open the web UI / call the API via the ingress hosts
`web-<provider>.<host>`, `api-<provider>.<host>`) and confirm telemetry arrives:

- **Google** — traces in Cloud Trace, metrics in Cloud Monitoring, logs in Cloud
  Logging (your project).
- **Dash0** — traces/metrics/logs in the dataset you set in the overlay.
- **Coralogix** — under the application name (defaults to `APP_NAME`).

## Teardown

```sh
helm uninstall <APP_NAME>-google    -n <APP_NAME>-google
helm uninstall <APP_NAME>-dash0     -n <APP_NAME>-dash0
helm uninstall <APP_NAME>-coralogix -n <APP_NAME>-coralogix

cd infra/live/autopilot  && terragrunt destroy   # if you created the cluster
cd infra/live/foundation && terragrunt destroy
```

## Layout

- `src/` — the apps (`Web`, `Api`, `Worker`) and shared `Core.*` .NET libraries.
- `chart/` — the single Helm chart; `values.yaml` is the base, `values-*.yaml`
  are thin per-backend overlays.
- `infra/` — OpenTofu + Terragrunt. `modules/gcp-foundation` (project resources),
  `modules/gcp-autopilot` (optional cluster), `live/*` apply them. See
  `infra/README.md`.
