/// HTTP/2 transport tests using h2c (cleartext HTTP/2 with prior
/// knowledge) over a loopback `ServerSocket`. Production TLS+ALPN
/// path is not exercised here because spinning up a self-signed
/// SecureSocket pair adds noise — the TLS branch is mechanical
/// (`SecureSocket.connect(supportedProtocols: ['h2'])`), the rest of
/// the protocol logic is identical and verified here.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';
import 'package:mcp_io_http/mcp_io_http.dart';
import 'package:test/test.dart';

/// Simple h2c server: spins up a `ServerSocket`, wraps each accepted
/// socket in `ServerTransportConnection.viaSocket`, lets the caller
/// register a per-stream handler that produces canned responses.
class _H2cServer {
  ServerSocket? _server;
  final void Function(_H2Request request)? _handler;

  _H2cServer(this._handler);

  Future<int> start() async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    _server = server;
    server.listen((socket) {
      final conn = ServerTransportConnection.viaSocket(socket);
      conn.incomingStreams.listen((stream) async {
        final request = _H2Request(stream);
        await request._collect();
        if (_handler != null) _handler(request);
      });
    });
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close();
  }
}

class _H2Request {
  _H2Request(this.stream);
  final ServerTransportStream stream;
  String method = '';
  String path = '';
  final Map<String, String> headers = {};
  final BytesBuilder _body = BytesBuilder(copy: false);

  Uint8List get body => _body.toBytes();

  Future<void> _collect() async {
    await for (final msg in stream.incomingMessages) {
      if (msg is HeadersStreamMessage) {
        for (final h in msg.headers) {
          final n = utf8.decode(h.name);
          final v = utf8.decode(h.value);
          if (n == ':method') {
            method = v;
          } else if (n == ':path') {
            path = v;
          } else if (!n.startsWith(':')) {
            headers[n] = v;
          }
        }
      } else if (msg is DataStreamMessage) {
        _body.add(msg.bytes);
      }
    }
  }

  Future<void> respond({
    required int status,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final hasBody = body != null && body.isNotEmpty;
    stream.outgoingMessages.add(HeadersStreamMessage([
      Header.ascii(':status', '$status'),
      for (final e in headers.entries)
        Header.ascii(e.key.toLowerCase(), e.value),
    ], endStream: !hasBody));
    if (hasBody) {
      stream.outgoingMessages.add(DataStreamMessage(
        Uint8List.fromList(utf8.encode(body)),
        endStream: true,
      ));
    }
    await stream.outgoingMessages.close();
  }
}

void main() {
  group('Http2IoTransport h2c roundtrip', () {
    late _H2cServer server;
    late int port;

    Future<void> startServer(void Function(_H2Request) handler) async {
      server = _H2cServer(handler);
      port = await server.start();
    }

    tearDown(() async {
      await server.stop();
    });

    test('TC-H2-001 GET roundtrip recovers status + headers + body',
        () async {
      await startServer((req) async {
        await req.respond(
          status: 200,
          headers: {'content-type': 'application/json'},
          body: '{"ok":true}',
        );
      });

      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:$port'),
      );

      final response = await transport.send(HttpIoRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/api/health'),
      ));

      expect(response.status, 200);
      expect(response.body, '{"ok":true}');
      expect(response.headers['content-type'], 'application/json');

      await transport.close();
    });

    test('TC-H2-002 POST with body — server sees method + body', () async {
      _H2Request? captured;
      await startServer((req) async {
        captured = req;
        await req.respond(status: 201, body: '{"created":true}');
      });

      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:$port'),
      );

      final response = await transport.send(HttpIoRequest(
        method: 'POST',
        uri: Uri.parse('http://127.0.0.1:$port/api/items'),
        headers: const {'content-type': 'application/json'},
        body: '{"name":"sensor-1"}',
      ));

      expect(response.status, 201);
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.path, '/api/items');
      expect(utf8.decode(captured!.body), '{"name":"sensor-1"}');
      expect(captured!.headers['content-type'], 'application/json');

      await transport.close();
    });

    test('TC-H2-003 multiple sequential requests reuse the connection',
        () async {
      var counter = 0;
      await startServer((req) async {
        counter++;
        await req.respond(status: 200, body: 'count=$counter');
      });

      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:$port'),
      );

      for (var i = 1; i <= 3; i++) {
        final r = await transport.send(HttpIoRequest(
          method: 'GET',
          uri: Uri.parse('http://127.0.0.1:$port/n'),
        ));
        expect(r.body, 'count=$i');
      }
      expect(counter, 3);

      await transport.close();
    });

    test('TC-H2-004 query string forwarded to :path', () async {
      _H2Request? captured;
      await startServer((req) async {
        captured = req;
        await req.respond(status: 200, body: 'ok');
      });

      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:$port'),
      );

      await transport.send(HttpIoRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/search?q=temp&limit=5'),
      ));

      expect(captured!.path, '/search?q=temp&limit=5');
      await transport.close();
    });

    test('TC-H2-005 5xx response surfaces as HttpIoResponse (no throw)',
        () async {
      await startServer((req) async {
        await req.respond(status: 503, body: 'unavailable');
      });

      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:$port'),
      );

      final response = await transport.send(HttpIoRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:$port/'),
      ));

      expect(response.status, 503);
      expect(response.isSuccess, isFalse);
      expect(response.body, 'unavailable');

      await transport.close();
    });
  });

  group('Http2IoTransport origin pinning', () {
    test('TC-H2-006 cross-origin request rejected', () async {
      final transport = Http2IoTransport.h2c(
        origin: Uri.parse('http://127.0.0.1:8080'),
      );

      expect(
        () => transport.send(HttpIoRequest(
          method: 'GET',
          uri: Uri.parse('http://other-host:8080/'),
        )),
        throwsArgumentError,
      );
    });

    test('TC-H2-007 empty-host origin rejected at construction', () {
      expect(
        () => Http2IoTransport.h2c(origin: Uri.parse('http:///')),
        throwsArgumentError,
      );
    });
  });
}
