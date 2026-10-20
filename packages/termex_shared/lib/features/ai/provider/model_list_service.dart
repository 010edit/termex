/// Fetches model IDs from an OpenAI-compatible `/models` endpoint.
///
/// The Custom provider needs a one-shot list request that is independent of
/// the chat client. Doing it in Dart avoids adding an FRB method (and a
/// codegen round-trip) for a settings-only call. The request is only made
/// when the user clicks Verify in a provider form.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Parses an OpenAI-compatible `/models` response into sorted, unique IDs.
///
/// Accepts the common shapes:
///   - `{"object":"list","data":[{"id":"gpt-4o-mini"}]}`
///   - `{"models":[{"name":"qwen2.5:7b"}]}`
///   - `["model-a", "model-b"]`
List<String> parseOpenAiModelIds(String body) {
  final decoded = jsonDecode(body);
  final entries = switch (decoded) {
    List<dynamic> list => list,
    Map<String, dynamic> map => switch (map['data'] ?? map['models']) {
        List<dynamic> list => list,
        _ => const <dynamic>[],
      },
    _ => const <dynamic>[],
  };

  final ids = <String>{};
  void add(dynamic value) {
    if (value is String && value.trim().isNotEmpty) {
      ids.add(value.trim());
    }
  }

  for (final entry in entries) {
    if (entry is String) {
      add(entry);
    } else if (entry is Map) {
      add(entry['id'] ?? entry['name'] ?? entry['model']);
    }
  }

  final result = ids.toList()..sort();
  if (result.isEmpty) {
    throw const FormatException('No models returned by /models');
  }
  return result;
}

/// GET `{baseUrl}/models` with the same Bearer token the chat path uses.
///
/// `baseUrl` must include the API version prefix, e.g.
/// `http://10.200.200.19:8601/v1`.
Future<List<String>> fetchOpenAiModels({
  required String baseUrl,
  required String apiKey,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty) {
    throw const FormatException('Base URL is empty');
  }

  final uri = Uri.parse('$base/models');
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (apiKey.trim().isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${apiKey.trim()}',
      );
    }

    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'HTTP ${response.statusCode}: ${_safeSnippet(body, apiKey)}',
        uri: uri,
      );
    }
    return parseOpenAiModelIds(body);
  } finally {
    client.close(force: true);
  }
}

/// Keep error text useful without leaking the API key or dumping a huge body.
String _safeSnippet(String body, String apiKey) {
  var text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (apiKey.trim().isNotEmpty) {
    text = text.replaceAll(apiKey.trim(), '<redacted>');
  }
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
