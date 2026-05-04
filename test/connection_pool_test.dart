/// `HttpConnectionPool` + `DartHttpIoTransport` propagation tests.
///
/// Verifies each tunable forwards into the underlying `dart:io
/// HttpClient` instance (we read back the configured properties to
/// confirm the constructor wiring without needing a real server).
@TestOn('vm')
library;

import 'dart:io';

import 'package:mcp_io_http/mcp_io_http.dart';
import 'package:test/test.dart';

void main() {
  group('HttpConnectionPool defaults', () {
    test('TC-CP-001 default values match historic behaviour', () {
      const p = HttpConnectionPool();
      expect(p.connectionTimeout, const Duration(seconds: 5));
      expect(p.idleTimeout, isNull);
      expect(p.maxConnectionsPerHost, isNull);
      expect(p.autoUncompress, isTrue);
      expect(p.userAgent, isNull);
    });
  });

  group('DartHttpIoTransport — settings propagate to HttpClient', () {
    test('TC-CP-002 connectionTimeout forwards to HttpClient', () {
      final c = HttpClient();
      DartHttpIoTransport(
        client: c,
        pool: const HttpConnectionPool(
          connectionTimeout: Duration(seconds: 11),
        ),
      );
      expect(c.connectionTimeout, const Duration(seconds: 11));
      c.close(force: true);
    });

    test('TC-CP-003 idleTimeout forwards', () {
      final c = HttpClient();
      DartHttpIoTransport(
        client: c,
        pool: const HttpConnectionPool(
          idleTimeout: Duration(seconds: 30),
        ),
      );
      expect(c.idleTimeout, const Duration(seconds: 30));
      c.close(force: true);
    });

    test('TC-CP-004 maxConnectionsPerHost forwards', () {
      final c = HttpClient();
      DartHttpIoTransport(
        client: c,
        pool: const HttpConnectionPool(maxConnectionsPerHost: 6),
      );
      expect(c.maxConnectionsPerHost, 6);
      c.close(force: true);
    });

    test('TC-CP-005 autoUncompress forwards (and default is true)', () {
      final c1 = HttpClient();
      DartHttpIoTransport(client: c1);
      expect(c1.autoUncompress, isTrue);
      c1.close(force: true);

      final c2 = HttpClient();
      DartHttpIoTransport(
        client: c2,
        pool: const HttpConnectionPool(autoUncompress: false),
      );
      expect(c2.autoUncompress, isFalse);
      c2.close(force: true);
    });

    test('TC-CP-006 userAgent forwards', () {
      final c = HttpClient();
      DartHttpIoTransport(
        client: c,
        pool: const HttpConnectionPool(userAgent: 'mcp_io/1.0 (test)'),
      );
      expect(c.userAgent, 'mcp_io/1.0 (test)');
      c.close(force: true);
    });

    test('TC-CP-007 BC — single-arg construction still works (default pool)',
        () {
      final c = HttpClient();
      final t = DartHttpIoTransport(client: c);
      expect(t.timeout, const Duration(seconds: 5));
      expect(t.pool.autoUncompress, isTrue);
      c.close(force: true);
    });
  });

  group('Pool snapshot is immutable', () {
    test('TC-CP-008 transport.pool returns the configured snapshot', () {
      final t = DartHttpIoTransport(
        pool: const HttpConnectionPool(
          connectionTimeout: Duration(seconds: 7),
          maxConnectionsPerHost: 8,
          userAgent: 'X',
        ),
      );
      expect(t.pool.connectionTimeout, const Duration(seconds: 7));
      expect(t.pool.maxConnectionsPerHost, 8);
      expect(t.pool.userAgent, 'X');
      t.close();
    });
  });
}
