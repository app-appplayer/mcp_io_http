import 'dart:convert';
import 'dart:typed_data';

/// One part inside a multipart/form-data body.
class MultipartPart {
  MultipartPart({
    required this.name,
    this.filename,
    this.contentType,
    this.headers = const {},
    Object? text,
    List<int>? bytes,
  })  : _text = text as String?,
        _bytes = bytes != null ? Uint8List.fromList(bytes) : null,
        assert(text != null || bytes != null,
            'one of text/bytes is required');

  /// `name=` field of the Content-Disposition header.
  final String name;

  /// Optional `filename=` field — present for file uploads.
  final String? filename;

  /// Per-part Content-Type (e.g. `application/octet-stream`,
  /// `image/png`). When omitted text parts default to UTF-8 plain.
  final String? contentType;

  /// Extra per-part headers (rare — added verbatim after C-D / C-T).
  final Map<String, String> headers;

  final String? _text;
  final Uint8List? _bytes;

  Uint8List bodyBytes() {
    if (_bytes != null) return _bytes;
    return Uint8List.fromList(utf8.encode(_text!));
  }
}

/// RFC 7578 multipart/form-data writer.
class MultipartBody {
  MultipartBody({
    required this.parts,
    String? boundary,
  }) : boundary = boundary ?? _defaultBoundary();

  /// Boundary token (without leading `--`).
  final String boundary;
  final List<MultipartPart> parts;

  String get contentTypeHeader =>
      'multipart/form-data; boundary=$boundary';

  Uint8List encode() {
    final out = BytesBuilder();
    final crlf = '\r\n'.codeUnits;
    final dashes = '--'.codeUnits;
    for (final part in parts) {
      out.add(dashes);
      out.add(boundary.codeUnits);
      out.add(crlf);

      final cd = StringBuffer('Content-Disposition: form-data; name="${_escape(part.name)}"');
      if (part.filename != null) {
        cd.write('; filename="${_escape(part.filename!)}"');
      }
      out.add(cd.toString().codeUnits);
      out.add(crlf);

      if (part.contentType != null) {
        out.add('Content-Type: ${part.contentType}'.codeUnits);
        out.add(crlf);
      }
      for (final h in part.headers.entries) {
        out.add('${h.key}: ${h.value}'.codeUnits);
        out.add(crlf);
      }
      out.add(crlf); // header/body separator
      out.add(part.bodyBytes());
      out.add(crlf);
    }
    out.add(dashes);
    out.add(boundary.codeUnits);
    out.add(dashes);
    out.add(crlf);
    return out.takeBytes();
  }

  static String _escape(String value) =>
      value.replaceAll('"', r'\"').replaceAll('\n', '');

  static String _defaultBoundary() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    return '----dart-mcp-io-$ts';
  }
}
