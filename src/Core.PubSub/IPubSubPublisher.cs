namespace Core.PubSub;
public interface IPubSubPublisher
{
    Task PublishAsync(OrderMessage message, CancellationToken ct = default);
}
public interface IPubSubSubscriber
{
    Task StartAsync(Func<OrderMessage, CancellationToken, Task> handler, CancellationToken ct);
}
