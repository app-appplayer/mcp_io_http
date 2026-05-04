## [0.2.0] - 2026-05-04

- HTTP/1.1 transport with connection-pool tuning + HTTP/2 transport
  (TLS+ALPN h2 + h2c, stream multiplex, origin pinning).
- Authentication (API Key / Basic / Bearer / OAuth 2.0 / mTLS), cookie
  jar, multipart bodies.
- Server-Sent Events (SSE) parser for `subscribe`.
- Retry policy + status code → `IoError` mapping.

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- HTTP REST transport and adapter for mcp_io.
- GET (read), POST / PUT / PATCH / DELETE / execute methods.
- Polling-based subscribe.
