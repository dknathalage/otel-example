FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY . .
RUN dotnet publish src/Worker -c Release -o /app
FROM mcr.microsoft.com/dotnet/runtime:10.0
WORKDIR /app
RUN apt-get update && apt-get install -y curl unzip && rm -rf /var/lib/apt/lists/*
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
RUN curl -sSfL https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/latest/download/otel-dotnet-auto-install.sh -O \
    && bash ./otel-dotnet-auto-install.sh
ENV CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318} \
    CORECLR_PROFILER_PATH=/otel-dotnet-auto/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so \
    DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps \
    DOTNET_SHARED_STORE=/otel-dotnet-auto/store \
    DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll \
    OTEL_SERVICE_NAME=worker
COPY --from=build /app .
ENTRYPOINT ["dotnet", "Worker.dll"]
