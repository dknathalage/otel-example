using Google.Cloud.Firestore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Firestore;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreFirestore(this IServiceCollection s, IConfiguration cfg)
    {
        var project = cfg["Firestore:ProjectId"]!;
        var prefix = cfg["Firestore:CollectionPrefix"] ?? "";
        s.AddSingleton(_ => FirestoreDb.Create(project));
        s.AddSingleton<IFirestoreStore>(sp =>
            new FirestoreStore(sp.GetRequiredService<FirestoreDb>(), prefix));
        return s;
    }
}
