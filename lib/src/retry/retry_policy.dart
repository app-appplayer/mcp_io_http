/// Retry policy for HTTP requests.
///
class HttpRetryPolicy {
  const HttpRetryPolicy({
    this.maxAttempts = 5,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.retryableStatuses = const {408, 429, 500, 502, 503, 504},
    this.idempotentMethods = const {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'},
    this.honorRetryAfter = true,
  });

  /// Maximum total attempts (including the initial). 5 means 1 initial
  /// + up to 4 retries.
  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final double multiplier;

  /// Status codes that trigger a retry (subject to method idempotency).
  final Set<int> retryableStatuses;

  /// Methods considered idempotent. POST / PATCH retries require an
  /// `Idempotency-Key` header from the caller.
  final Set<String> idempotentMethods;

  /// Honour `Retry-After` header (delta-seconds or HTTP date) on 429 /
  /// 503.
  final bool honorRetryAfter;

  /// Decide whether [response] from [method] (with optional
  /// `Idempotency-Key`) on [attempt] (1-based) warrants a retry.
  bool shouldRetry({
    required int attempt,
    required int statusCode,
    required String method,
    bool hasIdempotencyKey = false,
  }) {
    if (attempt >= maxAttempts) return false;
    if (!retryableStatuses.contains(statusCode)) return false;
    final m = method.toUpperCase();
    if (!idempotentMethods.contains(m) && !hasIdempotencyKey) return false;
    return true;
  }

  /// Compute the delay before the next retry, honouring `Retry-After`
  /// when present and configured.
  Duration nextBackoff({
    required int attempt,
    String? retryAfterHeader,
  }) {
    if (honorRetryAfter && retryAfterHeader != null) {
      final ra = parseRetryAfter(retryAfterHeader);
      if (ra != null) return ra;
    }
    var ms = initialBackoff.inMilliseconds * _pow(multiplier, attempt - 1);
    if (ms > maxBackoff.inMilliseconds) ms = maxBackoff.inMilliseconds;
    return Duration(milliseconds: ms.toInt());
  }

  /// Parse `Retry-After`: either an integer-seconds delta or an HTTP
  /// date.
  static Duration? parseRetryAfter(String header) {
    final secs = int.tryParse(header.trim());
    if (secs != null) return Duration(seconds: secs);
    try {
      final at = DateTime.parse(header.trim());
      final delta = at.difference(DateTime.now());
      return delta.isNegative ? Duration.zero : delta;
    } on Object {
      return null;
    }
  }

  static num _pow(double base, int exp) {
    if (exp <= 0) return 1;
    var v = 1.0;
    for (var i = 0; i < exp; i++) {
      v *= base;
    }
    return v;
  }
}
