import 'auth_provider.dart';

/// Mutual TLS — declarative bundle of client cert + key. The actual
/// transport (e.g. `dart:io HttpClient`) consumes these to build a
/// `SecurityContext`; this provider does not mutate request headers.
///
/// Combined with other providers (e.g. Bearer) the builder façade
/// pattern composes — pass [AuthChain].
class MutualTlsAuth implements AuthProvider {
  const MutualTlsAuth({
    required this.clientCertBytes,
    required this.clientKeyBytes,
    this.privateKeyPassword,
    this.trustedCaBytes,
  });

  /// PEM (or DER) encoded client certificate chain.
  final List<int> clientCertBytes;

  /// PEM (or DER) encoded client private key.
  final List<int> clientKeyBytes;

  /// Optional password for encrypted private keys.
  final String? privateKeyPassword;

  /// Optional trusted CA bundle. When omitted the system trust store
  /// is used.
  final List<int>? trustedCaBytes;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    // No request headers — the transport is responsible for binding
    // these credentials at SecurityContext / HttpClient creation time.
  }

  @override
  Future<bool> tryRefresh() async => false;
}

/// Compose multiple providers (e.g. mTLS + Bearer). All providers'
/// [apply] are invoked in order; the first non-false [tryRefresh]
/// wins.
class AuthChain implements AuthProvider {
  AuthChain(this.providers);

  final List<AuthProvider> providers;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    for (final p in providers) {
      await p.apply(builder);
    }
  }

  @override
  Future<bool> tryRefresh() async {
    for (final p in providers) {
      if (await p.tryRefresh()) return true;
    }
    return false;
  }
}
