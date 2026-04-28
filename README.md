# MCP IO HTTP

HTTP REST adapter for [`mcp_io`](https://pub.dev/packages/mcp_io). GET / read, POST / PUT / PATCH / DELETE / execute, and polling-based subscribe.

```dart
import 'package:mcp_io_http/mcp_io_http.dart';

final adapter = HttpIoAdapter(HttpIoTransport(baseUri));
registry.register('rest-api', adapter);
```

## License

MIT — see [LICENSE](LICENSE).
