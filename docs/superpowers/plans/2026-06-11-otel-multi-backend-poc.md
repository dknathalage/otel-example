# OTel Multi-Backend POC — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an identical auto-instrumented order-pipeline stack (Next.js + .NET API + .NET Worker + shared `Core.*` libs) deployed one-provider-per-namespace via Helm, exporting OTLP to Google Cloud / Dash0 / Coralogix, with OpenTofu+Terragrunt for kind (local) and GKE.

**Architecture:** Zero-code .NET auto-instrumentation + `@vercel/otel`/Web SDK for Next.js. Apps emit OTLP to one in-namespace Collector that exports to exactly one backend (selected by Helm `provider` value). Manual telemetry only inside `Core.PubSub` (traceparent shim) and `Core.Firestore` (manual spans), since the .NET agent does not cover GCP Pub/Sub or Firestore. Secrets come from Google Secret Manager (WIF on GKE, ADC locally).

**Tech Stack:** .NET 9 (minimal API + BackgroundService), OpenTelemetry.AutoInstrumentation v1.15.x, Next.js 15 + @vercel/otel + OTel Web SDK, OpenTelemetry Collector (Google-Built distro), Helm, OpenTofu, Terragrunt, kind, GKE, Postgres/Redis/Pub-Sub-emulator/Firestore-emulator (local) / Cloud SQL/Memorystore/Firestore/Pub-Sub (GKE), k6.

**No automated test suite** (dropped by scope). Each task is validated by compile/build/lint/template/plan commands and, for runtime, the Collector `debug` exporter. Commit after every task.

**Reference spec:** `docs/superpowers/specs/2026-06-11-otel-multi-backend-poc-design.md`

---

## File Structure

```
OtelPoc.sln
Directory.Packages.props
Directory.Build.props
.gitignore   Taskfile.yml
src/
  Web/                     # Next.js
  Api/                     # .NET minimal API
  Worker/                  # .NET BackgroundService
  Core.Telemetry/  Core.Secrets/  Core.Logging/
  Core.Data/  Core.Redis/  Core.PubSub/  Core.Firestore/
deploy/helm/otel-poc/      # Chart + templates
infra/
  modules/local-kind/  modules/gke/
  live/terragrunt.hcl  live/local/  live/gke/
load/order-scenario.js
docs/comparison/
```

**Phasing (each phase ends runnable/inspectable):**
- Phase 0 — Repo scaffolding
- Phase 1 — Core libraries (Telemetry → Secrets → Logging → Data → Redis → PubSub → Firestore)
- Phase 2 — API
- Phase 3 — Worker
- Phase 4 — Web (Next.js)
- Phase 5 — Dockerfiles
- Phase 6 — Collector config + Helm chart
- Phase 7 — Infra: local kind (Tofu + Terragrunt)
- Phase 8 — Local bring-up + validation (Google first, then Dash0, Coralogix)
- Phase 9 — Infra: GKE
- Phase 10 — k6 + comparison docs

---

## Phase 0 — Repo scaffolding

### Task 0.1: Solution + repo config

**Files:**
- Create: `.gitignore`, `Directory.Build.props`, `Directory.Packages.props`, `OtelPoc.sln`, `global.json`

- [ ] **Step 1: `.gitignore`** — standard .NET + Node + Terraform:

```gitignore
bin/
obj/
node_modules/
.next/
*.user
.terraform/
*.tfstate*
.terragrunt-cache/
.DS_Store
```

- [ ] **Step 2: `global.json`** pin SDK:

```json
{ "sdk": { "version": "9.0.0", "rollForward": "latestMinor" } }
```

- [ ] **Step 3: `Directory.Build.props`** shared .NET settings:

```xml
<Project>
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
</Project>
```

- [ ] **Step 4: `Directory.Packages.props`** central versions (pin exact at impl time):

```xml
<Project>
  <ItemGroup>
    <PackageVersion Include="Google.Cloud.SecretManager.V1" Version="2.*" />
    <PackageVersion Include="Google.Cloud.PubSub.V1" Version="3.*" />
    <PackageVersion Include="Google.Cloud.Firestore" Version="3.*" />
    <PackageVersion Include="StackExchange.Redis" Version="2.8.*" />
    <PackageVersion Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="9.*" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.Design" Version="9.*" />
  </ItemGroup>
</Project>
```

- [ ] **Step 5: create empty solution**

Run: `dotnet new sln -n OtelPoc`
Expected: `OtelPoc.sln` created.

- [ ] **Step 6: Commit**

```bash
git add .gitignore global.json Directory.Build.props Directory.Packages.props OtelPoc.sln
git commit -m "chore: solution + repo scaffolding"
```

### Task 0.2: Taskfile

**Files:** Create: `Taskfile.yml`

- [ ] **Step 1: write Taskfile** (build, kind-load, helm install per provider):

```yaml
version: "3"
vars:
  TAG: { sh: git rev-parse --short HEAD }
tasks:
  build:dotnet: { cmds: ["dotnet build OtelPoc.sln"] }
  build:web: { dir: src/Web, cmds: ["npm ci", "npm run build"] }
  images:
    cmds:
      - docker build -t otel-poc/api:{{.TAG}} -f src/Api/Dockerfile .
      - docker build -t otel-poc/worker:{{.TAG}} -f src/Worker/Dockerfile .
      - docker build -t otel-poc/web:{{.TAG}} -f src/Web/Dockerfile src/Web
  kind-load:
    cmds:
      - kind load docker-image otel-poc/api:{{.TAG}} otel-poc/worker:{{.TAG}} otel-poc/web:{{.TAG}}
  install:
    vars: { PROVIDER: '{{.PROVIDER}}' }
    cmds:
      - helm upgrade --install otel-poc-{{.PROVIDER}} deploy/helm/otel-poc
        -f deploy/helm/otel-poc/values-local.yaml
        --set provider={{.PROVIDER}} --set image.tag={{.TAG}}
        -n otel-poc-{{.PROVIDER}} --create-namespace
```

- [ ] **Step 2: Commit**

```bash
git add Taskfile.yml && git commit -m "chore: Taskfile"
```

---

## Phase 1 — Core libraries

> Each Core lib: `dotnet new classlib`, add to sln, add references, write the files, `dotnet build`, commit. All live in `src/Core.<Name>/`. DI surface = `ServiceCollectionExtensions.Add<Name>(this IServiceCollection, IConfiguration)`.

### Task 1.1: Core.Telemetry

**Files:**
- Create: `src/Core.Telemetry/Core.Telemetry.csproj`, `Telemetry.cs`, `Propagation.cs`, `ResourceConventions.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold project**

Run:
```bash
dotnet new classlib -o src/Core.Telemetry -n Core.Telemetry
dotnet sln add src/Core.Telemetry
```

- [ ] **Step 2: `Telemetry.cs`** — single shared ActivitySource + propagator:

```csharp
using System.Diagnostics;
using OpenTelemetry.Context.Propagation;

namespace Core.Telemetry;

public static class Telemetry
{
    public const string SourceName = "OtelPoc";
    public static readonly ActivitySource Source = new(SourceName);
    public static readonly TextMapPropagator Propagator =
        Propagators.DefaultTextMapPropagator; // W3C TraceContext + Baggage
}
```

- [ ] **Step 3: add OTel API package** to csproj:

```xml
<ItemGroup>
  <PackageReference Include="OpenTelemetry.Api" />
  <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" />
  <PackageReference Include="Microsoft.Extensions.Configuration.Abstractions" />
</ItemGroup>
```
Add matching `PackageVersion` lines to `Directory.Packages.props` (`OpenTelemetry.Api` 1.*, the MS.Extensions ones 9.*).

- [ ] **Step 4: `ResourceConventions.cs`** — the standard attribute names (the actual resource is set by the agent via `OTEL_RESOURCE_ATTRIBUTES`; this is the shared constant list referenced by manual spans/logs):

```csharp
namespace Core.Telemetry;
public static class ResourceConventions
{
    public const string ServiceNamespace = "otel-poc";
}
```

- [ ] **Step 5: `Propagation.cs`** — carrier helpers used by Core.PubSub:

```csharp
using OpenTelemetry.Context.Propagation;
namespace Core.Telemetry;

public static class Propagation
{
    // Inject current context into a string dictionary (Pub/Sub message attributes)
    public static void Inject(IDictionary<string, string> carrier)
        => Telemetry.Propagator.Inject(
            new PropagationContext(System.Diagnostics.Activity.Current?.Context ?? default, default),
            carrier, static (c, k, v) => c[k] = v);

    public static PropagationContext Extract(IReadOnlyDictionary<string, string> carrier)
        => Telemetry.Propagator.Extract(default, carrier,
            static (c, k) => c.TryGetValue(k, out var v) ? new[] { v } : Array.Empty<string>());
}
```

- [ ] **Step 6: `ServiceCollectionExtensions.cs`**:

```csharp
using Microsoft.Extensions.DependencyInjection;
namespace Core.Telemetry;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreTelemetry(this IServiceCollection s) => s;
    // ActivitySource is static; nothing to register yet. Hook kept for symmetry.
}
```

- [ ] **Step 7: build**

Run: `dotnet build src/Core.Telemetry`
Expected: Build succeeded.

- [ ] **Step 8: Commit**

```bash
git add src/Core.Telemetry Directory.Packages.props OtelPoc.sln
git commit -m "feat(core): Core.Telemetry (ActivitySource + W3C propagation)"
```

### Task 1.2: Core.Secrets

**Files:** Create `src/Core.Secrets/`: `Core.Secrets.csproj`, `ISecretProvider.cs`, `GsmSecretProvider.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln**

```bash
dotnet new classlib -o src/Core.Secrets -n Core.Secrets
dotnet sln add src/Core.Secrets
```

- [ ] **Step 2: csproj packages**: `Google.Cloud.SecretManager.V1`, MS.Extensions DI/Config/Caching.Memory.

- [ ] **Step 3: `ISecretProvider.cs`**:

```csharp
namespace Core.Secrets;
public interface ISecretProvider
{
    Task<string> GetAsync(string name, CancellationToken ct = default);
}
```

- [ ] **Step 4: `GsmSecretProvider.cs`** (ADC/WIF picked up automatically by the client; cached):

```csharp
using Google.Cloud.SecretManager.V1;
using Microsoft.Extensions.Caching.Memory;
namespace Core.Secrets;

public sealed class GsmSecretProvider(string projectId, IMemoryCache cache) : ISecretProvider
{
    private readonly SecretManagerServiceClient _client = SecretManagerServiceClient.Create();

    public async Task<string> GetAsync(string name, CancellationToken ct = default)
        => await cache.GetOrCreateAsync(name, async _ =>
        {
            var path = new SecretVersionName(projectId, name, "latest");
            var result = await _client.AccessSecretVersionAsync(path, ct);
            return result.Payload.Data.ToStringUtf8();
        }) ?? throw new InvalidOperationException($"secret {name} empty");
}
```

- [ ] **Step 5: `ServiceCollectionExtensions.cs`** — `AddCoreSecrets` reads `Gcp:ProjectId` from config:

```csharp
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Secrets;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreSecrets(this IServiceCollection s, IConfiguration cfg)
    {
        s.AddMemoryCache();
        var project = cfg["Gcp:ProjectId"] ?? throw new InvalidOperationException("Gcp:ProjectId missing");
        s.AddSingleton<ISecretProvider>(sp =>
            new GsmSecretProvider(project, sp.GetRequiredService<IMemoryCache>()));
        return s;
    }
}
```

- [ ] **Step 6: build + commit**

Run: `dotnet build src/Core.Secrets`
```bash
git add src/Core.Secrets Directory.Packages.props OtelPoc.sln
git commit -m "feat(core): Core.Secrets (GSM-backed ISecretProvider)"
```

### Task 1.3: Core.Logging

**Files:** Create `src/Core.Logging/`: csproj (ref Core.Telemetry), `LoggingConventions.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln + `dotnet add reference ../Core.Telemetry`**
- [ ] **Step 2: `LoggingConventions.cs`** — standard scope keys:

```csharp
namespace Core.Logging;
public static class LoggingConventions
{
    public const string OrderId = "order.id";
}
```

- [ ] **Step 3: `ServiceCollectionExtensions.cs`** — `AddCoreLogging` enables scopes (the .NET auto-instr agent exports ILogger → OTLP; we only ensure scopes/formatted message are on):

```csharp
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
namespace Core.Logging;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreLogging(this IServiceCollection s)
    {
        s.AddLogging(b => b.Configure(o =>
            o.ActivityTrackingOptions =
                ActivityTrackingOptions.TraceId | ActivityTrackingOptions.SpanId));
        return s;
    }
}
```

- [ ] **Step 4: build + commit** (`feat(core): Core.Logging`)

### Task 1.4: Core.Data (Postgres orders)

**Files:** Create `src/Core.Data/`: csproj (Npgsql EF Core, EF Design), `OrderEntity.cs`, `OrdersDbContext.cs`, `IOrderRepository.cs`, `OrderRepository.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln + packages** (`Npgsql.EntityFrameworkCore.PostgreSQL`, `Microsoft.EntityFrameworkCore.Design`)
- [ ] **Step 2: `OrderEntity.cs`**:

```csharp
namespace Core.Data;
public class OrderEntity
{
    public Guid Id { get; set; }
    public string Sku { get; set; } = "";
    public int Quantity { get; set; }
    public string Status { get; set; } = "created";
    public DateTimeOffset CreatedAt { get; set; }
}
```

- [ ] **Step 3: `OrdersDbContext.cs`**:

```csharp
using Microsoft.EntityFrameworkCore;
namespace Core.Data;
public class OrdersDbContext(DbContextOptions<OrdersDbContext> o) : DbContext(o)
{
    public DbSet<OrderEntity> Orders => Set<OrderEntity>();
}
```

- [ ] **Step 4: `IOrderRepository.cs` + `OrderRepository.cs`**:

```csharp
namespace Core.Data;
public interface IOrderRepository
{
    Task AddAsync(OrderEntity order, CancellationToken ct = default);
}

public sealed class OrderRepository(OrdersDbContext db) : IOrderRepository
{
    public async Task AddAsync(OrderEntity order, CancellationToken ct = default)
    {
        db.Orders.Add(order);
        await db.SaveChangesAsync(ct); // Npgsql auto-instrumented → DB span automatic
    }
}
```

- [ ] **Step 5: `ServiceCollectionExtensions.cs`** — `AddCoreData(cfg)` reads `ConnectionStrings:Orders`:

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Data;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreData(this IServiceCollection s, IConfiguration cfg)
    {
        s.AddDbContext<OrdersDbContext>(o => o.UseNpgsql(cfg.GetConnectionString("Orders")));
        s.AddScoped<IOrderRepository, OrderRepository>();
        return s;
    }
}
```

- [ ] **Step 6: initial migration**

Run: `dotnet ef migrations add InitialCreate -p src/Core.Data -s src/Core.Data`
(If no startup project context, defer migration to Api task; note here.)

- [ ] **Step 7: build + commit** (`feat(core): Core.Data (Postgres orders repo)`)

### Task 1.5: Core.Redis (idempotency)

**Files:** Create `src/Core.Redis/`: csproj (`StackExchange.Redis`), `IRedisCache.cs`, `RedisCache.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln + package**
- [ ] **Step 2: `IRedisCache.cs`**:

```csharp
namespace Core.Redis;
public interface IRedisCache
{
    // returns true if this key was newly set (i.e. not a duplicate)
    Task<bool> TryMarkAsync(string key, TimeSpan ttl, CancellationToken ct = default);
}
```

- [ ] **Step 3: `RedisCache.cs`** (key prefix from config for per-release isolation):

```csharp
using StackExchange.Redis;
namespace Core.Redis;
public sealed class RedisCache(IConnectionMultiplexer mux, string prefix) : IRedisCache
{
    public async Task<bool> TryMarkAsync(string key, TimeSpan ttl, CancellationToken ct = default)
        => await mux.GetDatabase().StringSetAsync($"{prefix}{key}", "1", ttl, When.NotExists);
}
```

- [ ] **Step 4: `ServiceCollectionExtensions.cs`** — `AddCoreRedis(cfg)` reads `Redis:ConnectionString` + `Redis:KeyPrefix`:

```csharp
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using StackExchange.Redis;
namespace Core.Redis;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreRedis(this IServiceCollection s, IConfiguration cfg)
    {
        s.AddSingleton<IConnectionMultiplexer>(_ =>
            ConnectionMultiplexer.Connect(cfg["Redis:ConnectionString"]!));
        var prefix = cfg["Redis:KeyPrefix"] ?? "";
        s.AddSingleton<IRedisCache>(sp =>
            new RedisCache(sp.GetRequiredService<IConnectionMultiplexer>(), prefix));
        return s;
    }
}
```

- [ ] **Step 5: build + commit** (`feat(core): Core.Redis (idempotency w/ key prefix)`)

### Task 1.6: Core.PubSub (the propagation shim — critical)

**Files:** Create `src/Core.PubSub/`: csproj (ref Core.Telemetry; `Google.Cloud.PubSub.V1`), `OrderMessage.cs`, `IPubSubPublisher.cs`, `PubSubPublisher.cs`, `IPubSubSubscriber.cs`, `PubSubSubscriber.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln + ref + package**
- [ ] **Step 2: `OrderMessage.cs`** — DTO serialized to JSON in the message body:

```csharp
namespace Core.PubSub;
public record OrderMessage(Guid Id, string Sku, int Quantity);
```

- [ ] **Step 3: `IPubSubPublisher.cs` / `IPubSubSubscriber.cs`**:

```csharp
namespace Core.PubSub;
public interface IPubSubPublisher
{
    Task PublishAsync(OrderMessage message, CancellationToken ct = default);
}
public interface IPubSubSubscriber
{
    Task StartAsync(Func<OrderMessage, CancellationToken, Task> handler, CancellationToken ct);
}
```

- [ ] **Step 4: `PubSubPublisher.cs`** — **inject traceparent into attributes + producer span**:

```csharp
using System.Diagnostics;
using System.Text.Json;
using Core.Telemetry;
using Google.Cloud.PubSub.V1;
using Google.Protobuf;
namespace Core.PubSub;

public sealed class PubSubPublisher(PublisherClient client) : IPubSubPublisher
{
    public async Task PublishAsync(OrderMessage message, CancellationToken ct = default)
    {
        using var activity = Telemetry.Source.StartActivity(
            "orders publish", ActivityKind.Producer);
        activity?.SetTag("messaging.system", "gcp_pubsub");

        var attrs = new Dictionary<string, string>();
        Propagation.Inject(attrs); // writes traceparent/tracestate

        var msg = new PubsubMessage
        {
            Data = ByteString.CopyFromUtf8(JsonSerializer.Serialize(message)),
        };
        foreach (var (k, v) in attrs) msg.Attributes[k] = v;
        await client.PublishAsync(msg);
    }
}
```

- [ ] **Step 5: `PubSubSubscriber.cs`** — **extract context + consumer span as child**:

```csharp
using System.Diagnostics;
using System.Text.Json;
using Core.Telemetry;
using Google.Cloud.PubSub.V1;
namespace Core.PubSub;

public sealed class PubSubSubscriber(SubscriberClient client) : IPubSubSubscriber
{
    public Task StartAsync(Func<OrderMessage, CancellationToken, Task> handler, CancellationToken ct)
        => client.StartAsync(async (msg, mct) =>
        {
            var carrier = msg.Attributes.ToDictionary(kv => kv.Key, kv => kv.Value);
            var parent = Propagation.Extract(carrier);
            using var activity = Telemetry.Source.StartActivity(
                "orders process", ActivityKind.Consumer, parent.ActivityContext);
            activity?.SetTag("messaging.system", "gcp_pubsub");

            var order = JsonSerializer.Deserialize<OrderMessage>(msg.Data.ToStringUtf8())!;
            await handler(order, mct);
            return SubscriberClient.Reply.Ack;
        });
}
```

- [ ] **Step 6: `ServiceCollectionExtensions.cs`** — build Publisher/Subscriber clients from config (`PubSub:ProjectId`, `:TopicId`, `:SubscriptionId`, and `PUBSUB_EMULATOR_HOST` honored automatically by the client lib):

```csharp
using Core.Telemetry;
using Google.Cloud.PubSub.V1;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.PubSub;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCorePubSubPublisher(this IServiceCollection s, IConfiguration cfg)
    {
        var topic = TopicName.FromProjectTopic(cfg["PubSub:ProjectId"]!, cfg["PubSub:TopicId"]!);
        s.AddSingleton(_ => PublisherClient.Create(topic));
        s.AddSingleton<IPubSubPublisher, PubSubPublisher>();
        return s;
    }
    public static IServiceCollection AddCorePubSubSubscriber(this IServiceCollection s, IConfiguration cfg)
    {
        var sub = SubscriptionName.FromProjectSubscription(cfg["PubSub:ProjectId"]!, cfg["PubSub:SubscriptionId"]!);
        s.AddSingleton(_ => SubscriberClient.Create(sub));
        s.AddSingleton<IPubSubSubscriber, PubSubSubscriber>();
        return s;
    }
}
```

- [ ] **Step 7: build + commit** (`feat(core): Core.PubSub (traceparent inject/extract shim)`)

### Task 1.7: Core.Firestore (manual spans)

**Files:** Create `src/Core.Firestore/`: csproj (ref Core.Telemetry; `Google.Cloud.Firestore`), `IFirestoreStore.cs`, `FirestoreStore.cs`, `ServiceCollectionExtensions.cs`

- [ ] **Step 1: scaffold + add to sln + ref + package**
- [ ] **Step 2: `IFirestoreStore.cs`**:

```csharp
namespace Core.Firestore;
public interface IFirestoreStore
{
    Task UpsertStatusAsync(Guid orderId, string status, CancellationToken ct = default);
}
```

- [ ] **Step 3: `FirestoreStore.cs`** — **manual client span** (not auto-instrumented); collection prefix from config for per-release isolation:

```csharp
using System.Diagnostics;
using Core.Telemetry;
using Google.Cloud.Firestore;
namespace Core.Firestore;

public sealed class FirestoreStore(FirestoreDb db, string collectionPrefix) : IFirestoreStore
{
    public async Task UpsertStatusAsync(Guid orderId, string status, CancellationToken ct = default)
    {
        using var activity = Telemetry.Source.StartActivity("firestore upsert", ActivityKind.Client);
        activity?.SetTag("db.system", "firestore");
        activity?.SetTag("db.collection.name", $"{collectionPrefix}orders");
        var doc = db.Collection($"{collectionPrefix}orders").Document(orderId.ToString());
        await doc.SetAsync(new { status, updatedAt = Timestamp.GetCurrentTimestamp() },
            SetOptions.MergeAll, ct);
    }
}
```

- [ ] **Step 4: `ServiceCollectionExtensions.cs`** — `AddCoreFirestore(cfg)` reads `Firestore:ProjectId`, `Firestore:CollectionPrefix` (FIRESTORE_EMULATOR_HOST honored by client):

```csharp
using Google.Cloud.Firestore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Firestore;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreFirestore(this IServiceCollection s, IConfiguration cfg)
    {
        var project = cfg["Firestore:ProjectId"]!;
        var prefix = cfg["Firestore:CollectionPrefix"] ?? "";
        s.AddSingleton(_ => FirestoreDb.Create(project));
        s.AddSingleton<IFirestoreStore>(sp =>
            new FirestoreStore(sp.GetRequiredService<FirestoreDb>(), prefix));
        return s;
    }
}
```

- [ ] **Step 5: build whole solution + commit**

Run: `dotnet build OtelPoc.sln`
Expected: Build succeeded.
```bash
git add src/Core.Firestore Directory.Packages.props OtelPoc.sln
git commit -m "feat(core): Core.Firestore (manual client spans)"
```

---

## Phase 2 — API

### Task 2.1: API project + order endpoint

**Files:** Create `src/Api/`: `Api.csproj` (refs all Core projects), `Program.cs`, `Endpoints/OrdersEndpoints.cs`, `Models/CreateOrderRequest.cs`, `appsettings.json`, `appsettings.Development.json`

- [ ] **Step 1: scaffold web project + add to sln + references**

```bash
dotnet new web -o src/Api -n Api
dotnet sln add src/Api
for p in Telemetry Secrets Logging Data Redis PubSub; do
  dotnet add src/Api reference src/Core.$p; done
```

- [ ] **Step 2: `Models/CreateOrderRequest.cs`**:

```csharp
namespace Api.Models;
public record CreateOrderRequest(string Sku, int Quantity);
```

- [ ] **Step 3: `Endpoints/OrdersEndpoints.cs`** — handler uses only Core interfaces:

```csharp
using Api.Models;
using Core.Data; using Core.PubSub; using Core.Redis;
using Microsoft.Extensions.Logging;
namespace Api.Endpoints;

public static class OrdersEndpoints
{
    public static void MapOrders(this WebApplication app)
    {
        app.MapPost("/orders", async (
            CreateOrderRequest req, IOrderRepository repo, IRedisCache cache,
            IPubSubPublisher pub, ILogger<Program> log, CancellationToken ct) =>
        {
            var id = Guid.NewGuid();
            if (!await cache.TryMarkAsync($"order:{req.Sku}:{req.Quantity}", TimeSpan.FromSeconds(30), ct))
                return Results.Conflict("duplicate");
            await repo.AddAsync(new OrderEntity {
                Id = id, Sku = req.Sku, Quantity = req.Quantity,
                CreatedAt = DateTimeOffset.UtcNow }, ct);
            await pub.PublishAsync(new OrderMessage(id, req.Sku, req.Quantity), ct);
            log.LogInformation("order {OrderId} created", id);
            return Results.Accepted($"/orders/{id}", new { id });
        });
    }
}
```

- [ ] **Step 4: `Program.cs`** — the standard `AddCore*` wiring:

```csharp
using Api.Endpoints;
using Core.Data; using Core.Logging; using Core.PubSub;
using Core.Redis; using Core.Secrets; using Core.Telemetry;

var builder = WebApplication.CreateBuilder(args);
builder.Services
    .AddCoreSecrets(builder.Configuration)
    .AddCoreTelemetry()
    .AddCoreLogging()
    .AddCoreData(builder.Configuration)
    .AddCoreRedis(builder.Configuration)
    .AddCorePubSubPublisher(builder.Configuration);

var app = builder.Build();
using (var scope = app.Services.CreateScope())
    scope.ServiceProvider.GetRequiredService<OrdersDbContext>().Database.Migrate();
app.MapOrders();
app.MapGet("/healthz", () => Results.Ok());
app.Run();
```

- [ ] **Step 5: `appsettings.json`** — config keys (overridden by env in k8s):

```json
{
  "Gcp": { "ProjectId": "" },
  "ConnectionStrings": { "Orders": "" },
  "Redis": { "ConnectionString": "", "KeyPrefix": "" },
  "PubSub": { "ProjectId": "", "TopicId": "orders", "SubscriptionId": "orders-sub" },
  "Logging": { "LogLevel": { "Default": "Information" } }
}
```

- [ ] **Step 6: generate EF migration now that a startup host exists**

Run: `dotnet ef migrations add InitialCreate -p src/Core.Data -s src/Api`
Expected: `Migrations/` created under Core.Data.

- [ ] **Step 7: build + commit**

Run: `dotnet build src/Api`
```bash
git add src/Api src/Core.Data/Migrations OtelPoc.sln
git commit -m "feat(api): order endpoint + Core wiring + EF migration"
```

---

## Phase 3 — Worker

### Task 3.1: Worker project + consumer

**Files:** Create `src/Worker/`: `Worker.csproj` (refs Core.Telemetry/Secrets/Logging/PubSub/Firestore), `Program.cs`, `Consumers/OrderConsumer.cs`, `appsettings.json`

- [ ] **Step 1: scaffold worker + add to sln + references**

```bash
dotnet new worker -o src/Worker -n Worker
dotnet sln add src/Worker
for p in Telemetry Secrets Logging PubSub Firestore; do
  dotnet add src/Worker reference src/Core.$p; done
```

- [ ] **Step 2: `Consumers/OrderConsumer.cs`** — `BackgroundService` driving the subscriber:

```csharp
using Core.Firestore; using Core.PubSub;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
namespace Worker.Consumers;

public sealed class OrderConsumer(
    IPubSubSubscriber subscriber, IFirestoreStore store, ILogger<OrderConsumer> log)
    : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken)
        => subscriber.StartAsync(async (order, ct) =>
        {
            await store.UpsertStatusAsync(order.Id, "processed", ct);
            log.LogInformation("order {OrderId} processed", order.Id);
        }, stoppingToken);
}
```

- [ ] **Step 3: `Program.cs`**:

```csharp
using Core.Firestore; using Core.Logging; using Core.PubSub;
using Core.Secrets; using Core.Telemetry;
using Worker.Consumers;

var builder = Host.CreateApplicationBuilder(args);
builder.Services
    .AddCoreSecrets(builder.Configuration)
    .AddCoreTelemetry()
    .AddCoreLogging()
    .AddCorePubSubSubscriber(builder.Configuration)
    .AddCoreFirestore(builder.Configuration);
builder.Services.AddHostedService<OrderConsumer>();
builder.Build().Run();
```

- [ ] **Step 4: `appsettings.json`** (Gcp, PubSub, Firestore keys mirroring API).

- [ ] **Step 5: build + commit**

Run: `dotnet build src/Worker`
```bash
git add src/Worker OtelPoc.sln && git commit -m "feat(worker): Pub/Sub consumer → Firestore"
```

---

## Phase 4 — Web (Next.js)

### Task 4.1: Next.js app + OTel

**Files:** Create `src/Web/`: `package.json`, `next.config.js`, `tsconfig.json`, `instrumentation.ts`, `app/layout.tsx`, `app/page.tsx`, `app/providers.tsx`, `lib/otel/client.ts`, `lib/api.ts`, `lib/secrets.ts`

- [ ] **Step 1: scaffold**

Run: `npx create-next-app@latest src/Web --ts --app --no-tailwind --no-eslint --no-src-dir`
(Accept defaults; trim boilerplate.)

- [ ] **Step 2: add OTel deps**

Run (in `src/Web`):
```bash
npm i @vercel/otel \
  @opentelemetry/sdk-trace-web @opentelemetry/exporter-trace-otlp-http \
  @opentelemetry/instrumentation @opentelemetry/instrumentation-document-load \
  @opentelemetry/instrumentation-fetch @opentelemetry/instrumentation-user-interaction \
  @opentelemetry/context-zone @opentelemetry/resources @opentelemetry/semantic-conventions
```

- [ ] **Step 3: `instrumentation.ts`** (server, root):

```ts
import { registerOTel } from '@vercel/otel';
export function register() {
  registerOTel({ serviceName: 'web' });
  // reads OTEL_EXPORTER_OTLP_ENDPOINT from env
}
```

- [ ] **Step 4: `lib/otel/client.ts`** (browser Web SDK → collector OTLP/http):

```ts
'use client';
import { WebTracerProvider, BatchSpanProcessor } from '@opentelemetry/sdk-trace-web';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { ZoneContextManager } from '@opentelemetry/context-zone';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME } from '@opentelemetry/semantic-conventions';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { UserInteractionInstrumentation } from '@opentelemetry/instrumentation-user-interaction';

export function initBrowserOtel() {
  const url = process.env.NEXT_PUBLIC_OTLP_HTTP_URL!; // e.g. https://otel.<env>/v1/traces
  const provider = new WebTracerProvider({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: 'web-browser',
      'service.namespace': 'otel-poc',
    }),
    spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url }))],
  });
  provider.register({ contextManager: new ZoneContextManager() });
  registerInstrumentations({
    instrumentations: [
      new DocumentLoadInstrumentation(),
      new FetchInstrumentation(),
      new UserInteractionInstrumentation(),
    ],
  });
}
```

- [ ] **Step 5: `app/providers.tsx`** — run browser init once on mount:

```tsx
'use client';
import { useEffect } from 'react';
import { initBrowserOtel } from '@/lib/otel/client';
export function Providers({ children }: { children: React.ReactNode }) {
  useEffect(() => { initBrowserOtel(); }, []);
  return <>{children}</>;
}
```

- [ ] **Step 6: `lib/api.ts`** + `app/page.tsx`** — order form POSTing to the API (`NEXT_PUBLIC_API_URL`), wrap `app/layout.tsx` children in `<Providers>`.

```ts
// lib/api.ts
export async function createOrder(sku: string, quantity: number) {
  const res = await fetch(`${process.env.NEXT_PUBLIC_API_URL}/orders`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ sku, quantity }),
  });
  return res.json();
}
```

- [ ] **Step 7: `lib/secrets.ts`** — server-only GSM read (mirrors Core.Secrets), used if web needs the browser ingest token:

```ts
import 'server-only';
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
const client = new SecretManagerServiceClient();
export async function getSecret(project: string, name: string) {
  const [v] = await client.accessSecretVersion({
    name: `projects/${project}/secrets/${name}/versions/latest`,
  });
  return v.payload?.data?.toString() ?? '';
}
```
(Run `npm i @google-cloud/secret-manager`.)

- [ ] **Step 8: build + commit**

Run: `npm run build` (in `src/Web`)
Expected: Next build succeeds.
```bash
git add src/Web && git commit -m "feat(web): Next.js order UI + server/browser OTel"
```

---

## Phase 5 — Dockerfiles

### Task 5.1: .NET API Dockerfile (zero-code agent baked in)

**Files:** Create `src/Api/Dockerfile`

- [ ] **Step 1: write multi-stage Dockerfile** (build context = repo root):

```dockerfile
# build
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY . .
RUN dotnet publish src/Api -c Release -o /app

# runtime + OTel auto-instrumentation
FROM mcr.microsoft.com/dotnet/aspnet:9.0
WORKDIR /app
RUN apt-get update && apt-get install -y curl unzip && rm -rf /var/lib/apt/lists/*
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
RUN curl -sSfL https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/otel-dotnet-auto-install.sh -O \
    && bash ./otel-dotnet-auto-install.sh
ENV CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318} \
    CORECLR_PROFILER_PATH=/otel-dotnet-auto/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so \
    DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps \
    DOTNET_SHARED_STORE=/otel-dotnet-auto/store \
    DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll \
    OTEL_SERVICE_NAME=api
COPY --from=build /app .
ENTRYPOINT ["dotnet", "Api.dll"]
```

- [ ] **Step 2: build image**

Run: `docker build -t otel-poc/api:dev -f src/Api/Dockerfile .`
Expected: image builds.

- [ ] **Step 3: Commit** (`build(api): Dockerfile with .NET auto-instrumentation`)

### Task 5.2: Worker Dockerfile

**Files:** Create `src/Worker/Dockerfile`

- [ ] **Step 1:** same as API but base `mcr.microsoft.com/dotnet/runtime:9.0`, publish `src/Worker`, `OTEL_SERVICE_NAME=worker`, `ENTRYPOINT ["dotnet","Worker.dll"]`.
- [ ] **Step 2: build + commit** (`build(worker): Dockerfile`)

### Task 5.3: Web Dockerfile

**Files:** Create `src/Web/Dockerfile` (context = `src/Web`)

- [ ] **Step 1:** Next standalone output:

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```
(Set `output: 'standalone'` in `next.config.js`.)

- [ ] **Step 2: build + commit** (`build(web): Dockerfile`)

---

## Phase 6 — Collector config + Helm chart

### Task 6.1: Chart skeleton + values

**Files:** Create `deploy/helm/otel-poc/`: `Chart.yaml`, `values.yaml`, `values-local.yaml`, `values-gke.yaml`, `templates/_helpers.tpl`

- [ ] **Step 1: `Chart.yaml`** (apiVersion v2, name otel-poc, version 0.1.0).
- [ ] **Step 2: `values.yaml`** — the schema from the spec:

```yaml
provider: google        # google | dash0 | coralogix
env: local              # local | gke
gcpProject: ""
image: { registry: "otel-poc", tag: "dev" }
providers:
  google: {}
  dash0: { region: us-west-2, dataset: otel-poc }
  coralogix: { domain: eu2.coralogix.com }
deps: { enabled: true }       # local in-namespace deps
webOrigin: "http://localhost:3000"
```

- [ ] **Step 3: `values-local.yaml`** (`env: local`, `deps.enabled: true`) and `values-gke.yaml` (`env: gke`, `deps.enabled: false`, real registry).
- [ ] **Step 4: `_helpers.tpl`** — release-derived names:

```
{{- define "otel-poc.release" -}}{{ .Release.Name | trimPrefix "otel-poc-" }}{{- end -}}
{{- define "otel-poc.topic" -}}orders-{{ include "otel-poc.release" . }}{{- end -}}
{{- define "otel-poc.subscription" -}}orders-{{ include "otel-poc.release" . }}-sub{{- end -}}
{{- define "otel-poc.pgdb" -}}orders_{{ include "otel-poc.release" . }}{{- end -}}
{{- define "otel-poc.prefix" -}}{{ include "otel-poc.release" . }}:{{- end -}}
```

- [ ] **Step 5: lint + commit**

Run: `helm lint deploy/helm/otel-poc`
```bash
git add deploy/helm/otel-poc && git commit -m "feat(helm): chart skeleton + values + helpers"
```

### Task 6.2: Collector ConfigMap (provider-selected exporter)

**Files:** Create `deploy/helm/otel-poc/templates/collector-configmap.yaml`

- [ ] **Step 1: write templated collector config** — receivers (OTLP + CORS), batch, conditional gcp processors, one exporter by `.Values.provider`, three pipelines. Use the exporter blocks from the spec (google OTLP+googleclientauth, dash0 otlphttp+headers, coralogix exporter+private_key), with `{{ .Values.gcpProject }}` rendered into GSM refs.

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: collector-config }
data:
  config.yaml: |
    extensions:
      {{- if eq .Values.provider "google" }}
      googleclientauth: {}
      {{- end }}
    receivers:
      otlp:
        protocols:
          grpc: {}
          http:
            endpoint: 0.0.0.0:4318
            cors:
              allowed_origins: ["{{ .Values.webOrigin }}"]
              allowed_headers: ["*"]
    processors:
      batch: {}
      {{- if eq .Values.provider "google" }}
      resource/gcp:
        attributes:
          - { key: gcp.project_id, value: "{{ .Values.gcpProject }}", action: upsert }
      {{- end }}
    exporters:
      {{- if eq .Values.provider "google" }}
      otlphttp/be:
        endpoint: https://telemetry.googleapis.com
        encoding: proto
        auth: { authenticator: googleclientauth }
      {{- else if eq .Values.provider "dash0" }}
      otlphttp/be:
        endpoint: https://ingress.{{ .Values.providers.dash0.region }}.aws.dash0.com
        headers:
          Authorization: "Bearer ${googlesecretmanager:projects/{{ .Values.gcpProject }}/secrets/dash0-token/versions/latest}"
          Dash0-Dataset: "{{ .Values.providers.dash0.dataset }}"
      {{- else if eq .Values.provider "coralogix" }}
      coralogix:
        domain: "{{ .Values.providers.coralogix.domain }}"
        private_key: "${googlesecretmanager:projects/{{ .Values.gcpProject }}/secrets/coralogix-key/versions/latest}"
        application_name: "otel-poc"
        subsystem_name: "${env:HOSTNAME}"
      {{- end }}
    service:
      {{- if eq .Values.provider "google" }}
      extensions: [googleclientauth]
      {{- end }}
      pipelines:
        traces:  { receivers: [otlp], processors: [batch{{ if eq .Values.provider "google" }}, resource/gcp{{ end }}], exporters: [{{ if eq .Values.provider "coralogix" }}coralogix{{ else }}otlphttp/be{{ end }}] }
        metrics: { receivers: [otlp], processors: [batch{{ if eq .Values.provider "google" }}, resource/gcp{{ end }}], exporters: [{{ if eq .Values.provider "coralogix" }}coralogix{{ else }}otlphttp/be{{ end }}] }
        logs:    { receivers: [otlp], processors: [batch], exporters: [{{ if eq .Values.provider "coralogix" }}coralogix{{ else }}otlphttp/be{{ end }}] }
```

- [ ] **Step 2: render-check each provider**

Run:
```bash
helm template t deploy/helm/otel-poc --set provider=google --set gcpProject=p | grep -A2 telemetry.googleapis
helm template t deploy/helm/otel-poc --set provider=dash0 --set gcpProject=p | grep Dash0-Dataset
helm template t deploy/helm/otel-poc --set provider=coralogix --set gcpProject=p | grep coralogix
```
Expected: each renders the right exporter, no `<no value>`.

- [ ] **Step 3: Commit** (`feat(helm): collector configmap, provider-selected exporter`)

### Task 6.3: Collector Deployment + Service

**Files:** Create `templates/collector.yaml`

- [ ] **Step 1:** Deployment using the **Google-Built Collector** image (bundles googleclientauth + googlesecretmanager provider), mount the ConfigMap, set `GCP_PROJECT` env, expose 4317/4318, command `--config=/conf/config.yaml`; Service `collector:4317/4318`. (Pin the exact image ref at impl time.)
- [ ] **Step 2: template-check + commit** (`feat(helm): collector deployment+service`)

### Task 6.4: App Deployments + Services + ServiceAccount

**Files:** Create `templates/serviceaccount.yaml`, `templates/api.yaml`, `templates/worker.yaml`, `templates/web.yaml`

- [ ] **Step 1: `serviceaccount.yaml`** — KSA `otel-poc` with WIF annotation `iam.gke.io/gcp-service-account` (only when `env=gke`).
- [ ] **Step 2: `api.yaml`** — Deployment+Service. Env: `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318`, `OTEL_RESOURCE_ATTRIBUTES`, `Gcp__ProjectId`, `ConnectionStrings__Orders`, `Redis__ConnectionString`, `Redis__KeyPrefix={{ include "otel-poc.prefix" . }}`, `PubSub__ProjectId/TopicId/SubscriptionId` (topic = helper), and for local `PUBSUB_EMULATOR_HOST`/`FIRESTORE_EMULATOR_HOST`. Reference image `{{.Values.image.registry}}/api:{{.Values.image.tag}}`.
- [ ] **Step 3: `worker.yaml`** — Deployment (no Service). Same telemetry + PubSub + Firestore env (`Firestore__CollectionPrefix` = helper).
- [ ] **Step 4: `web.yaml`** — Deployment+Service. Env `OTEL_EXPORTER_OTLP_ENDPOINT`, `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_OTLP_HTTP_URL`.
- [ ] **Step 5: template-check + commit** (`feat(helm): app deployments + KSA`)

### Task 6.5: Ingress + local deps

**Files:** Create `templates/ingress.yaml`, `templates/deps/postgres.yaml`, `deps/redis.yaml`, `deps/pubsub-emulator.yaml`, `deps/firestore-emulator.yaml`

- [ ] **Step 1: `ingress.yaml`** — hosts for web, api, and the browser-OTLP collector endpoint.
- [ ] **Step 2: `deps/*`** — guarded by `{{- if .Values.deps.enabled }}`: Postgres (`postgres:16`), Redis (`redis:7`), Pub/Sub emulator (`gcr.io/google.com/cloudsdktool/google-cloud-cli` `gcloud beta emulators pubsub start`), Firestore emulator (same CLI image, firestore start). Each a Deployment+Service.
- [ ] **Step 3: full template render both envs**

Run:
```bash
helm template t deploy/helm/otel-poc -f deploy/helm/otel-poc/values-local.yaml --set gcpProject=p >/tmp/local.yaml
helm template t deploy/helm/otel-poc -f deploy/helm/otel-poc/values-gke.yaml --set gcpProject=p >/tmp/gke.yaml
```
Expected: both render clean; deps present in local only.

- [ ] **Step 4: Commit** (`feat(helm): ingress + local dep emulators`)

---

## Phase 7 — Infra: local kind

### Task 7.1: kind module + Terragrunt local env

**Files:** Create `infra/modules/local-kind/{main.tf,variables.tf,versions.tf}`, `infra/live/terragrunt.hcl`, `infra/live/local/terragrunt.hcl`

- [ ] **Step 1: `versions.tf`** — providers `tehcyx/kind` (kind cluster) + `hashicorp/null`.
- [ ] **Step 2: `main.tf`** — a `kind_cluster` resource with `extraPortMappings` for the ingress (80/443) and node config.
- [ ] **Step 3: root `terragrunt.hcl`** — local backend (`path_relative_to_include`), shared inputs.
- [ ] **Step 4: `live/local/terragrunt.hcl`** — `terraform { source = "../../modules/local-kind" }`, inputs (cluster name `otel-poc`).
- [ ] **Step 5: validate**

Run: `cd infra/live/local && terragrunt validate` (or `tofu validate` in the module).
Expected: valid.

- [ ] **Step 6: Commit** (`feat(infra): kind module + terragrunt local env`)

---

## Phase 8 — Local bring-up + validation

### Task 8.1: Stand up kind + Google release

- [ ] **Step 1: ADC login** (prereq): instruct operator to run `gcloud auth application-default login` and create GSM secrets `dash0-token`, `coralogix-key` in the dev project (deferred creds; Google needs none).
- [ ] **Step 2: create cluster**

Run: `cd infra/live/local && terragrunt apply`
Expected: kind cluster `otel-poc` up; `kubectl get nodes` works.

- [ ] **Step 3: build + load images**

Run: `task images && task kind-load`

- [ ] **Step 4: install Google release**

Run: `task install PROVIDER=google`
Expected: pods Running in `otel-poc-google` (`kubectl -n otel-poc-google get pods`).

- [ ] **Step 5: add `debug` exporter temporarily** — set collector pipelines to also export `debug`; submit an order:

```bash
kubectl -n otel-poc-google port-forward svc/api 8080:80 &
curl -XPOST localhost:8080/orders -H 'content-type: application/json' -d '{"sku":"A","quantity":2}'
kubectl -n otel-poc-google logs deploy/collector | grep -E "orders publish|orders process|firestore upsert"
```
Expected: publish span → consume span (child) → firestore span visible; trace ids link.

- [ ] **Step 6: confirm in Google Cloud Trace UI** the end-to-end trace appears.
- [ ] **Step 7: Commit** any config fixes (`fix: local google bring-up`).

### Task 8.2: Dash0 + Coralogix releases

- [ ] **Step 1:** `task install PROVIDER=dash0` (needs `dash0-token` GSM secret + region/dataset in values). Submit order, confirm trace in Dash0 UI. Note the browser-span unsupported-path caveat.
- [ ] **Step 2:** `task install PROVIDER=coralogix` (needs `coralogix-key` + domain). Submit order, confirm in Coralogix UI.
- [ ] **Step 3: Commit** (`docs: local validation notes for all three backends`).

---

## Phase 9 — Infra: GKE

### Task 9.1: GKE module

**Files:** Create `infra/modules/gke/{main.tf,variables.tf,versions.tf,outputs.tf}`, `infra/live/gke/terragrunt.hcl`

- [ ] **Step 1: `main.tf`** — GKE cluster (Workload Identity enabled), Artifact Registry repo, GCP service account + IAM `roles/secretmanager.secretAccessor`, WIF binding for `[otel-poc-<release>/otel-poc]` × 3 releases, GSM secrets (`dash0-token`, `coralogix-key`), and per-release logical objects: 3 Pub/Sub topics+subscriptions, 3 Cloud SQL databases, Firestore DB. Loop over `for_each = toset(["google","dash0","coralogix"])`.
- [ ] **Step 2:** Memorystore (Redis) instance shared; Cloud SQL (Postgres) instance shared; per-release DB via `google_sql_database`.
- [ ] **Step 3: `live/gke/terragrunt.hcl`** — source + inputs (project, region).
- [ ] **Step 4: validate + plan**

Run: `cd infra/live/gke && terragrunt validate && terragrunt plan`
Expected: valid plan; review resource counts (3 topics/subs/DBs).

- [ ] **Step 5: Commit** (`feat(infra): GKE module — cluster, AR, WIF, GSM, per-release logical deps`)

### Task 9.2: GKE deploy

- [ ] **Step 1:** `terragrunt apply` (gke). Configure `kubectl` context.
- [ ] **Step 2:** build + push images to Artifact Registry; `helm upgrade --install` each provider with `values-gke.yaml` (`--set image.registry=<AR path> image.tag=<sha> gcpProject=<proj>`).
- [ ] **Step 3:** validate one order per namespace appears in each backend; confirm WIF (pods read GSM, no key files).
- [ ] **Step 4: Commit** (`docs: GKE validation notes`).

---

## Phase 10 — k6 + comparison docs

### Task 10.1: k6 scenario

**Files:** Create `load/order-scenario.js`

- [ ] **Step 1:** k6 script POSTing `/orders` at bounded RPS for a fixed duration against a target base URL (env `API_URL`), with think time.
- [ ] **Step 2:** document run command per namespace and the sampling rate used (cost guard).
- [ ] **Step 3: Commit** (`feat(load): k6 order scenario`).

### Task 10.2: Comparison report

**Files:** Create `docs/comparison/README.md`

- [ ] **Step 1:** matrix table (trace UX, log↔trace correlation, metrics, ingest lag, browser/RUM — Dash0 pure-OTel unsupported-path note, session replay = Coralogix-only/not-OTel, query/alerting, cost). Capture screenshots per backend.
- [ ] **Step 2: Commit** (`docs: backend comparison report`).

---

## Sequencing notes

- Phases 1→5 are pure local builds (no cloud). Phase 8 is the first runtime checkpoint — stop and validate the span tree before adding backends.
- The single highest-risk item is the **Pub/Sub traceparent shim** (Task 1.6 + validated in 8.1 step 5). If the consume span is not a child of the publish span, fix before proceeding.
- GKE (Phase 9) costs money; do Phases 1–8 fully on kind first.
