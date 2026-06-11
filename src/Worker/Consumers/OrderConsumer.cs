using Core.Firestore;
using Core.PubSub;
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
            using var _ = log.BeginScope(new Dictionary<string, object>
            {
                [Core.Logging.LoggingConventions.OrderId] = order.Id
            });
            await store.UpsertStatusAsync(order.Id, "processed", ct);
            log.LogInformation("order {OrderId} processed", order.Id);
        }, stoppingToken);
}
