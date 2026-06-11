using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Secrets;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreSecrets(this IServiceCollection s, IConfiguration cfg)
    {
        s.AddMemoryCache();
        var project = cfg["Gcp:ProjectId"] ?? throw new InvalidOperationException("Gcp:ProjectId missing");
        s.AddSingleton<ISecretProvider>(sp =>
            new GsmSecretProvider(project, sp.GetRequiredService<IMemoryCache>()));
        return s;
    }
}
