using StackExchange.Redis;
namespace Core.Redis;
public sealed class RedisCache(IConnectionMultiplexer mux, string prefix) : IRedisCache
{
    public async Task<bool> TryMarkAsync(string key, TimeSpan ttl, CancellationToken ct = default)
        => await mux.GetDatabase().StringSetAsync($"{prefix}{key}", "1", ttl, When.NotExists);
}
