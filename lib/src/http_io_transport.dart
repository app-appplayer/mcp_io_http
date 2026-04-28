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

/// Production transport using `dart:io` `HttpClient`.
class DartHttpIoTransport implements HttpIoTransport {
  final HttpClient _client;
  final Duration timeout;

  DartHttpIoTransport({HttpClient? client, this.timeout = const Duration(seconds: 5)})
      : _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
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
