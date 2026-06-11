using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
namespace Core.Data;
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCoreData(this IServiceCollection s, IConfiguration cfg)
    {
        s.AddDbContext<OrdersDbContext>(o => o.UseNpgsql(cfg.GetConnectionString("Orders")));
        s.AddScoped<IOrderRepository, OrderRepository>();
        return s;
    }
}
