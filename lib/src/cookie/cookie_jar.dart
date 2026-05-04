/// Single stored cookie.
class HttpCookie {
  HttpCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  /// `Strict` / `Lax` / `None` (case-insensitive); null when unset.
  final String? sameSite;

  bool isExpired(DateTime now) {
    if (expires == null) return false;
    return now.isAfter(expires!);
  }

  /// Standard `Cookie:` header pair (`name=value`).
  String toHeaderPair() => '$name=$value';

  /// Parse one Set-Cookie value. The default cookie applies to the
  /// response URI's host when [defaultDomain] is supplied.
  factory HttpCookie.parseSetCookie(
    String setCookie, {
    String? defaultDomain,
    DateTime? now,
  }) {
    final parts = setCookie.split(';').map((s) => s.trim()).toList();
    if (parts.isEmpty) {
      throw FormatException('empty Set-Cookie: "$setCookie"');
    }
    final pair = parts.first;
    final eq = pair.indexOf('=');
    if (eq < 0) {
      throw FormatException('Set-Cookie has no name=value: "$setCookie"');
    }
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();

    String? domain = defaultDomain;
    String path = '/';
    DateTime? expires;
    var secure = false;
    var httpOnly = false;
    String? sameSite;

    for (var i = 1; i < parts.length; i++) {
      final p = parts[i];
      final pe = p.indexOf('=');
      final key = (pe < 0 ? p : p.substring(0, pe)).trim().toLowerCase();
      final v = pe < 0 ? '' : p.substring(pe + 1).trim();
      switch (key) {
        case 'domain':
          domain = v.isEmpty ? domain : v.toLowerCase();
        case 'path':
          path = v.isEmpty ? '/' : v;
        case 'expires':
          expires = _parseExpiresHeader(v);
        case 'max-age':
          final secs = int.tryParse(v);
          if (secs != null) {
            expires = (now ?? DateTime.now()).add(Duration(seconds: secs));
          }
        case 'secure':
          secure = true;
        case 'httponly':
          httpOnly = true;
        case 'samesite':
          sameSite = v;
      }
    }

    return HttpCookie(
      name: name,
      value: value,
      domain: domain ?? '',
      path: path,
      expires: expires,
      secure: secure,
      httpOnly: httpOnly,
      sameSite: sameSite,
    );
  }

  static DateTime? _parseExpiresHeader(String s) {
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } on Object {
      return null;
    }
  }
}

/// In-memory RFC 6265 cookie jar.
///
/// - Match key: `(domain, path, name)` → unique cookie
/// - `Set-Cookie` parsed via [HttpCookie.parseSetCookie]
/// - `Cookie:` header rebuilt by domain/path matching for outbound URI
class CookieJar {
  CookieJar({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final List<HttpCookie> _cookies = [];
  final DateTime Function() _clock;

  /// Insert / replace cookies parsed from `Set-Cookie` headers.
  void store(Uri url, List<String> setCookieHeaders) {
    for (final raw in setCookieHeaders) {
      final cookie = HttpCookie.parseSetCookie(
        raw,
        defaultDomain: url.host,
        now: _clock(),
      );
      _cookies.removeWhere((c) =>
          c.domain == cookie.domain &&
          c.path == cookie.path &&
          c.name == cookie.name);
      _cookies.add(cookie);
    }
    _cleanupExpired();
  }

  /// Cookies that match outbound [url] under domain + path + secure
  /// rules. Returns the value that should appear in the `Cookie:`
  /// header.
  String? buildCookieHeader(Uri url) {
    _cleanupExpired();
    final matching = _cookies.where((c) => _matches(c, url)).toList();
    if (matching.isEmpty) return null;
    return matching.map((c) => c.toHeaderPair()).join('; ');
  }

  List<HttpCookie> all() => List.unmodifiable(_cookies);

  void clear({Uri? url}) {
    if (url == null) {
      _cookies.clear();
    } else {
      _cookies.removeWhere((c) => _matches(c, url));
    }
  }

  bool _matches(HttpCookie cookie, Uri url) {
    if (cookie.isExpired(_clock())) return false;
    if (cookie.secure && url.scheme != 'https') return false;
    if (!_domainMatches(cookie.domain, url.host)) return false;
    if (!_pathMatches(cookie.path, url.path)) return false;
    return true;
  }

  static bool _domainMatches(String cookieDomain, String host) {
    if (cookieDomain.isEmpty) return false;
    final cd =
        cookieDomain.startsWith('.') ? cookieDomain.substring(1) : cookieDomain;
    if (cd == host) return true;
    return host.endsWith('.$cd');
  }

  static bool _pathMatches(String cookiePath, String requestPath) {
    final reqPath = requestPath.isEmpty ? '/' : requestPath;
    if (cookiePath == reqPath) return true;
    if (reqPath.startsWith(cookiePath)) {
      if (cookiePath.endsWith('/')) return true;
      if (reqPath.length > cookiePath.length &&
          reqPath[cookiePath.length] == '/') {
        return true;
      }
    }
    return false;
  }

  void _cleanupExpired() {
    final now = _clock();
    _cookies.removeWhere((c) => c.isExpired(now));
  }
}
