import 'package:mcp_bundle/mcp_bundle.dart';

/// HTTP response status → canonical [IoError] code.
///
class HttpStatusToIoError {
  HttpStatusToIoError._();

  /// Convert non-2xx [status] (with optional [reasonPhrase]) into an
  /// [IoError]. Returns `null` for success / redirect.
  static IoError? fromStatus(int status,
      {String? reasonPhrase, DateTime? timestamp}) {
    if (status >= 200 && status < 400) return null;
    final ts = timestamp ?? DateTime.now();
    return IoError(
      code: _codeFor(status),
      message: 'HTTP $status${reasonPhrase != null ? ' $reasonPhrase' : ''}',
      timestamp: ts,
    );
  }

  static String _codeFor(int status) {
    switch (status) {
      case 400:
        return 'request.bad';
      case 401:
        return 'auth.unauthorized';
      case 403:
        return 'auth.forbidden';
      case 404:
        return 'resource.not_found';
      case 405:
        return 'request.method_not_allowed';
      case 408:
        return 'transport.timeout';
      case 409:
        return 'resource.conflict';
      case 410:
        return 'resource.gone';
      case 413:
        return 'request.payload_too_large';
      case 415:
        return 'request.media_unsupported';
      case 429:
        return 'quota.rate_limit';
      case 500:
        return 'server.internal';
      case 502:
        return 'gateway.bad';
      case 503:
        return 'server.unavailable';
      case 504:
        return 'gateway.timeout';
      default:
        if (status >= 400 && status < 500) return 'request.error';
        if (status >= 500) return 'server.error';
        return 'protocol.unknown';
    }
  }
}
