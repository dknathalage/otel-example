using OpenTelemetry.Context.Propagation;
namespace Core.Telemetry;

public static class Propagation
{
    // Inject current context into a string dictionary (Pub/Sub message attributes)
    public static void Inject(IDictionary<string, string> carrier)
        => Telemetry.Propagator.Inject(
            new PropagationContext(System.Diagnostics.Activity.Current?.Context ?? default, default),
            carrier, static (c, k, v) => c[k] = v);

    public static PropagationContext Extract(IReadOnlyDictionary<string, string> carrier)
        => Telemetry.Propagator.Extract(default, carrier,
            static (c, k) => c.TryGetValue(k, out var v) ? new[] { v } : Array.Empty<string>());
}
