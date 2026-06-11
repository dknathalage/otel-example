# Infra

OpenTofu + Terragrunt for the OTel multi-backend POC. State is local (POC).

## Layout

- `modules/gcp-foundation` — project-level resources: APIs, Artifact Registry,
  GSA + IAM, Workload Identity (WIF) bindings, GSM secret containers, Pub/Sub,
  Firestore. Does **not** create a cluster.
- `modules/gcp-autopilot` — a GKE Autopilot cluster, on its own. Optional.
- `live/foundation` — applies `gcp-foundation`.
- `live/autopilot` — applies `gcp-autopilot`. Optional.

## Configuration

Project and region come from the environment (and `APP_NAME` for the base
resource name); there are no hardcoded project defaults:

```sh
export GCP_PROJECT=my-project
export GCP_REGION=us-central1     # optional, defaults to us-central1
# export APP_NAME=otel-poc        # optional base name for all resources
```

`get_env("GCP_PROJECT")` has no default, so terragrunt fails fast if it is unset.

## Apply order

1. **Always** apply the foundation:

   ```sh
   cd infra/live/foundation
   terragrunt apply
   ```

   The WIF bindings reference KSA principal strings, so they are valid even when
   the target cluster does not exist yet.

2. **Cluster** — pick one:

   - **Create one** with this repo:

     ```sh
     cd infra/live/autopilot
     terragrunt apply
     ```

   - **Use an existing cluster** — skip `live/autopilot` entirely and point your
     kubeconfig at the pre-provisioned cluster (`CLUSTER` defaults to `$APP_NAME`):

     ```sh
     task creds:gke CLUSTER=<existing-cluster>
     ```

3. **Deploy the app** with Helm, once per provider release (see the top-level
   `README.md` for the full build+deploy flow):

   ```sh
   task install PROVIDER=google
   task install PROVIDER=dash0
   task install PROVIDER=coralogix
   ```
