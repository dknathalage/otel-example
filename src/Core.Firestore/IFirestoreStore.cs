namespace Core.Firestore;
public interface IFirestoreStore
{
    Task UpsertStatusAsync(Guid orderId, string status, CancellationToken ct = default);
}
