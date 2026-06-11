namespace Core.Redis;
public interface IRedisCache
{
    // returns true if this key was newly set (i.e. not a duplicate)
    Task<bool> TryMarkAsync(string key, TimeSpan ttl, CancellationToken ct = default);
}
