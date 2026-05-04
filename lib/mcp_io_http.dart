/// HTTP / REST adapter for mcp_io.
library;

// Transport + adapter (legacy, BC).
export 'src/http_io_transport.dart';
export 'src/http2_io_transport.dart';
export 'src/http_io_adapter.dart';

// Auth providers.
export 'src/auth/api_key.dart';
export 'src/auth/auth_provider.dart';
export 'src/auth/basic.dart';
export 'src/auth/bearer.dart';
export 'src/auth/mtls.dart';
export 'src/auth/oauth2.dart';

// Cookie jar.
export 'src/cookie/cookie_jar.dart';

// Multipart bodies.
export 'src/multipart/multipart_body.dart';

// Subscribe (SSE).
export 'src/subscribe/sse_parser.dart';

// Retry policy.
export 'src/retry/retry_policy.dart';

// Status mapping.
export 'src/mapping/status_to_ioerror.dart';
