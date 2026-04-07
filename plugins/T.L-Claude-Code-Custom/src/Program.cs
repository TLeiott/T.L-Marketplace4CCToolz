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
builder.Logging.AddConsole(options =>
{
    options.LogToStandardErrorThreshold = LogLevel.Trace;
});
builder.Logging.SetMinimumLevel(LogLevel.Information);

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
    private readonly ILogger<OpenRouterProxyMiddleware> _logger;

    public OpenRouterProxyMiddleware(RequestDelegate next, IHttpClientFactory httpClientFactory, string openRouterApiKey, string upstreamBase, ILogger<OpenRouterProxyMiddleware> logger)
    {
        _next = next;
        _httpClientFactory = httpClientFactory;
        _openRouterApiKey = openRouterApiKey;
        _upstreamBase = upstreamBase;
        _logger = logger;
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

        // --- Log incoming request ---
        _logger.LogInformation("======== REQUEST ========");
        _logger.LogInformation(">> {Method} {Path} -> {TargetUri}", method, rawPath, targetUri);
        _logger.LogInformation(">> Provider: {Provider}", provider ?? "(none)");
        _logger.LogInformation(">> Client headers:");
        foreach (var h in context.Request.Headers)
        {
            var val = h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                   || h.Key.Equals("x-api-key", StringComparison.OrdinalIgnoreCase)
                ? $"{h.Value.ToString()[..Math.Min(16, h.Value.ToString().Length)]}..." : h.Value.ToString();
            _logger.LogInformation(">>   {Key}: {Value}", h.Key, val);
        }

        // --- Read body for ALL POST requests (not just /v1/messages) ---
        byte[]? originalBody = null;
        if (method == "POST" || method == "PUT" || method == "PATCH")
        {
            originalBody = await ReadBodyAsync(context.Request.Body);
            // Log body details
            if (originalBody.Length > 0)
            {
                try
                {
                    using var bodyDoc = JsonDocument.Parse(originalBody);
                    var bodyRoot = bodyDoc.RootElement;
                    var model = bodyRoot.TryGetProperty("model", out var m) ? m.GetString() : null;
                    var msgCount = bodyRoot.TryGetProperty("messages", out var msgs) ? msgs.GetArrayLength() : -1;
                    var stream = bodyRoot.TryGetProperty("stream", out var s) && s.GetBoolean();
                    var maxTokens = bodyRoot.TryGetProperty("max_tokens", out var mt) ? mt.GetInt32() : -1;

                    _logger.LogInformation(">> Body ({Bytes} bytes):", originalBody.Length);
                    if (model != null) _logger.LogInformation(">>   model: {Model}", model);
                    if (msgCount >= 0) _logger.LogInformation(">>   messages: {Count}", msgCount);
                    if (maxTokens >= 0) _logger.LogInformation(">>   max_tokens: {MaxTokens}", maxTokens);
                    _logger.LogInformation(">>   stream: {Stream}", stream);

                    // Log all top-level keys
                    var keys = new List<string>();
                    foreach (var prop in bodyRoot.EnumerateObject())
                        keys.Add(prop.Name);
                    _logger.LogInformation(">>   all keys: [{Keys}]", string.Join(", ", keys));
                }
                catch
                {
                    // Not JSON — log raw preview
                    _logger.LogInformation(">> Body ({Bytes} bytes, non-JSON): {Preview}",
                        originalBody.Length, Encoding.UTF8.GetString(originalBody[..Math.Min(200, originalBody.Length)]));
                }
            }
        }

        using var upstreamRequest = new HttpRequestMessage(new HttpMethod(method), targetUri);

        if (originalBody != null && upstreamPath.Contains("/v1/messages", StringComparison.OrdinalIgnoreCase))
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
        else if (originalBody != null && originalBody.Length > 0)
        {
            // POST/PUT/PATCH to non-messages endpoint — forward body as-is
            upstreamRequest.Content = new ByteArrayContent(originalBody);
            if (context.Request.ContentType != null)
                upstreamRequest.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(context.Request.ContentType);
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

        // Log outgoing upstream headers
        _logger.LogInformation(">> Upstream headers:");
        foreach (var h in upstreamRequest.Headers)
        {
            var val = h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                ? $"{string.Join(",", h.Value)[..Math.Min(20, string.Join(",", h.Value).Length)]}..."
                : string.Join(",", h.Value);
            _logger.LogInformation(">>   {Key}: {Value}", h.Key, val);
        }

        // --- Send upstream ---
        using var httpClient = _httpClientFactory.CreateClient("upstream");
        using var upstreamResponse = await httpClient.SendAsync(upstreamRequest, HttpCompletionOption.ResponseHeadersRead);

        var statusCode = (int)upstreamResponse.StatusCode;
        _logger.LogInformation("======== RESPONSE ========");
        _logger.LogInformation("<< {StatusCode} {ContentType}",
            statusCode,
            upstreamResponse.Content.Headers.ContentType?.MediaType ?? "(none)");
        foreach (var h in upstreamResponse.Headers)
            _logger.LogInformation("<<   {Key}: {Value}", h.Key, string.Join(",", h.Value));

        // --- Translate non-2xx errors into Anthropic format so Claude Code shows the real message ---
        if (statusCode >= 400)
        {
            var errorBody = await TranslateErrorResponseAsync(upstreamResponse, statusCode);
            if (errorBody != null)
            {
                _logger.LogInformation("<< Translated error: {Error}", Encoding.UTF8.GetString(errorBody));
                context.Response.StatusCode = statusCode;
                context.Response.ContentType = "application/json";
                context.Response.ContentLength = errorBody.Length;
                await context.Response.Body.WriteAsync(errorBody);
                return;
            }
        }

        context.Response.StatusCode = statusCode;

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

    // --- Error translation ---

    /// Translates OpenRouter error responses into Anthropic API format
    /// so Claude Code can parse and display the actual error message.
    private static async Task<byte[]?> TranslateErrorResponseAsync(
        HttpResponseMessage response, int statusCode)
    {
        try
        {
            var bytes = await response.Content.ReadAsByteArrayAsync();
            var json = Encoding.UTF8.GetString(bytes);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            // Extract message from OpenRouter format: {"error":{"message":"...","code":N,"metadata":{...}}}
            string? message = null;
            if (root.TryGetProperty("error", out var errorObj) && errorObj.ValueKind == JsonValueKind.Object)
            {
                if (errorObj.TryGetProperty("message", out var msg))
                    message = msg.GetString();
                // Include metadata.raw if present (has the real upstream error)
                if (errorObj.TryGetProperty("metadata", out var meta) && meta.TryGetProperty("raw", out var raw))
                    message = raw.GetString() ?? message;
            }

            if (message == null) return null;

            // Map status code to Anthropic error type
            var errorType = statusCode switch
            {
                401 => "authentication_error",
                403 => "permission_error",
                404 => "not_found_error",
                429 => "rate_limit_error",
                >= 500 => "api_error",
                _ => "api_error"
            };

            // Return Anthropic-format error: {"type":"error","error":{"type":"...","message":"..."}}
            return JsonSerializer.SerializeToUtf8Bytes(new
            {
                type = "error",
                error = new { type = errorType, message }
            });
        }
        catch
        {
            return null; // If parsing fails, let the original response through
        }
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
        await using var writer = new StreamWriter(dest, new UTF8Encoding(false), 1024, leaveOpen: true);
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
                    await writer.WriteAsync("\n");
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
                        await writer.WriteAsync("\n");
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
                        await writer.WriteAsync("\n");
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
                await writer.WriteAsync(line + "\n");
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
                    // Emit non-data lines first (event: type, etc.), then data
                    foreach (var line in eventLines)
                    {
                        if (!line.StartsWith("data: "))
                            await writer.WriteAsync(line + "\n");
                    }
                    await writer.WriteAsync("data: " + modified + "\n");
                    return;
                }
                break;
            }
        }

        foreach (var line in eventLines)
            await writer.WriteAsync(line + "\n");
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
