namespace Core.Secrets;
public interface ISecretProvider
{
    Task<string> GetAsync(string name, CancellationToken ct = default);
}
