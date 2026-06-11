using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
namespace Core.Logging;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreLogging(this IServiceCollection s)
    {
        s.AddLogging(b => b.Configure(o =>
            o.ActivityTrackingOptions =
                ActivityTrackingOptions.TraceId | ActivityTrackingOptions.SpanId));
        return s;
    }
}
