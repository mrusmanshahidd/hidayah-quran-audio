import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiFailure implements Exception {
  const ApiFailure(this.status, this.message, {this.upstreamStatus, this.type});
  final int status;
  final String message;
  final int? upstreamStatus;
  final String? type;
}

class QuranFoundationAudioApi {
  QuranFoundationAudioApi({
    required this.clientId,
    required this.clientSecret,
    String environment = 'prelive',
    Uri? authBase,
    Uri? apiBase,
    HttpClient? client,
    this.development = false,
    this.scope = 'content',
    this.allowedOrigins = const {},
  }) : environment = environment,
       authBase =
           authBase ??
           Uri.parse(
             environment == 'production'
                 ? 'https://oauth2.quran.foundation'
                 : 'https://prelive-oauth2.quran.foundation',
           ),
       apiBase =
           apiBase ??
           Uri.parse(
             environment == 'production'
                 ? 'https://apis.quran.foundation'
                 : 'https://apis-prelive.quran.foundation',
           ),
       _client = client ?? HttpClient() {
    if (environment != 'prelive' && environment != 'production') {
      throw ArgumentError.value(environment, 'environment');
    }
    _client.connectionTimeout = const Duration(seconds: 8);
  }

  final String clientId;
  final String clientSecret;
  final String environment;
  final Uri authBase;
  final Uri apiBase;
  final HttpClient _client;
  final bool development;
  final String scope;
  final Set<String> allowedOrigins;
  String? _token;
  DateTime? _expiresAt;
  Future<String>? _tokenRequest;

  bool get configured =>
      clientId.isNotEmpty &&
      clientSecret.isNotEmpty &&
      !clientId.startsWith('your-') &&
      !clientSecret.startsWith('your-');

  String _safe(String value) {
    var result = value.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
    if (clientSecret.isNotEmpty) {
      result = result.replaceAll(clientSecret, '[redacted]');
    }
    if (clientId.isNotEmpty) result = result.replaceAll(clientId, '[redacted]');
    if (_token != null) result = result.replaceAll(_token!, '[redacted]');
    result = result.replaceAll(
      RegExp(r'(basic|bearer)\s+[a-z0-9+/=_-]+', caseSensitive: false),
      '[redacted]',
    );
    return result.length > 300 ? result.substring(0, 300) : result;
  }

  ApiFailure _upstreamError(int status, String body, String path) {
    String? type;
    String? message;
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        type = (data['type'] ?? data['error']) is String
            ? (data['type'] ?? data['error']) as String
            : null;
        message = (data['message'] ?? data['error_description']) is String
            ? (data['message'] ?? data['error_description']) as String
            : null;
      }
    } on FormatException {
      /* An HTML or empty upstream response has no safe details. */
    }
    type = type == null ? 'http_error' : _safe(type);
    message = message == null ? 'Upstream request failed.' : _safe(message);
    if (type == 'invalid_scope') {
      message =
          'Requested scope "$scope" was not approved. Check the approved Content scopes in Quran Foundation Developer Console; use content today unless this client was issued granular scopes.';
    }
    if (development) {
      stderr.writeln(
        'QF upstream: environment=$environment path=$path status=$status type=$type message=$message',
      );
    }
    return ApiFailure(
      status,
      development ? message : 'Quran audio service is currently unavailable.',
      upstreamStatus: status,
      type: type,
    );
  }

  ApiFailure _transportError(String path, String type, String details) {
    if (development) {
      stderr.writeln(
        'QF upstream: environment=$environment path=$path status=unavailable type=$type message=${_safe(details)}',
      );
    }
    return ApiFailure(
      503,
      'Quran audio service is currently unavailable.',
      type: type,
    );
  }

  Future<String> _accessToken() async {
    if (!configured) {
      throw const ApiFailure(503, 'Audio service is not configured.');
    }
    if (_token != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!)) {
      return _token!;
    }
    return _tokenRequest ??= _fetchToken().whenComplete(
      () => _tokenRequest = null,
    );
  }

  Future<String> _fetchToken() async {
    try {
      final request = await _client.postUrl(authBase.resolve('/oauth2/token'));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}',
      );
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'HidayahAudio/1.0');
      request.write(
        Uri(
          queryParameters: {'grant_type': 'client_credentials', 'scope': scope},
        ).query,
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw _upstreamError(response.statusCode, body, '/oauth2/token');
      }
      final data = jsonDecode(body);
      if (data is! Map ||
          data['access_token'] is! String ||
          data['expires_in'] is! num ||
          (data['expires_in'] as num) <= 0) {
        throw const ApiFailure(502, 'Invalid audio authentication response.');
      }
      _token = data['access_token'] as String;
      final seconds = (data['expires_in'] as num).toInt();
      _expiresAt = DateTime.now().add(
        Duration(seconds: seconds > 60 ? seconds - 60 : seconds - 1),
      );
      return _token!;
    } on ApiFailure {
      rethrow;
    } on SocketException catch (error) {
      throw _transportError('/oauth2/token', 'network_error', error.message);
    } on HandshakeException catch (error) {
      throw _transportError('/oauth2/token', 'tls_error', error.message);
    } on TimeoutException catch (error) {
      throw _transportError(
        '/oauth2/token',
        'timeout',
        error.message ?? 'Timed out.',
      );
    } on FormatException {
      throw const ApiFailure(502, 'Invalid audio authentication response.');
    }
  }

  Future<Map<String, dynamic>> _content(Uri path, {bool retry = true}) async {
    try {
      final token = await _accessToken();
      final request = await _client.getUrl(apiBase.resolveUri(path));
      request.headers.set('x-auth-token', token);
      request.headers.set('x-client-id', clientId);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401 && retry) {
        _token = null;
        _expiresAt = null;
        return await _content(path, retry: false);
      }
      if (response.statusCode != 200) {
        throw _upstreamError(response.statusCode, body, path.path);
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        throw const ApiFailure(502, 'Invalid Quran audio response.');
      }
      return data;
    } on ApiFailure {
      rethrow;
    } on SocketException catch (error) {
      throw _transportError(path.path, 'network_error', error.message);
    } on HandshakeException catch (error) {
      throw _transportError(path.path, 'tls_error', error.message);
    } on TimeoutException catch (error) {
      throw _transportError(
        path.path,
        'timeout',
        error.message ?? 'Timed out.',
      );
    } on FormatException {
      throw const ApiFailure(502, 'Invalid Quran audio response.');
    }
  }

  Future<List<Map<String, dynamic>>> reciters() async {
    final data = await _content(
      Uri(path: '/content/api/v4/resources/recitations'),
    );
    final rows = data['recitations'];
    if (rows is! List) throw const ApiFailure(502, 'Invalid reciter response.');
    return [
      for (final row in rows)
        if (row is Map &&
            row['id'] is int &&
            row['id'] > 0 &&
            (row['reciter_name'] is String || row['translated_name'] is Map))
          {
            'id': row['id'],
            'reciterName':
                (row['translated_name'] is Map &&
                    row['translated_name']['name'] is String)
                ? row['translated_name']['name']
                : row['reciter_name'],
            'style': row['style'] is String ? row['style'] : null,
          },
    ];
  }

  Future<Map<String, Object?>> debugReport() async {
    final report = <String, Object?>{
      'configured': configured,
      'environment': environment,
    };
    Future<bool> check(String name, Future<void> Function() action) async {
      try {
        await action();
        report[name] = {'success': true, 'status': 200};
        return true;
      } on ApiFailure catch (error) {
        report[name] = {
          'success': false,
          'status': error.upstreamStatus ?? error.status,
        };
        return false;
      }
    }

    if (!await check('tokenRequest', () async {
      await _accessToken();
    })) {
      report['chaptersRequest'] = {'success': false, 'status': null};
      report['recitersRequest'] = {'success': false, 'status': null};
      return report;
    }
    if (!await check('chaptersRequest', () async {
      await _content(Uri(path: '/content/api/v4/chapters'));
    })) {
      report['recitersRequest'] = {'success': false, 'status': null};
      return report;
    }
    await check('recitersRequest', () async {
      await reciters();
    });
    return report;
  }

  Future<Map<String, dynamic>> verseAudio(
    String verseKey,
    int recitationId,
  ) async {
    final data = await _content(
      Uri(
        path: '/content/api/v4/recitations/$recitationId/by_ayah/$verseKey',
        queryParameters: {'fields': 'segments'},
      ),
    );
    final files = data['audio_files'];
    if (files is! List) {
      throw const ApiFailure(502, 'Invalid Quran audio response.');
    }
    for (final file in files) {
      if (file is! Map || file['verse_key'] != verseKey) continue;
      final value = file['url'];
      if (value is! String || value.isEmpty) break;
      final parsed = Uri.tryParse(value);
      if (parsed == null) break;
      // The API supplies the asset path; only its CDN origin is supplied here.
      final url = parsed.hasScheme
          ? parsed
          : value.startsWith('//')
          ? Uri.parse('https:$value')
          : Uri.parse('https://audio.qurancdn.com/')
                .resolve(value.replaceFirst(RegExp(r'^/+'), ''));
      if (url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        break;
      }
      return {
        'verseKey': verseKey,
        'recitationId': recitationId,
        'audioUrl': url.toString(),
        'segments': file['segments'] is List ? file['segments'] : const [],
      };
    }
    throw const ApiFailure(404, 'Audio is unavailable for this Ayah.');
  }

  void close() => _client.close(force: true);
}

Future<void> handleAudioRequest(
  HttpRequest request,
  QuranFoundationAudioApi api,
) async {
  final path = request.uri.pathSegments;
  final response = request.response;
  response.headers.contentType = ContentType.json;
  final origin = request.headers.value('origin');
  final parsedOrigin = origin == null ? null : Uri.tryParse(origin);
  if (origin != null) response.headers.set('Vary', 'Origin');
  final localDevelopmentOrigin =
      api.development &&
      parsedOrigin?.scheme == 'http' &&
      (parsedOrigin?.host == 'localhost' || parsedOrigin?.host == '127.0.0.1');
  final configuredOrigin =
      origin != null &&
      parsedOrigin?.scheme == 'https' &&
      parsedOrigin?.userInfo.isEmpty == true &&
      parsedOrigin?.path.isEmpty == true &&
      parsedOrigin?.query.isEmpty == true &&
      parsedOrigin?.fragment.isEmpty == true &&
      api.allowedOrigins.contains(origin);
  if (localDevelopmentOrigin || configuredOrigin) {
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, origin!);
    response.headers.set(
      HttpHeaders.accessControlAllowMethodsHeader,
      'GET, OPTIONS',
    );
  }
  try {
    if (request.method == 'OPTIONS' &&
        (localDevelopmentOrigin || configuredOrigin)) {
      response.statusCode = HttpStatus.noContent;
      return;
    }
    if (request.method != 'GET') {
      throw const ApiFailure(405, 'Method not allowed.');
    }
    Object body;
    if (request.uri.path == '/health') {
      body = {
        'status': 'ok',
        'configured': api.configured,
        'environment': api.environment,
      };
    } else if (request.uri.path == '/debug/qf' &&
        api.development &&
        request.connectionInfo?.remoteAddress.isLoopback == true) {
      body = await api.debugReport();
    } else if (request.uri.path == '/api/quran/reciters') {
      body = {'reciters': await api.reciters()};
    } else if (path.length == 4 &&
        path[0] == 'api' &&
        path[1] == 'quran' &&
        path[2] == 'audio') {
      final key = path[3];
      final id = int.tryParse(
        request.uri.queryParameters['recitationId'] ?? '',
      );
      if (!RegExp(r'^[1-9]\d{0,2}:[1-9]\d{0,2}$').hasMatch(key) ||
          id == null ||
          id <= 0) {
        throw const ApiFailure(
          400,
          'Valid verseKey and recitationId are required.',
        );
      }
      body = await api.verseAudio(key, id);
    } else {
      throw const ApiFailure(404, 'Endpoint not found.');
    }
    response.write(jsonEncode(body));
  } on ApiFailure catch (error) {
    response.statusCode = error.status;
    response.write(
      jsonEncode(
        api.development &&
                request.connectionInfo?.remoteAddress.isLoopback == true &&
                error.upstreamStatus != null
            ? {
                'error': 'upstream_error',
                'upstreamStatus': error.upstreamStatus,
                'type': error.type,
                'message': error.message,
              }
            : {'error': error.message},
      ),
    );
  } catch (_) {
    response.statusCode = 502;
    response.write(
      jsonEncode({'error': 'Quran audio service is currently unavailable.'}),
    );
  } finally {
    await response.close();
  }
}
