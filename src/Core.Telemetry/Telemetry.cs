using System.Diagnostics;
using OpenTelemetry.Context.Propagation;

namespace Core.Telemetry;

public static class Telemetry
{
    public const string SourceName = "OtelPoc";
    public static readonly ActivitySource Source = new(SourceName);
    public static readonly TextMapPropagator Propagator =
        Propagators.DefaultTextMapPropagator; // W3C TraceContext + Baggage
}
