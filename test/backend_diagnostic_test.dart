import 'dart:convert';
import 'dart:io';

import 'package:quran_audio_backend/quran_audio_api.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> getJson(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

void main() {
  test('backend diagnostics and deployment CORS', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var tokenCalls = 0;
    var chaptersCalls = 0;
    var recitersCalls = 0;
    var invalidScope = false;
    var chaptersDenied = false;
    upstream.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/oauth2/token') {
        tokenCalls++;
        assert(
          request.headers.value(HttpHeaders.authorizationHeader) ==
              'Basic ${base64Encode(utf8.encode('test-id:test-secret'))}',
        );
        assert(
          await utf8.decoder.bind(request).join() ==
              'grant_type=client_credentials&scope=content',
        );
        if (invalidScope) {
          request.response.statusCode = 400;
          request.response.write(
            jsonEncode({
              'error': 'invalid_scope',
              'error_description': 'Scope content is not approved',
            }),
          );
        } else {
          request.response.write(
            jsonEncode({'access_token': 'test-token', 'expires_in': 3600}),
          );
        }
      } else {
        assert(request.headers.value('x-auth-token') == 'test-token');
        assert(request.headers.value('x-client-id') == 'test-id');
        if (request.uri.path == '/content/api/v4/chapters') {
          chaptersCalls++;
          if (chaptersDenied) {
            request.response.statusCode = 403;
            request.response.write(
              '{"type":"insufficient_scope","message":"Missing content.quran.read"}',
            );
          } else {
            request.response.write('{"chapters":[]}');
          }
        } else if (request.uri.path ==
            '/content/api/v4/resources/recitations') {
          recitersCalls++;
          request.response.write(
            '{"recitations":[{"id":7,"reciter_name":"Test"}]}',
          );
        } else {
          request.response.statusCode = 404;
          request.response.write('{}');
        }
      }
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${upstream.port}');
    var api = QuranFoundationAudioApi(
      clientId: 'test-id',
      clientSecret: 'test-secret',
      authBase: base,
      apiBase: base,
      development: true,
    );
    backend.listen((request) => handleAudioRequest(request, api));
    final local = Uri.parse('http://127.0.0.1:${backend.port}');
    try {
      final browser = HttpClient();
      final localRequest = await browser.getUrl(local.resolve('/health'));
      localRequest.headers.set('Origin', 'http://localhost:62656');
      final localResponse = await localRequest.close();
      assert(
        localResponse.headers.value('access-control-allow-origin') ==
            'http://localhost:62656',
      );
      await localResponse.drain<void>();
      final remoteRequest = await browser.getUrl(local.resolve('/health'));
      remoteRequest.headers.set('Origin', 'https://example.com');
      final remoteResponse = await remoteRequest.close();
      assert(
        remoteResponse.headers.value('access-control-allow-origin') == null,
      );
      await remoteResponse.drain<void>();
      final report = await getJson(local.resolve('/debug/qf'));
      assert((report['tokenRequest'] as Map)['success'] == true);
      assert((report['chaptersRequest'] as Map)['success'] == true);
      assert((report['recitersRequest'] as Map)['success'] == true);
      assert(tokenCalls == 1 && chaptersCalls == 1 && recitersCalls == 1);
      assert(
        (await getJson(local.resolve('/api/quran/reciters')))['reciters'] !=
            null,
      );

      api.close();
      invalidScope = true;
      api = QuranFoundationAudioApi(
        clientId: 'test-id',
        clientSecret: 'test-secret',
        authBase: base,
        apiBase: base,
        development: true,
      );
      final failed = await getJson(local.resolve('/debug/qf'));
      assert((failed['tokenRequest'] as Map)['status'] == 400);
      assert((failed['chaptersRequest'] as Map)['status'] == null);
      assert((failed['recitersRequest'] as Map)['status'] == null);
      assert(chaptersCalls == 1 && recitersCalls == 2);
      final error = await getJson(local.resolve('/api/quran/reciters'));
      assert(error['error'] == 'upstream_error');
      assert(
        error['upstreamStatus'] == 400 && error['type'] == 'invalid_scope',
      );
      assert(!jsonEncode(error).contains('test-secret'));
      assert(!jsonEncode(error).contains('test-token'));

      api.close();
      invalidScope = false;
      chaptersDenied = true;
      api = QuranFoundationAudioApi(
        clientId: 'test-id',
        clientSecret: 'test-secret',
        authBase: base,
        apiBase: base,
        development: true,
      );
      final chapterFailure = await getJson(local.resolve('/debug/qf'));
      assert((chapterFailure['tokenRequest'] as Map)['status'] == 200);
      assert((chapterFailure['chaptersRequest'] as Map)['status'] == 403);
      assert((chapterFailure['recitersRequest'] as Map)['status'] == null);
      assert(recitersCalls == 2);
      api.close();
      api = QuranFoundationAudioApi(
        clientId: 'test-id',
        clientSecret: 'test-secret',
        authBase: base,
        apiBase: base,
        allowedOrigins: {'https://app.example.test'},
      );
      final allowedRequest = await browser.getUrl(local.resolve('/health'));
      allowedRequest.headers.set('Origin', 'https://app.example.test');
      final allowedResponse = await allowedRequest.close();
      assert(
        allowedResponse.headers.value('access-control-allow-origin') ==
            'https://app.example.test',
      );
      await allowedResponse.drain<void>();
      final preflight = await browser.openUrl(
        'OPTIONS',
        local.resolve('/api/quran/reciters'),
      );
      preflight.headers.set('Origin', 'https://app.example.test');
      final preflightResponse = await preflight.close();
      assert(preflightResponse.statusCode == 204);
      await preflightResponse.drain<void>();
      final productionDebug = await browser.getUrl(local.resolve('/debug/qf'));
      final productionDebugResponse = await productionDebug.close();
      assert(productionDebugResponse.statusCode == 404);
      await productionDebugResponse.drain<void>();
      final productionLocal = await browser.getUrl(local.resolve('/health'));
      productionLocal.headers.set('Origin', 'http://localhost:62656');
      final productionLocalResponse = await productionLocal.close();
      assert(
        productionLocalResponse.headers.value('access-control-allow-origin') ==
            null,
      );
      await productionLocalResponse.drain<void>();
      browser.close();
      stdout.writeln('Backend diagnostics passed.');
    } finally {
      api.close();
      await backend.close(force: true);
      await upstream.close(force: true);
    }
  });
}
