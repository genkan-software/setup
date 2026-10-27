# Genkan – API Gateway, Auth, Notification

```
clients ──HTTP──▶ gateway ──▶ auth          (Redis sessions)
                     ├──────▶ lab           (devices, device groups, topic subscriptions, push endpoints)
                     └──────▶ notification  (notification log, FCM sender)
        both use the same PostgreSQL database, created and migrated by the one-shot `migrator` container
                                  ▲
        RabbitMQ topic exchange "workplace.events" ─ queue "notification-service"
        bindings: booking.#  access.#  visitor.#  alert.#   (dead-letter: workplace.events.dlx)

lab ──▶ RabbitMQ exchange "genkan.lab" ──▶ notification     push commands, device events (see *Lab service*)
lab ◀── RabbitMQ exchange "genkan.lab" ◀── notification     snapshot request, dead device tokens
```

One PostgreSQL database, configured only by the connection string (no schema name is imposed). Only `Genkan.Migrator` creates or alters tables; the services just read and write them (see *Database*).
Only the gateway is published on the host. Services trust the `X-User-*` headers set by the gateway
(it strips client-supplied ones), so never expose `auth` / `notification` directly.

## Repositories

One repo per service. This repo (**genkan-setup**) is the dev workspace: each service is a git submodule under `src/`, plus the compose files and Kubernetes manifests.

```
genkan-setup/
  src/
    shared/         -> genkan-shared        NuGet package Genkan.Shared (GitHub Packages)
    gateway/        -> genkan-gateway       Docker image ghcr.io/genkan-software/genkan-gateway
    auth/           -> genkan-auth          Docker image ghcr.io/genkan-software/genkan-auth
    notification/   -> genkan-notification  Docker image ghcr.io/genkan-software/notification
    migrator/       -> migrator      Docker image ghcr.io/software/migrator
  docker-compose.yml        dev: builds from src/*
  docker-compose.prod.yml   prod: pulls the published images
  k8s/                      kustomize manifests + deploy.sh
  scripts/                  push-all (one-time), bootstrap, update-submodules, pin-images
```

Services depend on Shared only through the NuGet package (`Genkan.Shared`, pinned version in each csproj; Dependabot bumps it).
Each service is layered as before: `Api -> Application, Domain, Infrastructure` (Notification: `Api -> Application, Rabbit`, `Application -> Infrastructure, Firebase, Domain`).

## Releases

1. **Shared**: in `shared`, `git tag vX.Y.Z && git push --tags` -> package published. Bump the consumers (Dependabot PRs).
2. **Services**: in this repo, `scripts/update-submodules.sh`, commit, then `git tag vX.Y.Z && git push --follow-tags`.
   The `release-services` workflow creates a release `vX.Y.Z` in gateway, auth, notification and migrator at the commit pinned here
   (not in shared), and each repo's `docker-publish` workflow builds `ghcr.io/software/<service>:X.Y.Z`.
3. Deploy: `scripts/pin-images.sh X.Y.Z && k8s/deploy.sh`.

Org notes (genkan-software): Settings > Actions > General > Workflow permissions = read and write; fine-grained PATs must be allowed for the org and created with the org as resource owner.

Secrets: `RELEASE_TOKEN` on this repo (fine-grained PAT, Contents read/write on the four service repos; a tag made with the default token would not trigger their workflows).
`PACKAGES_TOKEN` on each service repo only if the default token cannot read the Genkan.Shared package.

First time: create the six empty repos in the genkan-software org on GitHub (shared, -gateway, -auth, -notification, -migrator, -setup), then run `scripts/push-all.sh` (git only, no gh needed): it pushes each folder of this workspace and records them as submodules. Later: `git clone --recurse-submodules` or `scripts/bootstrap.sh`.

## Run

```bash
cp .env.example .env        # then edit the secrets
export GITHUB_PACKAGES_TOKEN=ghp_xxx   # read:packages (restore Genkan.Shared)
docker compose up -d --build postgres redis rabbitmq migrator auth notification gateway
```

Gateway: http://localhost:8080 · RabbitMQ UI: http://localhost:15672 · OpenAPI (inside the network): `/openapi/v1.json` on each service · Combined Swagger UI: http://localhost:8080/swagger when `SWAGGER_ENABLED=true` (see *Swagger*).

## Endpoints (all through the gateway)

| Method | Path | Access |
|---|---|---|
| GET | `/health`, `/auth/health`, `/lab/health`, `/notifications/health` | public |
| POST | `/auth/login` `{email,password}` → `{token, expiresAt, user}` | public, 10/min/IP |
| GET | `/auth/session` | bearer token |
| POST | `/auth/logout` | bearer token |
| POST | `/auth/users` `{email,displayName,password,role}` | Admin |
| GET | `/notifications/me` | any user (own + broadcast alerts) |
| GET | `/notifications/users/{userId}` | Admin |
| GET | `/notifications/logs?userId=&type=&status=&page=&pageSize=` | Admin |
| POST | `/notifications/alerts` `{title,message}` → publishes `alert.broadcast` | Admin |
| POST | `/lab/devices` `{token,platform}` (`android`\|`ios`\|`web`) → registers the device's FCM token | any user |
| POST | `/lab/devices/unregister` `{token}` (call on logout) | any user |
| GET | `/notifications/firebase-config` → `{apiKey, applicationId, messagingSenderId, projectId}` (public client identifiers, never the service-account key) | any user |
| POST | `/lab/push/individual` `{userId \| token, message}` | Admin |
| POST | `/lab/push/multicast` `{userIds, tokens, message}` | Admin |
| GET | `/lab/push/groups` | Admin |
| PUT / DELETE | `/lab/push/groups/{name}` (`{userIds}` replaces the members, an empty list deletes the group) | Admin |
| POST | `/lab/push/groups/{name}/send` `{title, body, data}` | Admin |
| POST | `/lab/push/topics/{topic}/send` `{title, body, data}` | Admin |
| POST | `/lab/push/topics/{topic}/subscribe` and `/unsubscribe` `{userIds}` | Admin |

The `/lab/push/*` calls answer `202 Accepted` with `{commandId, targets}` once the push is handed to RabbitMQ (`404 no_registered_device` when there is
nothing to send to, `503` when RabbitMQ is unreachable). The notification service sends it to FCM afterwards; look for the `commandId` in its logs.
Subscribe / unsubscribe answer `200 {subscribedDevices | unsubscribedDevices}` (devices addressed).

`message` is `{ "title": "...", "body": "...", "data": { "doorId": "102" } }` (data values are strings).

## Try it

```bash
TOKEN=$(curl -s localhost:8080/auth/login -H 'content-type: application/json' \
  -d '{"email":"admin@genkan.local","password":"SuperSecureAdmin123!"}' | jq -r .token)

curl -s localhost:8080/notifications/alerts -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"title":"Fire drill","message":"Assembly point B at 10:00"}'

curl -s localhost:8080/notifications/logs -H "authorization: Bearer $TOKEN"
```

Publish a test event from the RabbitMQ UI (exchange `workplace.events`, routing key `booking.created`):

```json
{"eventId":"3f0c6d52-6a41-4c0a-9d0e-1f6a0f1f2b11","type":"booking.created","occurredAt":"2026-10-19T08:30:00Z",
 "recipientUserIds":["<a user id>"],"data":{"room":"Kaede","start":"09:00"}}
```
Sending it twice creates one notification (idempotent on eventId + user).

## Push notifications (Firebase)

The notification service consumes `booking.#`, `access.#`, `visitor.#` and `alert.#` from RabbitMQ, stores one notification per recipient
and pushes it to the recipient's registered devices through Firebase Cloud Messaging (an alert with no recipients goes to every device).
The app registers its FCM token with `POST /lab/devices` (see *Lab service*).

Status of a stored notification: `Sent` (at least one device reached), `Skipped` (`no_registered_device`: still visible in `/notifications/me`), `Failed` (FCM error, see `error`).
Tokens FCM reports as unregistered are reported to the lab service, which deletes them.

### Lab service

`lab` owns everything about devices: the tables `device_tokens`, `device_group_members` and `topic_subscriptions` (same PostgreSQL database, still created
by `Genkan.Migrator`), the device endpoints and the four push endpoints. It never talks to Firebase and holds no Firebase credentials.
`notification` never reads those tables; it learns about them over RabbitMQ (exchange `genkan.lab`, declared by both services through `LabTopology` in `Genkan.Shared`):

| Direction | Routing key | Queue | Purpose |
|---|---|---|---|
| lab → notification | `push.send`, `push.topic-subscription` | `notification-push-commands` (durable, shared: one instance executes each command) | send a push / (un)subscribe tokens to a topic; lab has already resolved users and groups to tokens |
| lab → notification | `device.registered`, `device.removed` | one private queue per notification instance | keep each instance's in-memory device cache current |
| notification → lab | `snapshot.request` (RPC, `ReplyTo`) | `lab-service` (durable) | notification loads every device at startup, then again every `LabSync__SnapshotRefreshMinutes` (default 5) as a safety net |
| notification → lab | `device.invalid` | `lab-service` | tokens FCM reported as unregistered; lab deletes them and publishes `device.removed` |

Failed messages are retried once, then land in `genkan.lab.dead` (dead-letter exchange `genkan.lab.dlx`).
The device cache keeps the lab timestamp of every change (plus short-lived tombstones for removals), so a snapshot and live events arriving in any order give the same result.
Notification events (`booking.#`...) are only consumed once the first snapshot is loaded, so none is marked `no_registered_device` by mistake; they wait in the durable queue while lab is down.
If a device event is lost (broker down), the cache is repaired by the next snapshot; a device registered during that window may miss a push at most that long.

### Four ways to send on demand (Admin)

| Kind | Target | Implementation |
|---|---|---|
| Individual | one token, or one user's most recently used device | lab `IndividualPushService` → command → notification `FcmIndividualPushSender` |
| Multicast | an ad-hoc list of tokens and/or users | lab `MulticastPushService` → command → notification `FcmMulticastPushSender` (500 per FCM request) |
| Device group | a named group of users kept by lab | lab `DeviceGroupPushService` → multicast command |
| Topic | an FCM topic | lab `TopicPushService` → command → notification `FcmTopicPushSender` |

Device groups are a mapping kept in our own database (`device_group_members`) and resolved to tokens at send time:
FCM's native device groups are deprecated (decommissioned on 2027-09-29), and Firebase's migration guide recommends exactly this approach.
Topic subscriptions are stored per user (`topic_subscriptions`) and managed by an admin, so a device that registers a new token is
re-subscribed to its user's topics. `FirebaseAdmin` must be >= 3.7.0 for topic management.

### Broadcast topic

Every device is subscribed to the FCM topic `broadcast` when its token is registered (`POST /lab/devices`, which the app calls after login and when FCM rotates
the token), and unsubscribed from it, and from the topics of its user, when it is unregistered (logout). FCM creates a topic when its first device subscribes,
so nothing has to be created beforehand. `POST /lab/push/topics/broadcast/send` then reaches everyone with a single request.
The app registers its token after every login, so a device registered before this existed is subscribed the next time its user logs in: no extra call is needed.
If the broker is down when a device registers, it is subscribed at its next registration.
The alerts consumed from RabbitMQ (`alert.broadcast`) still go to each token individually, so a device that missed its subscription never misses an alert.

### Firebase client config for the app

`GET /notifications/firebase-config` returns the public identifiers the app needs to initialise Firebase at runtime
(`apiKey`, `applicationId`, `messagingSenderId`, `projectId`, the values found in `google-services.json`). Configure them with
`Firebase__Client__ApiKey`, `Firebase__Client__ApplicationId`, `Firebase__Client__MessagingSenderId` and `Firebase__Client__ProjectId`.
The service-account key (`firebase-service-account.json`) contains a private key, stays on the server and is never returned by any route.

### Enabling real pushes

By default `Firebase:Enabled` is `false` and pushes are only logged. To send for real, add a service-account key and use the override file:

```bash
mkdir secrets   # put firebase-service-account.json in it (git- and docker-ignored)
docker compose -f docker-compose.yml -f docker-compose.firebase.yml up -d --build
```

With `Firebase:Enabled=true` the service refuses to start if the credentials cannot be loaded.

## Rate limiting (gateway)

A token bucket in front of the proxy, applied after the token check: one bucket per user (`X-User-Id`), and per client IP for requests
without a user (login). With the default policy a bucket holds 30 tokens, every request takes one, and tokens come back continuously at
30 per 60 s (one every 2 s) instead of all at once when a fixed minute ends. An empty bucket answers `429` with `Retry-After`
(seconds until one token is back); every response carries `X-RateLimit-Limit` and `X-RateLimit-Remaining`. `/health` is never limited.

```json
"RateLimiting": {
  "Enabled": true,
  "Store": "Memory",
  "Policies": {
    "user": { "Key": "User", "Capacity": 30, "RefillTokens": 30, "RefillPeriodSeconds": 60 }
  }
}
```

Environment overrides: `RateLimiting__Policies__user__Capacity=60`, `RateLimiting__Enabled=false`, `RATE_LIMIT_STORE=Redis` (compose).
`Capacity` is the largest burst after being idle; `RefillTokens` / `RefillPeriodSeconds` is the sustained rate.

- `Store: Memory` keeps the buckets in the gateway process. With several gateway instances each instance counts on its own (N instances allow about N times the limit).
- `Store: Redis` shares the buckets between all gateway instances (atomic Lua script, Redis clock). If Redis is unreachable requests are allowed and a warning is logged.
- Another limit, for example per IP before authentication, is another entry in `Policies` plus `app.UseGatewayRateLimit("ip")` before `TokenValidationMiddleware`.
- Auth keeps its own, stricter limit on `POST /auth/login` (10 / min / IP, per Auth instance).

## Swagger (gateway)

The gateway can serve one Swagger UI for every service. It is **off by default**; switch it with one variable in `.env`:

```bash
SWAGGER_ENABLED=true    # true = show, false = hide (restart the gateway after changing it)
```

| URL | Content |
|---|---|
| `GET /swagger` | Swagger UI (assets come from the jsdelivr CDN, so the browser needs internet access) |
| `GET /swagger/openapi.json` | the merged OpenAPI document |

The gateway downloads `/openapi/v1.json` from each service (inside the network), merges paths, tags and schemas (a schema name used by two services with
different definitions is prefixed with the service name) and caches the result for 60 s. Use **Authorize** with the token from `POST /auth/login`;
"Try it out" calls the gateway, so the token check and the rate limit apply as usual. If a service is down, the others are still shown and the
description says which one is unreachable.

Settings (`Swagger` section of `src/gateway/src/Genkan.Gateway.Api/appsettings.json`, override with `Swagger__...` environment variables): `Enabled`, `Title`, `CacheSeconds`
and `Sources` (`Swagger__Sources__0__Url=http://auth:8080/openapi/v1.json`; add an entry for every new service). The two URLs are public when enabled
(like `/health`), so leave it `false` on anything exposed to the internet. When disabled, `/swagger` is not registered at all.

## Notes

- Schema changes go through `Genkan.Migrator` (see *Database*); services never create or alter tables.

## Database

One database, one owner: **`Genkan.Migrator`** is a console project run as its own container (`restart: "no"`). It applies the EF Core
migrations and exits; `auth` and `notification` have `depends_on: migrator: service_completed_successfully`, so they start on an up-to-date database.

| Project | Role |
|---|---|
| `Genkan.Shared` (`Entities/`, `Configurations/`) | entities + mappings (`IEntityTypeConfiguration<T>`), the single definition of every table |
| `Genkan.Migrator` | `GenkanDbContext` (full model **with the cross-service foreign keys**), migrations, one `__EFMigrationsHistory` |
| `AuthDbContext`, `NotificationDbContext` | runtime access to their own tables, using the mappings from `Genkan.Shared`; they never migrate |

```bash
dotnet tool install --global dotnet-ef
dotnet ef migrations add InitialCreate -p src/migrator/src/Genkan.Migrator -o Migrations     # again for every model change
docker compose up -d --build        # migrator runs, exits 0, then auth / notification start
# outside docker: dotnet run --project src/migrator/src/Genkan.Migrator   (ConnectionStrings__Postgres must be set)
```

To change the model: edit the entity / its configuration in `Genkan.Shared`, add a migration, commit it, deploy. Foreign keys are declared only in `GenkanDbContext`.
Table names are global to the database/schema, so two services must not use the same table name. Without any migration the migrator creates the tables directly (development only).
Databases created by the previous layouts (schemas `auth` / `notification` or `genkan`) are not migrated automatically: `docker compose down -v` once.

**Schema:** nothing is hard-coded, the connection string decides. By default tables are created in `public`. To use another schema, add `Search Path=<name>` to
`ConnectionStrings__Postgres` of **every** service and of the migrator (e.g. `Host=postgres;Database=genkan;Username=genkan;Password=...;Search Path=app`);
the migrator creates that schema if it does not exist. All services must use the same value, because they share the same tables.
