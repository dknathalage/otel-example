using System.Diagnostics;
using Core.Telemetry;
using Google.Cloud.Firestore;
namespace Core.Firestore;

public sealed class FirestoreStore(FirestoreDb db, string collectionPrefix) : IFirestoreStore
{
    public async Task UpsertStatusAsync(Guid orderId, string status, CancellationToken ct = default)
    {
        using var activity = Telemetry.Telemetry.Source.StartActivity("firestore upsert", ActivityKind.Client);
        activity?.SetTag("db.system", "firestore");
        activity?.SetTag("db.collection.name", $"{collectionPrefix}orders");
        var doc = db.Collection($"{collectionPrefix}orders").Document(orderId.ToString());
        await doc.SetAsync(new { status, updatedAt = Timestamp.GetCurrentTimestamp() },
            SetOptions.MergeAll, ct);
    }
}
