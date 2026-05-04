/// Builder façade passed to [AuthProvider.apply] so providers can
/// mutate request headers (and, for OAuth2, query parameters).
class HttpRequestBuilder {
  HttpRequestBuilder({
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  })  : headers = {...?headers},
        queryParameters = {...?queryParameters};

  final Map<String, String> headers;
  final Map<String, String> queryParameters;
}

/// Authentication scheme contract.
///
/// Each scheme [apply]s its credentials to an outbound request.
/// 401/403 responses can call [tryRefresh] to attempt a transparent
/// re-authentication; when it returns true the caller retries the
/// request, otherwise the error propagates.
///
abstract class AuthProvider {
  Future<void> apply(HttpRequestBuilder builder);

  Future<bool> tryRefresh() async => false;
}

/// No-op (no credentials).
class NoneAuth implements AuthProvider {
  const NoneAuth();
  @override
  Future<void> apply(HttpRequestBuilder builder) async {}
  @override
  Future<bool> tryRefresh() async => false;
}
