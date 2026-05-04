import 'dart:convert';

import 'package:mcp_io_http/mcp_io_http.dart';
import 'package:test/test.dart';

void main() {
  group('Auth - Basic', () {
    test('TC-AUTH-001 base64 of user:pass', () async {
      final auth = const BasicAuth(username: 'u', password: 'p');
      final builder = HttpRequestBuilder();
      await auth.apply(builder);
      final expected = base64Encode(utf8.encode('u:p'));
      expect(builder.headers['Authorization'], 'Basic $expected');
    });
  });

  group('Auth - Bearer', () {
    test('TC-AUTH-010 static token', () async {
      final auth = BearerAuth(token: 'abc.def.ghi');
      final b = HttpRequestBuilder();
      await auth.apply(b);
      expect(b.headers['Authorization'], 'Bearer abc.def.ghi');
    });

    test('TC-AUTH-011 dynamic token via provider', () async {
      var counter = 0;
      final auth = BearerAuth(tokenProvider: () async {
        counter++;
        return 'token-$counter';
      });
      final b1 = HttpRequestBuilder();
      await auth.apply(b1);
      expect(b1.headers['Authorization'], 'Bearer token-1');
      final b2 = HttpRequestBuilder();
      await auth.apply(b2);
      expect(b2.headers['Authorization'], 'Bearer token-2');
    });
  });

  group('Auth - ApiKey', () {
    test('TC-AUTH-020 header location', () async {
      final auth =
          const ApiKeyAuth(key: 'secret', parameterName: 'X-Custom-Key');
      final b = HttpRequestBuilder();
      await auth.apply(b);
      expect(b.headers['X-Custom-Key'], 'secret');
    });

    test('TC-AUTH-021 query location', () async {
      final auth = const ApiKeyAuth(
        key: 'k',
        location: ApiKeyLocation.query,
        parameterName: 'api_key',
      );
      final b = HttpRequestBuilder();
      await auth.apply(b);
      expect(b.queryParameters['api_key'], 'k');
    });
  });

  group('Auth - OAuth2', () {
    test('TC-AUTH-030 client_credentials caches token', () async {
      var calls = 0;
      final auth = OAuth2Auth(
        tokenClient: _StubTokenClient((_) async {
          calls++;
          return const OAuth2TokenResponse(
            accessToken: 'tok',
            expiresIn: 3600,
          );
        }),
        tokenEndpoint: Uri.parse('https://example.com/token'),
        clientId: 'id',
        clientSecret: 'secret',
      );
      final b1 = HttpRequestBuilder();
      await auth.apply(b1);
      final b2 = HttpRequestBuilder();
      await auth.apply(b2);
      expect(b1.headers['Authorization'], 'Bearer tok');
      expect(b2.headers['Authorization'], 'Bearer tok');
      expect(calls, 1);
    });

    test('TC-AUTH-031 tryRefresh forces a new fetch', () async {
      var calls = 0;
      final auth = OAuth2Auth(
        tokenClient: _StubTokenClient((_) async {
          calls++;
          return OAuth2TokenResponse(accessToken: 'tok-$calls', expiresIn: 3600);
        }),
        tokenEndpoint: Uri.parse('https://example.com/token'),
        clientId: 'id',
        clientSecret: 'secret',
      );
      final b1 = HttpRequestBuilder();
      await auth.apply(b1);
      final ok = await auth.tryRefresh();
      expect(ok, isTrue);
      final b2 = HttpRequestBuilder();
      await auth.apply(b2);
      expect(b1.headers['Authorization'], 'Bearer tok-1');
      expect(b2.headers['Authorization'], 'Bearer tok-2');
    });
  });

  group('Auth - Chain', () {
    test('TC-AUTH-040 mTLS + Bearer combine', () async {
      final chain = AuthChain([
        const MutualTlsAuth(clientCertBytes: [], clientKeyBytes: []),
        BearerAuth(token: 't'),
      ]);
      final b = HttpRequestBuilder();
      await chain.apply(b);
      expect(b.headers['Authorization'], 'Bearer t');
    });
  });

  group('CookieJar', () {
    test('TC-COOK-001 store + buildCookieHeader', () {
      final jar = CookieJar();
      jar.store(Uri.parse('https://example.com/'), [
        'sid=abc123; Path=/; Secure',
      ]);
      final header = jar.buildCookieHeader(Uri.parse('https://example.com/api'));
      expect(header, 'sid=abc123');
    });

    test('TC-COOK-002 secure flag blocks http', () {
      final jar = CookieJar();
      jar.store(Uri.parse('https://example.com/'), [
        'sid=x; Path=/; Secure',
      ]);
      expect(jar.buildCookieHeader(Uri.parse('http://example.com/')), isNull);
    });

    test('TC-COOK-003 path matching', () {
      final jar = CookieJar();
      jar.store(Uri.parse('https://example.com/api/'), [
        'token=t; Path=/api',
      ]);
      expect(
          jar.buildCookieHeader(Uri.parse('https://example.com/api/v1')),
          'token=t');
      expect(
          jar.buildCookieHeader(Uri.parse('https://example.com/other')),
          isNull);
    });

    test('TC-COOK-004 expired cookie removed', () {
      var now = DateTime(2026, 1, 1);
      final jar = CookieJar(clock: () => now);
      jar.store(Uri.parse('https://example.com/'), [
        'tmp=v; Max-Age=10',
      ]);
      now = now.add(const Duration(seconds: 30));
      expect(
          jar.buildCookieHeader(Uri.parse('https://example.com/')), isNull);
    });

    test('TC-COOK-005 domain match (parent host)', () {
      final jar = CookieJar();
      jar.store(Uri.parse('https://api.example.com/'), [
        'k=v; Domain=example.com; Path=/',
      ]);
      expect(
          jar.buildCookieHeader(Uri.parse('https://www.example.com/')),
          'k=v');
    });
  });

  group('MultipartBody', () {
    test('TC-MP-001 single text part', () {
      final body = MultipartBody(
        parts: [MultipartPart(name: 'field', text: 'value')],
        boundary: 'BND',
      );
      final encoded = utf8.decode(body.encode());
      expect(encoded, contains('--BND\r\n'));
      expect(encoded, contains(
          'Content-Disposition: form-data; name="field"\r\n'));
      expect(encoded, contains('value\r\n'));
      expect(encoded.endsWith('--BND--\r\n'), isTrue);
    });

    test('TC-MP-002 file part with filename + content type', () {
      final body = MultipartBody(
        parts: [
          MultipartPart(
            name: 'upload',
            filename: 'test.png',
            contentType: 'image/png',
            bytes: [0x89, 0x50, 0x4E, 0x47],
          )
        ],
        boundary: 'BND',
      );
      final encoded = utf8.decode(body.encode(), allowMalformed: true);
      expect(encoded, contains('filename="test.png"'));
      expect(encoded, contains('Content-Type: image/png'));
    });

    test('TC-MP-003 contentTypeHeader', () {
      final body = MultipartBody(parts: [
        MultipartPart(name: 'a', text: 'b'),
      ], boundary: 'XYZ');
      expect(body.contentTypeHeader, 'multipart/form-data; boundary=XYZ');
    });
  });

  group('HttpRetryPolicy', () {
    test('TC-RETRY-001 retry 503 GET', () {
      const p = HttpRetryPolicy();
      expect(
          p.shouldRetry(attempt: 1, statusCode: 503, method: 'GET'),
          isTrue);
    });

    test('TC-RETRY-002 no retry POST without idempotency key', () {
      const p = HttpRetryPolicy();
      expect(
          p.shouldRetry(attempt: 1, statusCode: 503, method: 'POST'),
          isFalse);
    });

    test('TC-RETRY-003 idempotency key allows POST retry', () {
      const p = HttpRetryPolicy();
      expect(
          p.shouldRetry(
              attempt: 1,
              statusCode: 503,
              method: 'POST',
              hasIdempotencyKey: true),
          isTrue);
    });

    test('TC-RETRY-004 stop after maxAttempts', () {
      const p = HttpRetryPolicy(maxAttempts: 3);
      expect(p.shouldRetry(attempt: 3, statusCode: 503, method: 'GET'),
          isFalse);
    });

    test('TC-RETRY-005 backoff scales geometrically', () {
      const p = HttpRetryPolicy();
      final d1 = p.nextBackoff(attempt: 1).inMilliseconds;
      final d2 = p.nextBackoff(attempt: 2).inMilliseconds;
      final d3 = p.nextBackoff(attempt: 3).inMilliseconds;
      expect(d2, d1 * 2);
      expect(d3, d1 * 4);
    });

    test('TC-RETRY-006 Retry-After honored', () {
      const p = HttpRetryPolicy();
      final d = p.nextBackoff(attempt: 1, retryAfterHeader: '10');
      expect(d.inSeconds, 10);
    });

    test('TC-RETRY-007 parseRetryAfter int + date', () {
      expect(HttpRetryPolicy.parseRetryAfter('30'), const Duration(seconds: 30));
      // Far past date should clamp to zero (negative delta).
      final past = HttpRetryPolicy.parseRetryAfter('2020-01-01T00:00:00Z');
      expect(past, Duration.zero);
    });

    test('TC-RETRY-008 retry status set', () {
      const p = HttpRetryPolicy();
      expect(p.shouldRetry(attempt: 1, statusCode: 200, method: 'GET'),
          isFalse);
      expect(p.shouldRetry(attempt: 1, statusCode: 404, method: 'GET'),
          isFalse);
      expect(p.shouldRetry(attempt: 1, statusCode: 429, method: 'GET'),
          isTrue);
    });
  });

  group('HttpStatusToIoError', () {
    test('TC-STAT-001 success returns null', () {
      expect(HttpStatusToIoError.fromStatus(200), isNull);
      expect(HttpStatusToIoError.fromStatus(301), isNull);
    });

    test('TC-STAT-002 4xx mapping', () {
      expect(HttpStatusToIoError.fromStatus(401)!.code,
          'auth.unauthorized');
      expect(HttpStatusToIoError.fromStatus(403)!.code, 'auth.forbidden');
      expect(HttpStatusToIoError.fromStatus(404)!.code,
          'resource.not_found');
      expect(HttpStatusToIoError.fromStatus(429)!.code, 'quota.rate_limit');
    });

    test('TC-STAT-003 5xx mapping', () {
      expect(HttpStatusToIoError.fromStatus(500)!.code, 'server.internal');
      expect(HttpStatusToIoError.fromStatus(503)!.code,
          'server.unavailable');
      expect(HttpStatusToIoError.fromStatus(599)!.code, 'server.error');
    });
  });

  group('SseParser', () {
    test('TC-SSE-001 single event', () async {
      final input = Stream.value('event: msg\ndata: hello\n\n');
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events, hasLength(1));
      expect(events.first.event, 'msg');
      expect(events.first.data, 'hello');
    });

    test('TC-SSE-002 multi-line data joined with \\n', () async {
      final input = Stream.value('data: line1\ndata: line2\n\n');
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events.first.data, 'line1\nline2');
    });

    test('TC-SSE-003 id persists across events', () async {
      final input = Stream.value(
          'id: 1\ndata: a\n\ndata: b\n\nid: 2\ndata: c\n\n');
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events.map((e) => e.id).toList(), ['1', '1', '2']);
    });

    test('TC-SSE-004 retry parsed', () async {
      final input = Stream.value('retry: 5000\ndata: x\n\n');
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events.first.retry, 5000);
    });

    test('TC-SSE-005 comment lines skipped', () async {
      final input = Stream.value(': heartbeat\ndata: x\n\n');
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events, hasLength(1));
      expect(events.first.data, 'x');
    });

    test('TC-SSE-006 chunked input across boundaries', () async {
      final input = Stream<String>.fromIterable([
        'data: he',
        'llo\n\n',
      ]);
      final events = await input
          .transform(const SseParser().transformer)
          .toList();
      expect(events.first.data, 'hello');
    });
  });
}

class _StubTokenClient implements OAuth2TokenClient {
  _StubTokenClient(this._handler);
  final Future<OAuth2TokenResponse> Function(OAuth2GrantType grant) _handler;

  @override
  Future<OAuth2TokenResponse> requestToken({
    required Uri tokenEndpoint,
    required String clientId,
    String? clientSecret,
    required OAuth2GrantType grant,
    String? refreshToken,
    String? scope,
  }) =>
      _handler(grant);
}
