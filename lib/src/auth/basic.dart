import 'dart:convert';

import 'auth_provider.dart';

/// HTTP Basic auth (`Authorization: Basic <base64(user:pass)>`).
class BasicAuth implements AuthProvider {
  const BasicAuth({required this.username, required this.password});

  final String username;
  final String password;

  @override
  Future<void> apply(HttpRequestBuilder builder) async {
    final raw = '$username:$password';
    final token = base64Encode(utf8.encode(raw));
    builder.headers['Authorization'] = 'Basic $token';
  }

  @override
  Future<bool> tryRefresh() async => false;
}
