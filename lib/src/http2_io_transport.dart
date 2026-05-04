/// HTTP/2 transport for `HttpIoAdapter`.
///
/// Wraps `package:http2`'s `ClientTransportConnection` to multiplex
/// many request/response streams over a single TCP/TLS connection —
/// the production-correct transport for high-RPS REST APIs that talk
/// to HTTP/2-capable backends (modern API gateways, gRPC-gateway,
/// industrial control plane services).
///
/// Two modes:
///
///   * [Http2IoTransport.tls] — TLS with ALPN-negotiated `h2`. The
///     production path. Falls back to `HttpException` if the peer
///     does not select `h2` during the TLS handshake.
///   * [Http2IoTransport.h2c] — cleartext HTTP/2 with prior knowledge.
///     Used in service-mesh deployments (sidecar terminates TLS) and
///     in-memory test fixtures. No upgrade dance — both peers start
///     speaking h2 framing from the connection preface.
///
/// Connection lifecycle: lazy on first [send], reused for every
/// subsequent [send] until [close] or peer-initiated GOAWAY. The
/// transport does not auto-reconnect — if the connection drops, the
/// caller's retry policy decides whether to re-send.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/http2.dart';

import 'http_io_transport.dart';

class Http2IoTransport implements HttpIoTransport {
  /// Origin that this transport is pinned to (scheme + host + port).
  /// Every [send] request must target the same origin.
  final Uri origin;

  /// `true` for TLS+ALPN; `false` for cleartext h2c.
  final bool useTls;

  /// Optional TLS context — only consulted in [useTls] mode.
  final SecurityContext? securityContext;

  /// Per-call deadline applied to the response stream completion.
  final Duration timeout;

  ClientTransportConnection? _conn;

  Http2IoTransport.tls({
    required this.origin,
    this.securityContext,
    this.timeout = const Duration(seconds: 30),
  }) : useTls = true {
    _validateOrigin();
  }

  Http2IoTransport.h2c({
    required this.origin,
    this.timeout = const Duration(seconds: 30),
  })  : useTls = false,
        securityContext = null {
    _validateOrigin();
  }

  void _validateOrigin() {
    if (origin.host.isEmpty) {
      throw ArgumentError.value(origin, 'origin', 'must have a host');
    }
  }

  Future<ClientTransportConnection> _ensureConnection() async {
    final existing = _conn;
    if (existing != null && existing.isOpen) return existing;

    final port =
        origin.hasPort ? origin.port : (useTls ? 443 : 80);
    final Socket socket;
    if (useTls) {
      final tls = await SecureSocket.connect(
        origin.host,
        port,
        supportedProtocols: const ['h2'],
        context: securityContext,
      );
      if (tls.selectedProtocol != 'h2') {
        tls.destroy();
        throw HttpException(
          'server did not negotiate h2 (selectedProtocol='
          '${tls.selectedProtocol})',
        );
      }
      socket = tls;
    } else {
      socket = await Socket.connect(origin.host, port);
    }

    final conn = ClientTransportConnection.viaSocket(socket);
    _conn = conn;
    return conn;
  }

  @override
  Future<HttpIoResponse> send(HttpIoRequest request) async {
    if (request.uri.host != origin.host ||
        request.uri.scheme != origin.scheme ||
        (request.uri.hasPort && request.uri.port != origin.port)) {
      throw ArgumentError(
          'request URI ${request.uri} does not match transport origin '
          '$origin — Http2IoTransport is per-origin');
    }

    final conn = await _ensureConnection();

    final pathAndQuery = request.uri.hasQuery
        ? '${request.uri.path}?${request.uri.query}'
        : request.uri.path.isEmpty
            ? '/'
            : request.uri.path;

    final headers = <Header>[
      Header.ascii(':method', request.method.toUpperCase()),
      Header.ascii(':path', pathAndQuery),
      Header.ascii(':scheme', origin.scheme),
      Header.ascii(':authority',
          origin.hasPort ? '${origin.host}:${origin.port}' : origin.host),
      for (final e in request.headers.entries)
        Header.ascii(e.key.toLowerCase(), e.value),
    ];

    final hasBody = request.body != null && request.body!.isNotEmpty;
    final stream = conn.makeRequest(headers, endStream: !hasBody);

    if (hasBody) {
      stream.outgoingMessages.add(
        DataStreamMessage(
          Uint8List.fromList(utf8.encode(request.body!)),
          endStream: true,
        ),
      );
    }
    await stream.outgoingMessages.close();

    int? status;
    final respHeaders = <String, String>{};
    final bodyBuf = BytesBuilder(copy: false);

    await for (final msg
        in stream.incomingMessages.timeout(timeout)) {
      if (msg is HeadersStreamMessage) {
        for (final h in msg.headers) {
          final name = utf8.decode(h.name);
          final value = utf8.decode(h.value);
          if (name == ':status') {
            status = int.parse(value);
          } else if (!name.startsWith(':')) {
            respHeaders[name] = value;
          }
        }
      } else if (msg is DataStreamMessage) {
        bodyBuf.add(msg.bytes);
      }
    }

    if (status == null) {
      throw HttpException('HTTP/2 response missing :status pseudo-header');
    }

    return HttpIoResponse(
      status: status,
      headers: respHeaders,
      body: utf8.decode(bodyBuf.toBytes(), allowMalformed: true),
    );
  }

  @override
  Future<void> close() async {
    final c = _conn;
    _conn = null;
    if (c != null) {
      await c.finish();
    }
  }
}
