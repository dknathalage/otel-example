using Api.Endpoints;
using Microsoft.EntityFrameworkCore;
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

// Browser (web at :3000) posts orders directly to this API (:8080) — cross-origin.
// W3C traceparent must be allowed through so browser→api trace propagation works.
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins("http://localhost:3000")
    .AllowAnyHeader()
    .AllowAnyMethod()));

var app = builder.Build();
app.UseCors();
using (var scope = app.Services.CreateScope())
    scope.ServiceProvider.GetRequiredService<OrdersDbContext>().Database.Migrate();
app.MapOrders();
app.MapGet("/healthz", () => Results.Ok());
app.Run();
