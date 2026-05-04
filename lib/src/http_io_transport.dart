/// HTTP transport abstraction used by `HttpIoAdapter`.
///
/// Implementations perform a single request/response round-trip. Tests use
/// [InMemoryHttpIoTransport]; production uses [DartHttpIoTransport] backed
/// by `dart:io`'s `HttpClient`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A normalized HTTP response surfaced to the adapter. The [body] is decoded
/// as UTF-8 text; JSON parsing is performed one layer up in the adapter.
class HttpIoResponse {
  final int status;
  final Map<String, String> headers;
  final String body;

  const HttpIoResponse({
    required this.status,
    this.headers = const {},
    this.body = '',
  });

  bool get isSuccess => status >= 200 && status < 300;
}

/// Single round-trip HTTP request.
class HttpIoRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  const HttpIoRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
  });
}

abstract class HttpIoTransport {
  Future<HttpIoResponse> send(HttpIoRequest request);
  Future<void> close();
}

/// Connection-pool / timeout / compression knobs for the
/// `dart:io HttpClient`. Each field has a sensible default so the
/// existing 1-arg [DartHttpIoTransport] constructor stays BC.
class HttpConnectionPool {
  /// Initial dial timeout — surfaced as `HttpClient.connectionTimeout`.
  final Duration connectionTimeout;

  /// Max idle time for a kept-alive connection in the pool. `null`
  /// keeps the dart:io default (15 seconds).
  final Duration? idleTimeout;

  /// Cap on simultaneous TCP connections to the same host. `null`
  /// keeps the dart:io default (-1 == unlimited).
  final int? maxConnectionsPerHost;

  /// Whether to transparently un-gzip response bodies — surfaced as
  /// `HttpClient.autoUncompress`. Defaults to `true` (matches
  /// dart:io default and what a typical REST client expects).
  final bool autoUncompress;

  /// User-Agent override. `null` keeps the dart:io default
  /// (`Dart/<version> (dart:io)`).
  final String? userAgent;

  const HttpConnectionPool({
    this.connectionTimeout = const Duration(seconds: 5),
    this.idleTimeout,
    this.maxConnectionsPerHost,
    this.autoUncompress = true,
    this.userAgent,
  });
}

/// Production transport using `dart:io` `HttpClient`. Pool / timeout
/// tuning is supplied via [HttpConnectionPool] (default values match
/// the historic transport behaviour).
class DartHttpIoTransport implements HttpIoTransport {
  final HttpClient _client;

  /// Per-call timeout (`openUrl` + `close` + body drain). Separate
  /// from [HttpConnectionPool.connectionTimeout] which only covers
  /// the initial dial.
  final Duration timeout;

  /// Snapshot of the pool config at construction time.
  final HttpConnectionPool pool;

  DartHttpIoTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 5),
    this.pool = const HttpConnectionPool(),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = pool.connectionTimeout;
    if (pool.idleTimeout != null) {
      _client.idleTimeout = pool.idleTimeout!;
    }
    if (pool.maxConnectionsPerHost != null) {
      _client.maxConnectionsPerHost = pool.maxConnectionsPerHost!;
    }
    _client.autoUncompress = pool.autoUncompress;
    if (pool.userAgent != null) {
      _client.userAgent = pool.userAgent;
    }
  }

  @override
  Future<HttpIoResponse> send(HttpIoRequest request) async {
    final r = await _client
        .openUrl(request.method, request.uri)
        .timeout(timeout);
    request.headers.forEach(r.headers.add);
    if (request.body != null) {
      r.write(request.body);
    }
    final response = await r.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) headers[name] = values.first;
    });
    return HttpIoResponse(
      status: response.statusCode,
      headers: headers,
      body: body,
    );
  }

  @override
  Future<void> close() async {
    _client.close(force: true);
  }
}

/// In-memory transport for tests. The caller registers a handler that maps
/// each request to a canned response. [requests] records all calls for
/// assertion.
class InMemoryHttpIoTransport implements HttpIoTransport {
  Future<HttpIoResponse> Function(HttpIoRequest request) handler;
  final List<HttpIoRequest> requests = [];
  bool isClosed = false;

  InMemoryHttpIoTransport(this.handler);

  @override
  Future<HttpIoResponse> send(HttpIoRequest request) async {
    if (isClosed) {
      throw StateError('transport closed');
    }
    requests.add(request);
    return handler(request);
  }

  @override
  Future<void> close() async {
    isClosed = true;
  }
}
