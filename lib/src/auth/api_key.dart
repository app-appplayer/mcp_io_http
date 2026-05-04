import 'auth_provider.dart';

/// API key location.
enum ApiKeyLocation { header, query }

/// API key auth — header (`X-API-Key: <key>`) or query (`?api_key=<key>`).
class ApiKeyAuth implements AuthProvider {
  const ApiKeyAuth({
    required this.key,
    this.location = ApiKeyLocation.header,
    this.parameterName = 'X-API-Key',
  });

  final String key;
  final ApiKeyLocation location;

  /// Header name (when [location] is header) or query parameter name
  /// (when query). Default uses the `X-API-Key` header convention.
  final String parameterName;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    switch (location) {
      case ApiKeyLocation.header:
        builder.headers[parameterName] = key;
      case ApiKeyLocation.query:
        builder.queryParameters[parameterName] = key;
    }
  }

  @override
  Future<bool> tryRefresh() async => false;
}
