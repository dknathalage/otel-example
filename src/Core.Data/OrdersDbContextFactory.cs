using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
namespace Core.Data;

// Design-time only: lets `dotnet ef migrations` build OrdersDbContext without
// spinning up the application host (whose AddCore* wiring needs live config).
// Not used at runtime — the app builds the context via AddCoreData/DI.
public sealed class OrdersDbContextFactory : IDesignTimeDbContextFactory<OrdersDbContext>
{
    public OrdersDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<OrdersDbContext>()
            .UseNpgsql("Host=localhost;Database=orders;Username=postgres")
            .Options;
        return new OrdersDbContext(options);
    }
}
