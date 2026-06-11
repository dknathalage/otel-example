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
            using var _ = log.BeginScope(new Dictionary<string, object> {
                [Core.Logging.LoggingConventions.OrderId] = id });
            await pub.PublishAsync(new OrderMessage(id, req.Sku, req.Quantity), ct);
            log.LogInformation("order {OrderId} created", id);
            return Results.Accepted($"/orders/{id}", new { id });
        });
    }
}
