import 'auth_provider.dart';

/// `Authorization: Bearer <token>` — JWT, opaque API tokens, etc.
///
/// When [tokenProvider] is supplied the token is fetched per request
/// (allowing dynamic / refreshable tokens). Otherwise [token] is used.
class BearerAuth implements AuthProvider {
  BearerAuth({String? token, Future<String> Function()? tokenProvider})
      : assert(token != null || tokenProvider != null,
            'either token or tokenProvider must be supplied'),
        _staticToken = token,
        _tokenProvider = tokenProvider;

  final String? _staticToken;
  final Future<String> Function()? _tokenProvider;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    final token = _staticToken ?? await _tokenProvider!();
    builder.headers['Authorization'] = 'Bearer $token';
  }

  @override
  Future<bool> tryRefresh() async => false;
}
