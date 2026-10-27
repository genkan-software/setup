# Genkan on Kubernetes

```
k8s/
  base/                 namespace, config, migrator Job, gateway / auth / lab / notification (Deployment, Service, HPA, PDB), ingress, network policies
  overlays/keda/        same stack, notification scaled on the RabbitMQ queue length
  secrets.example.yaml  template of every Secret (copy to k8s/secrets.yaml, git-ignored)
  dev-infra.yaml        postgres / redis / rabbitmq as single pods, to try it on kind or minikube
  deploy.sh             namespace -> migrator Job (waits for it) -> services
```

## First deployment

```bash
cp k8s/secrets.example.yaml k8s/secrets.yaml     # change every CHANGE_ME
kubectl apply -f k8s/base/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/dev-infra.yaml              # skip with managed PostgreSQL / Redis / RabbitMQ
k8s/deploy.sh                                    # or: k8s/deploy.sh --keda
```

Pin the images in `k8s/base/kustomization.yaml` (`newTag`) to a tag the workflow published (`sha-1a2b3c4`, `1.4.0`) instead of `latest`.
Private GHCR packages need an `imagePullSecrets` entry (commented in the Deployments).

## How each service scales

| Service | Signal | Replicas | Why |
|---|---|---|---|
| gateway | CPU 70% | 2 - 10 | stateless reverse proxy; the rate-limit buckets live in Redis so all replicas share them |
| auth | CPU 70% | 2 - 8 | stateless (sessions are in Redis); login hashes passwords with PBKDF2, which is CPU-bound |
| lab | CPU 70% | 2 - 6 | stateless (devices, groups and topic subscriptions are in PostgreSQL); replicas share `lab-service` as competing consumers and each publishes the commands and device events it produces |
| notification | CPU 70%, or queue length with `--keda` | 2 - 10 | the RabbitMQ consumers and the HTTP API run in the same pod; replicas share `notification-service` as competing consumers |
| migrator | - | Job, runs once per release | the only thing that changes the database structure |

With `--keda` the notification Deployment is scaled on the number of messages waiting in `notification-service` (50 per replica, plus CPU),
which is the real load of this service. KEDA replaces the HPA of notification; the two never run together.

## What matters with several replicas

- **Lab and notification:** notification never reads devices from the database. Each notification pod asks lab for a snapshot of all devices when it starts (RPC over RabbitMQ), then follows `device.registered` / `device.removed` on its own private queue, and refreshes the snapshot every `LabSync__SnapshotRefreshMinutes` (5). A new pod therefore only consumes notification events once lab has answered; lab being down delays them (they wait in the durable queue) but never loses them. Push commands from lab are executed by exactly one notification pod (`notification-push-commands` is a shared queue). Memory: the cache holds every device token of the system in each notification pod (about 200 bytes per device).
- **Order:** the services assume the tables exist, so the migrator Job must complete before they start. `deploy.sh` does it; with Argo CD or Helm use a PreSync / pre-upgrade hook (annotations in `migrator-job.yaml`). Migrations run while the old pods still serve: keep them backward compatible (add a column first, remove it in a later release).
- **Real client IP:** the gateway runs with `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`. Without it the anonymous rate limit (login) counts the ingress as a single client.
- **Network policy:** auth, lab and notification trust `X-User-Id` / `X-User-Role` from the gateway, so only the gateway may reach them, and the gateway only the ingress controller (`networkpolicy.yaml`, needs a CNI that enforces it; adapt the ingress namespace).
- **Database connections:** every replica has its own Npgsql pool. replicas x `Maximum Pool Size` must stay below PostgreSQL `max_connections` (the secrets template uses 20 per pod); use PgBouncer or a pooler to scale further.
- **Probes:** `/health` (it checks the dependencies) decides readiness only. Liveness is a TCP check (the gateway, which has no dependency, uses `/health`), so a database outage stops traffic instead of restarting every pod. The startup probe leaves 150 s for the first start.
- **Rollouts:** `maxUnavailable: 0`, a `preStop` pause and a PodDisruptionBudget keep at least one pod serving during updates and node drains.
- **No CPU limits** on purpose: they throttle the pods before the autoscaler reacts. Memory limits are set. Autoscaling needs the metrics-server (KEDA: the KEDA operator).
- **Firebase:** `kubectl -n genkan create secret generic firebase-service-account --from-file=firebase.json=secrets/firebase-service-account.json`, then set `Firebase__Enabled: "true"` (and the client ids) in `base/config.yaml`.
