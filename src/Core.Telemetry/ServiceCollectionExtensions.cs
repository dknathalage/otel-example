using Microsoft.Extensions.DependencyInjection;
namespace Core.Telemetry;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreTelemetry(this IServiceCollection s) => s;
    // ActivitySource is static; nothing to register yet. Hook kept for symmetry.
}
