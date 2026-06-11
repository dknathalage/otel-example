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
            using var activity = Telemetry.Telemetry.Source.StartActivity(
                "orders process", ActivityKind.Consumer, parent.ActivityContext);
            activity?.SetTag("messaging.system", "gcp_pubsub");

            var order = JsonSerializer.Deserialize<OrderMessage>(msg.Data.ToStringUtf8())!;
            await handler(order, mct);
            return SubscriberClient.Reply.Ack;
        });
}
