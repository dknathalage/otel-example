namespace Core.PubSub;
public record OrderMessage(Guid Id, string Sku, int Quantity);
