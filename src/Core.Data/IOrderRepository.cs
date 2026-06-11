namespace Core.Data;
public interface IOrderRepository
{
    Task AddAsync(OrderEntity order, CancellationToken ct = default);
}

public sealed class OrderRepository(OrdersDbContext db) : IOrderRepository
{
    public async Task AddAsync(OrderEntity order, CancellationToken ct = default)
    {
        db.Orders.Add(order);
        await db.SaveChangesAsync(ct); // Npgsql auto-instrumented → DB span automatic
    }
}
