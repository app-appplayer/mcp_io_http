# mcp_io_http

HTTP / REST adapter for [`mcp_io`](https://pub.dev/packages/mcp_io) —
talk to REST APIs, webhook endpoints, and SSE streams through the
4-Primitive surface, with auth, cookies, multipart, retry, and
Server-Sent Events all wired in.

## Capability matrix

| Area | Support |
|---|---|
| Methods | GET / HEAD / OPTIONS / POST / PUT / PATCH / DELETE |
| Auth | None, Basic, Bearer, API Key (header / query), OAuth2 (token + refresh hook), mTLS, `AuthChain` (multiple in order) |
| Content | JSON, form-urlencoded, multipart/form-data (RFC 7578), arbitrary `Content-Type` |
| Compression | gzip + deflate (transparent via dart:io HttpClient) |
| Flow | Redirect cap, cookie jar (RFC 6265, injected clock support), custom headers, configurable connect / read timeouts |
| Subscribe | Polling (interval) + Server-Sent Events (`text/event-stream`, `Last-Event-ID` resume, RFC 8895 streaming) |
| Retry | 5xx + 429, idempotent methods only, `Retry-After` honor, exponential backoff |
| Error mapping | 4xx / 5xx → `IoError` codes (`auth.unauthorized`, `client.bad_request`, `gateway.timeout`, `server.unavailable`, ...) |
| Capabilities | `http.get` / `head` / `options` / `post` / `put` / `patch` / `delete` / `subscribe_sse` |

## Quick start

```dart
import 'package:mcp_io_http/mcp_io_http.dart';

final adapter = HttpIoAdapter(
  deviceId: 'api-1',
  baseUri: Uri.parse('https://api.example.com/v1'),
  auth: BearerAuth(token: 'abc...'),
  cookieJar: CookieJar(),
  retryPolicy: RetryPolicy(maxAttempts: 5),
);
await adapter.connect();

// One-shot read.
final r = await adapter.read(const ReadSpec(targets: ['/sensors/42']));

// SSE stream.
final stream = adapter.subscribe(const TopicSpec(
  uri: '/events',
  options: TopicOptions.fromMap({'mode': 'sse'}),
));
stream.listen((env) => print(env.payload.value));
```

## Auth chain

Compose multiple auth providers (header API key + Bearer in
`Authorization`, for example):

```dart
final auth = AuthChain([
  ApiKeyAuth(name: 'X-API-Key', value: 'k...', placement: ApiKeyPlacement.header),
  BearerAuth(token: 'jwt...'),
]);
```

OAuth2 with refresh-on-401:

```dart
final auth = OAuth2Auth(
  initialAccessToken: 't0',
  refresh: () async => fetchNewToken(),
);
// HttpIoAdapter automatically retries the original request once
// after a 401 response, replaying through the refreshed token.
```

## License

MIT — see [LICENSE](LICENSE).
