/// HttpIoAdapter — REST-over-HTTP adapter implementing `AdapterBase`.
///
/// - `read` issues an HTTP GET and parses the response body (JSON first,
///   text fallback). One request per target; per-target errors are isolated.
/// - `execute` supports these actions:
///     * `get`    — target becomes the URI, returns the response in result.
///     * `post`   — body in `args['body']`.
///     * `put`    — body in `args['body']`.
///     * `patch`  — body in `args['body']`.
///     * `delete` — body optional.
///   Extra headers may be provided via `args['headers']` as a
///   `Map<String, String>`.
/// - `subscribe` polls the target URI at the interval given by
///   `TopicSpec.options.intervalMs` (default 5s). Each response is emitted
///   as a `PayloadEnvelope`; 4xx/5xx ticks emit an error into the stream.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';

import 'http_io_transport.dart';

class HttpIoAdapter extends AdapterBase {
  final String deviceId;
  final Uri baseUri;
  final HttpIoTransport _transport;
  final UriMapper? _uriMapper;
  final Map<String, String> defaultHeaders;

  IoConnectionState _state = IoConnectionState.disconnected;

  HttpIoAdapter({
    required this.deviceId,
    required this.baseUri,
    required HttpIoTransport transport,
    UriMapper? uriMapper,
    this.defaultHeaders = const {},
    AdapterManifest? manifest,
  })  : _transport = transport,
        _uriMapper = uriMapper,
        super(manifest: manifest ?? _defaultManifest);

  static final AdapterManifest _defaultManifest = AdapterManifest(
    adapterId: 'mcp_io_http',
    adapterVersion: '0.1.0',
    contractVersionRange: '>=0.1.0 <1.0.0',
    displayName: 'HTTP REST Adapter',
    description: 'Generic HTTP REST adapter. GET for read; POST/PUT/PATCH/DELETE for execute; polling subscribe.',
  );

  // === Lifecycle ===

  @override
  Future<void> connect() async {
    _state = IoConnectionState.connected;
  }

  @override
  Future<void> disconnect() async {
    await _transport.close();
    _state = IoConnectionState.disconnected;
  }

  @override
  Future<List<DeviceDescriptor>> probe(dynamic transport) async => const [];

  // === 4-Primitive Contract ===

  @override
  Future<DeviceDescriptor> describe() async {
    return DeviceDescriptor(
      deviceId: deviceId,
      manufacturer: 'HTTP',
      model: baseUri.host,
      transport: 'http',
      connectionState: _state,
    );
  }

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    final items = <ReadResultItem>[];
    for (final target in spec.targets) {
      try {
        final uri = _resolveUri(target);
        final response = await _transport.send(HttpIoRequest(
          method: 'GET', uri: uri, headers: defaultHeaders,
        ));
        if (!response.isSuccess) {
          items.add(ReadResultItem(
            uri: target,
            error: IoError(
              code: 'exec.failed',
              message: 'HTTP ${response.status}: ${response.body}',
              timestamp: DateTime.now(),
            ),
          ));
          continue;
        }
        items.add(ReadResultItem(
          uri: target,
          envelope: _envelope(target, response),
        ));
      } catch (e) {
        items.add(ReadResultItem(
          uri: target, error: AdapterBase.mapException(e),
        ));
      }
    }
    return ReadResult(items: items);
  }

  @override
  Future<CommandResult> execute(Command command) async {
    try {
      final method = _methodForAction(command.action);
      if (method == null) {
        return CommandResult(
          status: CommandStatus.rejected,
          error: IoError(
            code: 'exec.unknown_action',
            message: 'Unknown action: ${command.action}',
            timestamp: DateTime.now(),
          ),
        );
      }
      final uri = _resolveUri(command.target);
      final headers = <String, String>{
        ...defaultHeaders,
        ...((command.args['headers'] as Map?)?.cast<String, String>() ?? const {}),
      };
      String? body;
      final rawBody = command.args['body'];
      if (rawBody != null) {
        if (rawBody is String) {
          body = rawBody;
        } else {
          body = jsonEncode(rawBody);
          headers.putIfAbsent('content-type', () => 'application/json');
        }
      }
      final response = await _transport.send(HttpIoRequest(
        method: method, uri: uri, headers: headers, body: body,
      ));
      if (!response.isSuccess) {
        return CommandResult(
          status: CommandStatus.failed,
          error: IoError(
            code: 'exec.failed',
            message: 'HTTP ${response.status}: ${response.body}',
            timestamp: DateTime.now(),
          ),
        );
      }
      return CommandResult(
        status: CommandStatus.completed,
        result: {
          'status': response.status,
          'body': _parseBody(response.body),
        },
      );
    } catch (e) {
      return CommandResult(
        status: CommandStatus.failed,
        error: AdapterBase.mapException(e),
      );
    }
  }

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) {
    final intervalMs = spec.options?.intervalMs ?? 5000;
    final interval = Duration(milliseconds: intervalMs);
    late StreamController<PayloadEnvelope> ctrl;
    Timer? timer;

    Future<void> poll() async {
      if (ctrl.isClosed) return;
      try {
        final uri = _resolveUri(spec.uri);
        final response = await _transport.send(HttpIoRequest(
          method: 'GET', uri: uri, headers: defaultHeaders,
        ));
        if (!response.isSuccess) {
          ctrl.addError(IoError(
            code: 'exec.failed',
            message: 'HTTP ${response.status}',
            timestamp: DateTime.now(),
          ));
          return;
        }
        ctrl.add(_envelope(spec.uri, response));
      } catch (e) {
        if (!ctrl.isClosed) ctrl.addError(e);
      }
    }

    ctrl = StreamController<PayloadEnvelope>.broadcast(
      onListen: () {
        // Fire immediately, then at the requested cadence.
        poll();
        timer = Timer.periodic(interval, (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return ctrl.stream;
  }

  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async {
    // HTTP has no device-level emergency stop; return unsuccessful so callers
    // can surface the condition explicitly.
    return EmergencyStopResult(
      success: false,
      error: IoError(
        code: 'device.unsupported',
        message: 'HTTP REST devices have no generic emergency stop',
        timestamp: DateTime.now(),
      ),
    );
  }

  // === Internal helpers ===

  String? _methodForAction(String action) {
    switch (action) {
      case 'get':
        return 'GET';
      case 'post':
        return 'POST';
      case 'put':
        return 'PUT';
      case 'patch':
        return 'PATCH';
      case 'delete':
        return 'DELETE';
      default:
        return null;
    }
  }

  Uri _resolveUri(String target) {
    String path = target;
    final mapper = _uriMapper;
    if (mapper != null) {
      final mapping = mapper.resolve(target);
      if (mapping != null) path = mapping.nativeAddress;
    }
    // If the target path already looks absolute (starts with a scheme),
    // use it verbatim; otherwise append it to baseUri.
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    return baseUri.replace(
      path: (baseUri.path.isEmpty || baseUri.path == '/')
          ? normalized
          : '${_trimTrailingSlash(baseUri.path)}$normalized',
    );
  }

  String _trimTrailingSlash(String p) =>
      p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  PayloadEnvelope _envelope(String target, HttpIoResponse response) {
    final value = _parseBody(response.body);
    final type = (value is Map || value is List) ? PayloadType.struct_ : PayloadType.scalar;
    return PayloadEnvelope(
      uri: target,
      kind: PayloadKind.read,
      payload: TypedPayload(
        type: type,
        value: value,
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: response.headers['content-type'] ?? 'text/plain',
      ),
    );
  }

  Object? _parseBody(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return trimmed;
    }
  }
}
