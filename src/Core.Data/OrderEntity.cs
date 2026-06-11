namespace Core.Data;
public class OrderEntity
{
    public Guid Id { get; set; }
    public string Sku { get; set; } = "";
    public int Quantity { get; set; }
    public string Status { get; set; } = "created";
    public DateTimeOffset CreatedAt { get; set; }
}
