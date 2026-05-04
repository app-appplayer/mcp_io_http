import 'auth_provider.dart';

/// OAuth 2.0 grant types supported by [OAuth2Auth].
enum OAuth2GrantType { clientCredentials, refreshToken }

/// Pluggable token endpoint client. Implementations send the token
/// request and parse the JSON response, returning the issued token
/// triple. Kept abstract so callers can plug their HTTP client of
/// choice (avoiding circular dependency with the adapter).
abstract class OAuth2TokenClient {
  /// Exchange [grant] (with optional [refreshToken] / [scope]) at
  /// [tokenEndpoint] using the supplied client credentials. Returns
  /// the granted access token plus optional refresh token.
  Future<OAuth2TokenResponse> requestToken({
    required Uri tokenEndpoint,
    required String clientId,
    String? clientSecret,
    required OAuth2GrantType grant,
    String? refreshToken,
    String? scope,
  });
}

class OAuth2TokenResponse {
  const OAuth2TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
    this.tokenType = 'Bearer',
  });

  final String accessToken;
  final String? refreshToken;

  /// Server-reported lifetime in seconds.
  final int? expiresIn;

  final String tokenType;
}

/// OAuth 2.0 client_credentials / refresh_token flows.
class OAuth2Auth implements AuthProvider {
  OAuth2Auth({
    required this.tokenClient,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.scope,
    String? refreshToken,
    Duration earlyRefresh = const Duration(seconds: 30),
  })  : _refreshToken = refreshToken,
        _earlyRefresh = earlyRefresh;

  final OAuth2TokenClient tokenClient;
  final Uri tokenEndpoint;
  final String clientId;
  final String? clientSecret;
  final String? scope;

  String? _refreshToken;
  String? _accessToken;
  DateTime? _expiresAt;
  final Duration _earlyRefresh;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    if (_accessToken == null || _isExpired()) {
      await _fetchOrRefresh();
    }
    builder.headers['Authorization'] = 'Bearer $_accessToken';
  }

  @override
  Future<bool> tryRefresh() async {
    if (_refreshToken == null) {
      // Fall back to client_credentials on 401.
      if (clientSecret == null) return false;
      await _fetchOrRefresh(force: true);
      return _accessToken != null;
    }
    await _fetchOrRefresh(force: true);
    return _accessToken != null;
  }

  bool _isExpired() {
    final exp = _expiresAt;
    if (exp == null) return false;
    return DateTime.now()
        .isAfter(exp.subtract(_earlyRefresh));
  }

  Future<void> _fetchOrRefresh({bool force = false}) async {
    final resp = await tokenClient.requestToken(
      tokenEndpoint: tokenEndpoint,
      clientId: clientId,
      clientSecret: clientSecret,
      grant: _refreshToken != null
          ? OAuth2GrantType.refreshToken
          : OAuth2GrantType.clientCredentials,
      refreshToken: _refreshToken,
      scope: scope,
    );
    _accessToken = resp.accessToken;
    _refreshToken = resp.refreshToken ?? _refreshToken;
    _expiresAt = resp.expiresIn != null
        ? DateTime.now().add(Duration(seconds: resp.expiresIn!))
        : null;
  }
}
