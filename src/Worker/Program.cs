using Core.Firestore;
using Core.Logging;
using Core.PubSub;
using Core.Secrets;
using Core.Telemetry;
using Worker.Consumers;

var builder = Host.CreateApplicationBuilder(args);
builder.Services
    .AddCoreSecrets(builder.Configuration)
    .AddCoreTelemetry()
    .AddCoreLogging()
    .AddCorePubSubSubscriber(builder.Configuration)
    .AddCoreFirestore(builder.Configuration);
builder.Services.AddHostedService<OrderConsumer>();
builder.Build().Run();
