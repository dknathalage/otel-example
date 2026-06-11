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
        using var activity = Telemetry.Telemetry.Source.StartActivity(
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
