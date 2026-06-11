using Google.Cloud.SecretManager.V1;
using Microsoft.Extensions.Caching.Memory;
namespace Core.Secrets;

public sealed class GsmSecretProvider(string projectId, IMemoryCache cache) : ISecretProvider
{
    private readonly SecretManagerServiceClient _client = SecretManagerServiceClient.Create();

    public async Task<string> GetAsync(string name, CancellationToken ct = default)
        => await cache.GetOrCreateAsync(name, async _ =>
        {
            var path = new SecretVersionName(projectId, name, "latest");
            var result = await _client.AccessSecretVersionAsync(path, ct);
            return result.Payload.Data.ToStringUtf8();
        }) ?? throw new InvalidOperationException($"secret {name} empty");
}
