using Microsoft.EntityFrameworkCore;
namespace Core.Data;
public class OrdersDbContext(DbContextOptions<OrdersDbContext> o) : DbContext(o)
{
    public DbSet<OrderEntity> Orders => Set<OrderEntity>();
}
