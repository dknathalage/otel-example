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
