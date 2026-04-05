using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

var openRouterApiKey = Environment.GetEnvironmentVariable("OPENROUTER_API_KEY")
    ?? throw new InvalidOperationException("OPENROUTER_API_KEY environment variable is not set.");

var upstreamBase = Environment.GetEnvironmentVariable("OPENROUTER_BASE_URL")
    ?? "https://openrouter.ai/api";

var defaultProvider = Environment.GetEnvironmentVariable("DEFAULT_PROVIDER") ?? "";
var defaultAllowFallbacks = Environment.GetEnvironmentVariable("DEFAULT_ALLOW_FALLBACKS") != "false";

var app = builder.Build();

app.UseMiddleware<OpenRouterProxyMiddleware>(openRouterApiKey, upstreamBase, defaultProvider, defaultAllowFallbacks);

app.Run();

public class OpenRouterProxyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly string _openRouterApiKey;
    private readonly string _upstreamBase;
    private readonly string? _defaultProvider;
    private readonly bool _defaultAllowFallbacks;

    public OpenRouterProxyMiddleware(RequestDelegate next, string openRouterApiKey, string upstreamBase, string? defaultProvider, bool defaultAllowFallbacks)
    {
        _next = next;
        _openRouterApiKey = openRouterApiKey;
        _upstreamBase = upstreamBase;
        _defaultProvider = defaultProvider;
        _defaultAllowFallbacks = defaultAllowFallbacks;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var requestPath = context.Request.Path.Value ?? "/";
        var method = context.Request.Method;

        if (method == "OPTIONS")
        {
            context.Response.Headers.Append("Access-Control-Allow-Origin", "*");
            context.Response.Headers.Append("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
            context.Response.Headers.Append("Access-Control-Allow-Headers", "*");
            return;
        }

        var targetUri = new Uri(new Uri(_upstreamBase), requestPath.TrimStart('/'));

        byte[]? originalBody = null;
        if (method == "POST" && requestPath.Contains("/v1/messages", StringComparison.OrdinalIgnoreCase))
        {
            originalBody = await ReadBodyAsync(context.Request.Body);
        }

        using var upstreamRequest = new HttpRequestMessage(new HttpMethod(method), targetUri);

        if (originalBody != null)
        {
            byte[] modifiedBody;
            try
            {
                modifiedBody = InjectProviderRouting(originalBody, _defaultProvider, _defaultAllowFallbacks);
            }
            catch (Exception ex)
            {
                context.Response.StatusCode = 502;
                context.Response.ContentType = "application/json";
                var error = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    error = "provider_routing_failed",
                    detail = ex.Message,
                    requested_provider = _defaultProvider
                });
                await context.Response.Body.WriteAsync(error);
                return;
            }
            upstreamRequest.Content = new ByteArrayContent(modifiedBody);
            upstreamRequest.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        }
        else if (context.Request.ContentLength > 0)
        {
            var bodyBytes = await ReadBodyAsync(context.Request.Body);
            upstreamRequest.Content = new ByteArrayContent(bodyBytes);
            if (context.Request.ContentType != null)
                upstreamRequest.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(context.Request.ContentType);
        }

        foreach (var header in context.Request.Headers)
        {
            var key = header.Key;
            if (key.Equals("Host", StringComparison.OrdinalIgnoreCase)) continue;
            if (key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;

            upstreamRequest.Headers.TryAddWithoutValidation(key, header.Value.AsEnumerable());
        }

        upstreamRequest.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _openRouterApiKey);

        using var httpClient = new HttpClient();
        httpClient.Timeout = TimeSpan.FromMinutes(10);

        using var upstreamResponse = await httpClient.SendAsync(upstreamRequest, HttpCompletionOption.ResponseHeadersRead);

        context.Response.StatusCode = (int)upstreamResponse.StatusCode;

        foreach (var header in upstreamResponse.Headers)
        {
            context.Response.Headers.Append(header.Key, header.Value.ToArray());
        }

        if (upstreamResponse.Content.Headers.ContentType != null)
        {
            context.Response.ContentType = upstreamResponse.Content.Headers.ContentType.ToString();
        }

        if (upstreamResponse.Content.Headers.ContentLength.HasValue)
        {
            context.Response.ContentLength = upstreamResponse.Content.Headers.ContentLength.Value;
        }
        else
        {
            context.Response.ContentLength = null;
        }

        await upstreamResponse.Content.CopyToAsync(context.Response.Body);
    }

    private static async Task<byte[]> ReadBodyAsync(Stream body)
    {
        using var ms = new MemoryStream();
        await body.CopyToAsync(ms);
        return ms.ToArray();
    }

    private static byte[] InjectProviderRouting(byte[] originalBody, string? provider, bool allowFallbacks)
    {
        if (string.IsNullOrEmpty(provider))
        {
            return originalBody;
        }

        using var doc = JsonDocument.Parse(originalBody);
        var root = doc.RootElement.Clone();

        var providerObj = new Dictionary<string, object?>
        {
            ["only"] = new[] { provider },
            ["allow_fallbacks"] = allowFallbacks
        };

        var output = new Dictionary<string, object?>();

        foreach (var prop in root.EnumerateObject())
        {
            output[prop.Name] = prop.Value.ValueKind switch
            {
                JsonValueKind.String => prop.Value.GetString(),
                JsonValueKind.Number => prop.Value.GetDouble(),
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.Null => null,
                JsonValueKind.Object => JsonSerializer.Deserialize<Dictionary<string, object?>>(prop.Value.GetRawText()),
                JsonValueKind.Array => JsonSerializer.Deserialize<List<object?>>(prop.Value.GetRawText()),
                _ => prop.Value.GetRawText()
            };
        }

        output["provider"] = providerObj;

        return JsonSerializer.SerializeToUtf8Bytes(output);
    }
}
