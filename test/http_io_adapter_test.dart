import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';
import 'package:mcp_io_http/mcp_io_http.dart';
import 'package:test/test.dart';

InMemoryHttpIoTransport _fake(
  Future<HttpIoResponse> Function(HttpIoRequest req) handler,
) =>
    InMemoryHttpIoTransport(handler);

HttpIoResponse _ok(String body, {Map<String, String>? headers}) =>
    HttpIoResponse(
      status: 200,
      headers: headers ?? const {'content-type': 'application/json'},
      body: body,
    );

void main() {
  group('HttpIoAdapter — read', () {
    test('GET returns scalar JSON number as scalar payload', () async {
      final transport = _fake((req) async {
        expect(req.method, 'GET');
        expect(req.uri.path, '/api/temp/living');
        return _ok('21.3');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
        uriMapper: UriMapper([
          const ResourceMapping(
            uriTemplate: 'temp/{zone}',
            addressTemplate: '/api/temp/{zone}',
          ),
        ]),
      );
      final res = await adapter.read(const ReadSpec(targets: ['temp/living']));
      final item = res.items.single;
      expect(item.error, isNull);
      expect(item.envelope?.payload.type, PayloadType.scalar);
      expect(item.envelope?.payload.value, 21.3);
    });

    test('GET returns JSON object as struct_ payload', () async {
      final transport = _fake((req) async =>
        _ok('{"value":22.5,"unit":"C"}'));
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.read(const ReadSpec(targets: ['/sensor/1']));
      final item = res.items.single;
      expect(item.envelope?.payload.type, PayloadType.struct_);
      final value = item.envelope?.payload.value as Map;
      expect(value['value'], 22.5);
      expect(value['unit'], 'C');
    });

    test('non-2xx response → per-target IoError', () async {
      final transport = _fake((req) async =>
        const HttpIoResponse(status: 503, body: 'service down'));
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.read(const ReadSpec(targets: ['/x']));
      expect(res.items.single.envelope, isNull);
      expect(res.items.single.error?.code, 'exec.failed');
      expect(res.items.single.error?.message, contains('503'));
    });

    test('mixed targets — error isolation across items', () async {
      final transport = _fake((req) async {
        if (req.uri.path == '/ok') return _ok('"hello"');
        return const HttpIoResponse(status: 404);
      });
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.read(
        const ReadSpec(targets: ['/ok', '/missing']),
      );
      expect(res.items[0].envelope?.payload.value, 'hello');
      expect(res.items[1].error, isNotNull);
    });

    test('plain-text fallback when body is not JSON', () async {
      final transport = _fake((req) async =>
        const HttpIoResponse(
          status: 200, body: 'BAY1-OK',
          headers: {'content-type': 'text/plain'},
        ));
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.read(const ReadSpec(targets: ['/status']));
      expect(res.items.single.envelope?.payload.value, 'BAY1-OK');
    });
  });

  group('HttpIoAdapter — execute', () {
    test('put with structured body → JSON-encoded and content-type set', () async {
      final transport = _fake((req) async {
        expect(req.method, 'PUT');
        expect(req.headers['content-type'], 'application/json');
        expect(req.body, jsonEncode({'value': 23}));
        return _ok('{"ok":true}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'thermo',
        baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.execute(const Command(
        action: 'put', target: '/api/setpoint',
        args: {'body': {'value': 23}},
      ));
      expect(res.status, CommandStatus.completed);
      expect((res.result as Map)['status'], 200);
    });

    test('post with string body — no content-type override', () async {
      final transport = _fake((req) async {
        expect(req.method, 'POST');
        expect(req.headers['content-type'], isNull);
        expect(req.body, 'raw-text');
        return _ok('');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.execute(const Command(
        action: 'post', target: '/log',
        args: {'body': 'raw-text'},
      ));
      expect(res.status, CommandStatus.completed);
    });

    test('custom headers from args are forwarded', () async {
      String? trace;
      final transport = _fake((req) async {
        trace = req.headers['X-Trace'];
        return _ok('{}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      await adapter.execute(const Command(
        action: 'get', target: '/info',
        args: {'headers': {'X-Trace': 'abc'}},
      ));
      expect(trace, 'abc');
    });

    test('defaultHeaders from constructor are applied', () async {
      String? auth;
      final transport = _fake((req) async {
        auth = req.headers['Authorization'];
        return _ok('{}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
        defaultHeaders: const {'Authorization': 'Bearer T'},
      );
      await adapter.execute(const Command(action: 'get', target: '/a'));
      expect(auth, 'Bearer T');
    });

    test('non-2xx → failed with IoError', () async {
      final transport = _fake((req) async =>
        const HttpIoResponse(status: 422, body: 'invalid'));
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.execute(const Command(
        action: 'post', target: '/x', args: {'body': {}},
      ));
      expect(res.status, CommandStatus.failed);
      expect(res.error?.message, contains('422'));
    });

    test('unknown action → rejected', () async {
      final transport = _fake((_) async => _ok('{}'));
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final res = await adapter.execute(const Command(
        action: 'blast', target: '/x',
      ));
      expect(res.status, CommandStatus.rejected);
      expect(res.error?.code, 'exec.unknown_action');
    });

    test('absolute URI in target bypasses baseUri', () async {
      Uri? called;
      final transport = _fake((req) async {
        called = req.uri;
        return _ok('{}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://host-a.example'),
        transport: transport,
      );
      await adapter.execute(const Command(
        action: 'get', target: 'https://other.example/v1/x',
      ));
      expect(called.toString(), 'https://other.example/v1/x');
    });

    test('baseUri with path prefix composes correctly', () async {
      Uri? called;
      final transport = _fake((req) async {
        called = req.uri;
        return _ok('{}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com/v1'),
        transport: transport,
      );
      await adapter.execute(const Command(action: 'get', target: 'temp'));
      expect(called?.path, '/v1/temp');
    });
  });

  group('HttpIoAdapter — subscribe (polling)', () {
    test('emits responses at the requested interval', () async {
      var count = 0;
      final transport = _fake((_) async {
        count++;
        return _ok('${count * 10}');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final received = <int>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: '/t', mode: TopicMode.poll,
        options: TopicOptions(intervalMs: 40),
      )).listen((e) => received.add(e.payload.value as int));
      await Future<void>.delayed(const Duration(milliseconds: 130));
      await sub.cancel();
      // Initial + a few ticks — assert at least 2 samples arrived.
      expect(received.length, greaterThanOrEqualTo(2));
      expect(received.first, 10);
    });

    test('non-2xx response emits error on stream', () async {
      final transport = _fake((_) async =>
        const HttpIoResponse(status: 500, body: 'boom'));
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final errors = <Object>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: '/t', mode: TopicMode.poll,
        options: TopicOptions(intervalMs: 50),
      )).listen((_) {}, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(errors, isNotEmpty);
      expect((errors.first as IoError).code, 'exec.failed');
    });

    test('cancel stops the polling timer', () async {
      var count = 0;
      final transport = _fake((_) async {
        count++;
        return _ok('1');
      });
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      final sub = adapter.subscribe(const TopicSpec(
        uri: '/t', mode: TopicMode.poll,
        options: TopicOptions(intervalMs: 20),
      )).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final snapshot = count;
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(count, snapshot,
        reason: 'count should freeze after cancel');
    });
  });

  group('HttpIoAdapter — lifecycle + emergency', () {
    test('connect / disconnect toggles state; disconnect closes transport', () async {
      final transport = _fake((_) async => _ok('{}'));
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: transport,
      );
      await adapter.connect();
      final d1 = await adapter.describe();
      expect(d1.connectionState, IoConnectionState.connected);
      await adapter.disconnect();
      expect(transport.isClosed, isTrue);
      final d2 = await adapter.describe();
      expect(d2.connectionState, IoConnectionState.disconnected);
    });

    test('emergencyStop returns unsupported', () async {
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: _fake((_) async => _ok('{}')),
      );
      final r = await adapter.emergencyStop(const EmergencyStopRequest(
        reason: 't', actorId: 'u',
      ));
      expect(r.success, isFalse);
      expect(r.error?.code, 'device.unsupported');
    });

    test('probe returns empty list', () async {
      final adapter = HttpIoAdapter(
        deviceId: 'a', baseUri: Uri.parse('http://example.com'),
        transport: _fake((_) async => _ok('{}')),
      );
      expect(await adapter.probe(null), isEmpty);
    });
  });
}
