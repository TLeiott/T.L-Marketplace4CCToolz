using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

// --- Configuration ---
var openRouterApiKey = Environment.GetEnvironmentVariable("OPENROUTER_API_KEY")
    ?? throw new InvalidOperationException("OPENROUTER_API_KEY environment variable is not set.");

var upstreamBase = Environment.GetEnvironmentVariable("OPENROUTER_BASE_URL")
    ?? "https://openrouter.ai/api/";

// Ensure trailing slash — Uri relative resolution requires it
if (!upstreamBase.EndsWith('/'))
    upstreamBase += '/';

var port = ResolvePort(args);

// --- Builder ---
var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Logging.AddFilter("OpenRouterProxy", LogLevel.Information);

builder.WebHost.UseUrls($"http://127.0.0.1:{port}");

builder.Services.AddHttpClient("upstream", client =>
{
    client.Timeout = TimeSpan.FromMinutes(10);
});

var app = builder.Build();

// --- Health endpoint (before middleware) ---
app.MapGet("/health", () => Results.Ok(new { status = "ok", version = 2, port }));

// --- Proxy middleware ---
app.UseMiddleware<OpenRouterProxyMiddleware>(openRouterApiKey, upstreamBase);

// --- Lock file lifecycle ---
var lockFilePath = GetLockFilePath();
var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();

lifetime.ApplicationStarted.Register(() =>
{
    WriteLockFile(lockFilePath, port);
    Console.Error.WriteLine($"OpenRouterProxy daemon listening on http://127.0.0.1:{port}");
});

lifetime.ApplicationStopping.Register(() => DeleteLockFile(lockFilePath));
AppDomain.CurrentDomain.ProcessExit += (_, _) => DeleteLockFile(lockFilePath);

app.Run();

// --- Helpers ---

static int ResolvePort(string[] args)
{
    for (int i = 0; i < args.Length - 1; i++)
    {
        if (args[i] == "--port" && int.TryParse(args[i + 1], out var p))
            return p;
    }
    var envPort = Environment.GetEnvironmentVariable("PROXY_PORT");
    if (envPort != null && int.TryParse(envPort, out var ep))
        return ep;
    return 18080;
}

static string GetLockFilePath()
{
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var dir = Path.Combine(home, ".claude", "claude-custom");
    Directory.CreateDirectory(dir);
    return Path.Combine(dir, "proxy.lock");
}

static void WriteLockFile(string path, int port)
{
    var tmpPath = path + ".tmp";
    var content = $"pid={Environment.ProcessId}\nport={port}\nstarted={DateTime.UtcNow:o}\nversion=2\n";
    File.WriteAllText(tmpPath, content);
    File.Move(tmpPath, path, overwrite: true);
}

static void DeleteLockFile(string path)
{
    try { File.Delete(path); } catch { }
}

// --- Middleware ---

public class OpenRouterProxyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly string _openRouterApiKey;
    private readonly string _upstreamBase;

    public OpenRouterProxyMiddleware(RequestDelegate next, IHttpClientFactory httpClientFactory, string openRouterApiKey, string upstreamBase)
    {
        _next = next;
        _httpClientFactory = httpClientFactory;
        _openRouterApiKey = openRouterApiKey;
        _upstreamBase = upstreamBase;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var rawPath = context.Request.Path.Value ?? "/";
        var queryString = context.Request.QueryString.Value ?? "";
        var method = context.Request.Method;

        if (rawPath.Equals("/health", StringComparison.OrdinalIgnoreCase))
        {
            await _next(context);
            return;
        }

        if (method == "OPTIONS")
        {
            context.Response.Headers.Append("Access-Control-Allow-Origin", "*");
            context.Response.Headers.Append("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
            context.Response.Headers.Append("Access-Control-Allow-Headers", "*");
            return;
        }

        // --- Extract provider from URL path ---
        string? provider = null;
        string upstreamPath;

        if (rawPath.StartsWith("/route/", StringComparison.OrdinalIgnoreCase))
        {
            var afterRoute = rawPath["/route/".Length..];
            var slashIdx = afterRoute.IndexOf('/');
            if (slashIdx < 0)
            {
                provider = Uri.UnescapeDataString(afterRoute);
                upstreamPath = "/";
            }
            else
            {
                provider = Uri.UnescapeDataString(afterRoute[..slashIdx]);
                upstreamPath = afterRoute[slashIdx..];
            }

            if (string.IsNullOrWhiteSpace(provider))
            {
                context.Response.StatusCode = 502;
                context.Response.ContentType = "application/json";
                var error = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    error = "empty_provider",
                    detail = "Provider extracted from /route/ prefix was empty."
                });
                await context.Response.Body.WriteAsync(error);
                return;
            }
        }
        else
        {
            upstreamPath = rawPath;
        }

        var targetUri = new Uri(new Uri(_upstreamBase), upstreamPath.TrimStart('/') + queryString);

        // --- Read and optionally modify body ---
        byte[]? originalBody = null;
        if (method == "POST" && upstreamPath.Contains("/v1/messages", StringComparison.OrdinalIgnoreCase))
        {
            originalBody = await ReadBodyAsync(context.Request.Body);
        }

        using var upstreamRequest = new HttpRequestMessage(new HttpMethod(method), targetUri);

        if (originalBody != null)
        {
            byte[] modifiedBody;
            try
            {
                modifiedBody = InjectProviderRouting(originalBody, provider);
            }
            catch (Exception ex)
            {
                context.Response.StatusCode = 502;
                context.Response.ContentType = "application/json";
                var error = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    error = "provider_routing_failed",
                    detail = ex.Message,
                    requested_provider = provider
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

        // --- Forward headers ---
        foreach (var header in context.Request.Headers)
        {
            var key = header.Key;
            if (key.Equals("Host", StringComparison.OrdinalIgnoreCase)) continue;
            if (key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;

            upstreamRequest.Headers.TryAddWithoutValidation(key, header.Value.AsEnumerable());
        }

        upstreamRequest.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _openRouterApiKey);

        // --- Send upstream ---
        using var httpClient = _httpClientFactory.CreateClient("upstream");
        using var upstreamResponse = await httpClient.SendAsync(upstreamRequest, HttpCompletionOption.ResponseHeadersRead);

        context.Response.StatusCode = (int)upstreamResponse.StatusCode;

        // Filter hop-by-hop headers — HttpClient already decoded Transfer-Encoding
        foreach (var header in upstreamResponse.Headers)
        {
            var key = header.Key;
            if (key.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)) continue;
            if (key.Equals("Connection", StringComparison.OrdinalIgnoreCase)) continue;
            if (key.Equals("Keep-Alive", StringComparison.OrdinalIgnoreCase)) continue;
            context.Response.Headers.Append(key, header.Value.ToArray());
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

        // --- Normalize usage in response and forward ---
        var contentType = upstreamResponse.Content.Headers.ContentType?.MediaType ?? "";

        if (contentType.Contains("text/event-stream", StringComparison.OrdinalIgnoreCase))
        {
            context.Response.ContentLength = null;
            await NormalizeSseResponseAsync(
                await upstreamResponse.Content.ReadAsStreamAsync(),
                context.Response.Body,
                context.RequestAborted);
        }
        else if (contentType.Contains("application/json", StringComparison.OrdinalIgnoreCase))
        {
            context.Response.ContentLength = null;
            await NormalizeJsonResponseAsync(
                upstreamResponse.Content,
                context.Response.Body,
                context.RequestAborted);
        }
        else
        {
            await upstreamResponse.Content.CopyToAsync(context.Response.Body);
        }
    }

    private static async Task<byte[]> ReadBodyAsync(Stream body)
    {
        using var ms = new MemoryStream();
        await body.CopyToAsync(ms);
        return ms.ToArray();
    }

    private static byte[] InjectProviderRouting(byte[] originalBody, string? provider)
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
            ["allow_fallbacks"] = false
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

    // --- Usage normalization ---

    /// Reads SSE line-by-line, forwarding non-target events immediately.
    /// When a message_delta event with usage is detected, normalizes tokens.
    private static async Task NormalizeSseResponseAsync(
        Stream source, Stream dest, CancellationToken ct)
    {
        var lineBuffer = new StringBuilder();
        var dataLines = new List<string>();
        var eventLines = new List<string>();
        await using var writer = new StreamWriter(dest, Encoding.UTF8, 1024, leaveOpen: true);
        writer.AutoFlush = true;

        var buffer = new byte[1];
        while (true)
        {
            var bytesRead = await source.ReadAsync(buffer, ct);
            if (bytesRead == 0)
            {
                if (eventLines.Count > 0)
                    await ProcessSseEventAsync(dataLines, eventLines, writer, ct);
                return;
            }

            if (buffer[0] == '\n')
            {
                var line = lineBuffer.ToString();
                lineBuffer.Clear();

                if (string.IsNullOrEmpty(line))
                {
                    await ProcessSseEventAsync(dataLines, eventLines, writer, ct);
                    await writer.WriteLineAsync();
                    dataLines.Clear();
                    eventLines.Clear();
                }
                else
                {
                    eventLines.Add(line);
                    if (line.StartsWith("data: "))
                        dataLines.Add(line["data: ".Length..]);
                }
            }
            else if (buffer[0] == '\r')
            {
                var nextBytesRead = await source.ReadAsync(buffer, ct);
                var line = lineBuffer.ToString();
                lineBuffer.Clear();

                if (nextBytesRead > 0 && buffer[0] == '\n')
                {
                    // \r\n
                    if (string.IsNullOrEmpty(line))
                    {
                        await ProcessSseEventAsync(dataLines, eventLines, writer, ct);
                        await writer.WriteLineAsync();
                        dataLines.Clear();
                        eventLines.Clear();
                    }
                    else
                    {
                        eventLines.Add(line);
                        if (line.StartsWith("data: "))
                            dataLines.Add(line["data: ".Length..]);
                    }
                }
                else
                {
                    // bare \r
                    if (string.IsNullOrEmpty(line))
                    {
                        await ProcessSseEventAsync(dataLines, eventLines, writer, ct);
                        await writer.WriteLineAsync();
                        dataLines.Clear();
                        eventLines.Clear();
                    }
                    else
                    {
                        eventLines.Add(line);
                        if (line.StartsWith("data: "))
                            dataLines.Add(line["data: ".Length..]);
                    }
                    if (nextBytesRead > 0)
                        lineBuffer.Append((char)buffer[0]);
                }
            }
            else
            {
                lineBuffer.Append((char)buffer[0]);
            }
        }
    }

    /// Processes a complete SSE event. If it's a message_delta with usage, normalizes tokens.
    /// Otherwise forwards the event lines as-is.
    private static async Task ProcessSseEventAsync(
        List<string> dataLines,
        List<string> eventLines,
        StreamWriter writer,
        CancellationToken ct)
    {
        if (dataLines.Count == 0)
        {
            foreach (var line in eventLines)
                await writer.WriteLineAsync(line);
            return;
        }

        for (int i = 0; i < dataLines.Count; i++)
        {
            var payload = dataLines[i];
            bool isMessageDelta = payload.Contains("\"type\":\"message_delta\"")
                               || payload.Contains("\"type\": \"message_delta\"");

            if (isMessageDelta && (payload.Contains("\"usage\":") || payload.Contains("\"usage\" :")))
            {
                var fullPayload = string.Concat(dataLines);
                var modified = NormalizeMessageDeltaUsage(fullPayload);
                if (modified != null)
                {
                    await writer.WriteLineAsync("data: " + modified);
                    foreach (var line in eventLines)
                    {
                        if (!line.StartsWith("data: "))
                            await writer.WriteLineAsync(line);
                    }
                    return;
                }
                break;
            }
        }

        foreach (var line in eventLines)
            await writer.WriteLineAsync(line);
    }

    /// Normalizes the usage field in a message_delta SSE event payload.
    /// Sets input_tokens to 0, preserves output_tokens.
    /// Returns the modified JSON string, or null if no usage field found.
    private static string? NormalizeMessageDeltaUsage(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (!root.TryGetProperty("usage", out var usage))
            return null;

        int outputTokens = 0;
        if (usage.TryGetProperty("output_tokens", out var ot))
            outputTokens = ot.GetInt32();

        using var ms = new MemoryStream();
        using var jw = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = false });

        jw.WriteStartObject();

        foreach (var prop in root.EnumerateObject())
        {
            if (prop.NameEquals("usage"))
            {
                jw.WritePropertyName("usage");
                jw.WriteStartObject();
                jw.WriteNumber("input_tokens", 0);
                jw.WriteNumber("output_tokens", outputTokens);

                if (usage.TryGetProperty("cache_creation_input_tokens", out var ccit))
                    jw.WriteNumber("cache_creation_input_tokens", ccit.GetDouble());
                if (usage.TryGetProperty("cache_read_input_tokens", out var crit))
                    jw.WriteNumber("cache_read_input_tokens", crit.GetDouble());
                if (usage.TryGetProperty("num_cached_tokens", out var nct))
                    jw.WriteNumber("num_cached_tokens", nct.GetDouble());

                jw.WriteEndObject();
            }
            else
            {
                jw.WritePropertyName(prop.Name);
                prop.Value.WriteTo(jw);
            }
        }

        jw.WriteEndObject();
        jw.Flush();

        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// Normalizes usage in non-streaming JSON responses.
    private static async Task NormalizeJsonResponseAsync(
        HttpContent content, Stream dest, CancellationToken ct)
    {
        var bytes = await content.ReadAsByteArrayAsync(ct);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (!root.TryGetProperty("usage", out _))
        {
            await dest.WriteAsync(bytes, ct);
            return;
        }

        int outputTokens = 0;
        if (root.TryGetProperty("usage", out var usage) && usage.TryGetProperty("output_tokens", out var ot))
            outputTokens = ot.GetInt32();

        using var ms = new MemoryStream();
        using var jw = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = false });

        jw.WriteStartObject();
        foreach (var prop in root.EnumerateObject())
        {
            if (prop.NameEquals("usage"))
            {
                jw.WritePropertyName("usage");
                jw.WriteStartObject();
                jw.WriteNumber("input_tokens", 0);
                jw.WriteNumber("output_tokens", outputTokens);
                jw.WriteEndObject();
            }
            else
            {
                jw.WritePropertyName(prop.Name);
                prop.Value.WriteTo(jw);
            }
        }
        jw.WriteEndObject();
        jw.Flush();

        await dest.WriteAsync(ms.ToArray(), ct);
    }
}
