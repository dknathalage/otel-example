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

var app = builder.Build();
using (var scope = app.Services.CreateScope())
    scope.ServiceProvider.GetRequiredService<OrdersDbContext>().Database.Migrate();
app.MapOrders();
app.MapGet("/healthz", () => Results.Ok());
app.Run();
