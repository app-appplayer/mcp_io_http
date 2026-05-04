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

import 'auth/auth_provider.dart';
import 'cookie/cookie_jar.dart';
import 'http_io_transport.dart';
import 'mapping/status_to_ioerror.dart';
import 'retry/retry_policy.dart';
import 'subscribe/sse_parser.dart';

class HttpIoAdapter extends AdapterBase {
  final String deviceId;
  final Uri baseUri;
  final HttpIoTransport _transport;
  final UriMapper? _uriMapper;
  final Map<String, String> defaultHeaders;

  /// Optional auth provider. Default `NoneAuth`.
  final AuthProvider auth;

  /// Optional cookie jar. When supplied, Set-Cookie headers in responses
  /// are stored and outbound requests automatically attach `Cookie:`.
  final CookieJar? cookieJar;

  /// Retry policy applied to transport-level errors and 5xx responses.
  final HttpRetryPolicy retryPolicy;

  IoConnectionState _state = IoConnectionState.disconnected;

  HttpIoAdapter({
    required this.deviceId,
    required this.baseUri,
    required HttpIoTransport transport,
    UriMapper? uriMapper,
    this.defaultHeaders = const {},
    AuthProvider? auth,
    this.cookieJar,
    HttpRetryPolicy? retryPolicy,
    AdapterManifest? manifest,
  })  : _transport = transport,
        _uriMapper = uriMapper,
        auth = auth ?? const NoneAuth(),
        retryPolicy = retryPolicy ?? const HttpRetryPolicy(),
        super(manifest: manifest ?? _defaultManifest);

  static final AdapterManifest _defaultManifest = AdapterManifest(
    adapterId: 'mcp_io_http',
    adapterVersion: '0.2.0',
    contractVersionRange: '>=0.1.0 <1.0.0',
    displayName: 'HTTP REST Adapter',
    description:
        'HTTP REST adapter — 7 methods, 5 auth schemes (Basic/Bearer/APIKey/'
        'OAuth2/mTLS) + AuthChain, RFC 6265 cookie jar, RFC 7578 multipart, '
        'SSE parser, retry with Retry-After, 4xx/5xx → IoError mapping.',
    capabilities: const [
      CapabilityDescriptor(action: 'http.get', safetyClass: SafetyClass.safe),
      CapabilityDescriptor(action: 'http.head', safetyClass: SafetyClass.safe),
      CapabilityDescriptor(action: 'http.options', safetyClass: SafetyClass.safe),
      CapabilityDescriptor(action: 'http.post', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'http.put', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'http.patch', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'http.delete', safetyClass: SafetyClass.dangerous),
      CapabilityDescriptor(action: 'http.subscribe_sse', safetyClass: SafetyClass.safe),
    ],
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
        final response = await _send(method: 'GET', uri: uri);
        if (!response.isSuccess) {
          items.add(ReadResultItem(
            uri: target,
            error: HttpStatusToIoError.fromStatus(
                  response.status,
                  reasonPhrase: response.body,
                ) ??
                IoError(
                  code: 'exec.failed',
                  message: 'HTTP ${response.status}',
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
      final extraHeaders =
          (command.args['headers'] as Map?)?.cast<String, String>();
      String? body;
      final rawBody = command.args['body'];
      String? contentType;
      if (rawBody != null) {
        if (rawBody is String) {
          body = rawBody;
        } else {
          body = jsonEncode(rawBody);
          contentType = 'application/json';
        }
      }
      final hasIdempotencyKey = command.args['idempotencyKey'] != null ||
          (extraHeaders?.containsKey('Idempotency-Key') ?? false);
      final response = await _send(
        method: method,
        uri: uri,
        extraHeaders: extraHeaders,
        body: body,
        contentType: contentType,
        hasIdempotencyKey: hasIdempotencyKey,
      );
      if (!response.isSuccess) {
        return CommandResult(
          status: CommandStatus.failed,
          error: HttpStatusToIoError.fromStatus(
                response.status,
                reasonPhrase: response.body,
              ) ??
              IoError(
                code: 'exec.failed',
                message: 'HTTP ${response.status}',
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
    // SSE mode: client opens a long-lived stream and consumes
    // text/event-stream events. Triggered by `mode: 'sse'` option.
    final mode = spec.options?.toJson()['mode'] as String?;
    if (mode == 'sse') return _subscribeSse(spec);
    return _subscribePolling(spec);
  }

  Stream<PayloadEnvelope> _subscribePolling(TopicSpec spec) {
    final intervalMs = spec.options?.intervalMs ?? 5000;
    final interval = Duration(milliseconds: intervalMs);
    late StreamController<PayloadEnvelope> ctrl;
    Timer? timer;

    Future<void> poll() async {
      if (ctrl.isClosed) return;
      try {
        final uri = _resolveUri(spec.uri);
        // Poll path skips the request-level retry loop — the next tick
        // retries naturally, surfacing transient 5xx responses to the
        // consumer immediately.
        final response = await _transport.send(HttpIoRequest(
          method: 'GET',
          uri: uri,
          headers: defaultHeaders,
        ));
        if (!response.isSuccess) {
          ctrl.addError(HttpStatusToIoError.fromStatus(response.status) ??
              IoError(
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

  /// SSE subscribe — sends an Accept: text/event-stream request and
  /// transforms each event line into a [PayloadEnvelope]. The transport
  /// returns a single response with the entire body streamed back as
  /// `body`; for line-by-line streams callers should bind a
  /// streaming-capable transport. The default
  /// [DartHttpIoTransport] returns the entire body once the connection
  /// closes — useful for tests + bursty SSE; long-lived streams need a
  /// chunked-aware transport (deferred to v1.x).
  Stream<PayloadEnvelope> _subscribeSse(TopicSpec spec) {
    late StreamController<PayloadEnvelope> ctrl;
    bool cancelled = false;
    String? lastEventId;

    Future<void> run() async {
      while (!cancelled) {
        try {
          final uri = _resolveUri(spec.uri);
          final response = await _send(
            method: 'GET',
            uri: uri,
            extraHeaders: {
              'Accept': 'text/event-stream',
              if (lastEventId != null) 'Last-Event-ID': lastEventId!,
            },
          );
          if (!response.isSuccess) {
            if (!ctrl.isClosed) {
              ctrl.addError(
                  HttpStatusToIoError.fromStatus(response.status) ??
                      IoError(
                        code: 'exec.failed',
                        message: 'HTTP ${response.status}',
                        timestamp: DateTime.now(),
                      ));
            }
            return;
          }
          // Parse each SSE event from the body. For test transports
          // that buffer the entire response this completes in one go;
          // for streaming-capable transports each chunk is parsed
          // incrementally via the same parser pipeline.
          final events = await Stream<String>.value(response.body)
              .transform(const SseParser().transformer)
              .toList();
          for (final event in events) {
            if (cancelled || ctrl.isClosed) return;
            if (event.id != null) lastEventId = event.id;
            ctrl.add(_sseEnvelope(spec.uri, event));
          }
          // SSE expects long-lived streams; bail out of the loop after
          // the body completes since the default transport doesn't
          // hold the stream open. Real streaming transports drive the
          // loop via reconnect logic.
          return;
        } on Object catch (e) {
          if (!ctrl.isClosed) ctrl.addError(e);
          return;
        }
      }
    }

    ctrl = StreamController<PayloadEnvelope>.broadcast(
      onListen: run,
      onCancel: () => cancelled = true,
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

  /// Map either short ('get') or namespaced ('http.get') action names
  /// to the corresponding HTTP method. Returns null for unknown.
  String? _methodForAction(String action) {
    switch (action) {
      // Legacy short names (pre-0.2.0).
      case 'get':
        return 'GET';
      case 'head':
        return 'HEAD';
      case 'options':
        return 'OPTIONS';
      case 'post':
        return 'POST';
      case 'put':
        return 'PUT';
      case 'patch':
        return 'PATCH';
      case 'delete':
        return 'DELETE';
      // 0.2.0 capability ids.
      case 'http.get':
        return 'GET';
      case 'http.head':
        return 'HEAD';
      case 'http.options':
        return 'OPTIONS';
      case 'http.post':
        return 'POST';
      case 'http.put':
        return 'PUT';
      case 'http.patch':
        return 'PATCH';
      case 'http.delete':
        return 'DELETE';
      default:
        return null;
    }
  }

  /// Send a request with auth + cookies + retry applied.
  Future<HttpIoResponse> _send({
    required String method,
    required Uri uri,
    Map<String, String>? extraHeaders,
    String? body,
    String? contentType,
    bool hasIdempotencyKey = false,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final builder = HttpRequestBuilder(headers: <String, String>{
        ...defaultHeaders,
        if (contentType != null) 'content-type': contentType,
        ...?extraHeaders,
      });
      await auth.apply(builder);

      // Attach cookies for the resolved URI.
      var requestUri = uri;
      if (builder.queryParameters.isNotEmpty) {
        requestUri = uri.replace(queryParameters: <String, String>{
          ...uri.queryParameters,
          ...builder.queryParameters,
        });
      }
      final cookieHeader = cookieJar?.buildCookieHeader(requestUri);
      if (cookieHeader != null) {
        builder.headers['Cookie'] = cookieHeader;
      }

      final response = await _transport.send(HttpIoRequest(
        method: method,
        uri: requestUri,
        headers: builder.headers,
        body: body,
      ));

      // Persist Set-Cookie.
      final setCookies = response.headers.entries
          .where((e) => e.key.toLowerCase() == 'set-cookie')
          .map((e) => e.value)
          .toList();
      if (setCookies.isNotEmpty && cookieJar != null) {
        cookieJar!.store(requestUri, setCookies);
      }

      // 401 / 403 → try a single auth refresh + replay.
      if ((response.status == 401 || response.status == 403) &&
          attempt == 1) {
        final refreshed = await auth.tryRefresh();
        if (refreshed) continue;
      }

      // Retry on retryable status when policy allows.
      final shouldRetry = retryPolicy.shouldRetry(
        attempt: attempt,
        statusCode: response.status,
        method: method,
        hasIdempotencyKey: hasIdempotencyKey,
      );
      if (!shouldRetry) return response;

      final retryAfter = response.headers['retry-after'] ??
          response.headers['Retry-After'];
      final delay = retryPolicy.nextBackoff(
          attempt: attempt, retryAfterHeader: retryAfter);
      await Future<void>.delayed(delay);
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

  PayloadEnvelope _sseEnvelope(String target, SseEvent event) {
    return PayloadEnvelope(
      uri: target,
      kind: PayloadKind.event,
      payload: TypedPayload(
        type: PayloadType.scalar,
        value: event.data,
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: 'sse:${event.event ?? 'message'}',
      ),
    );
  }
}
