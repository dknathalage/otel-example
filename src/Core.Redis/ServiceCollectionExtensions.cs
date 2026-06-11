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
