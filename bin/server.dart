import 'dart:io';

import 'package:quran_audio_backend/quran_audio_api.dart';

Future<void> main() async {
  const productionBuild = bool.fromEnvironment('QF_PRODUCTION_BUILD');
  final values = <String, String>{...Platform.environment};
  final envFile = File.fromUri(Platform.script.resolve('../.env'));
  if (!productionBuild && await envFile.exists()) {
    for (final line in await envFile.readAsLines()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final split = trimmed.indexOf('=');
      if (split <= 0) continue;
      final value = trimmed.substring(split + 1).trim();
      values.putIfAbsent(
        trimmed.substring(0, split).trim(),
        () => value.length >= 2 && value.startsWith('"') && value.endsWith('"')
            ? value.substring(1, value.length - 1)
            : value,
      );
    }
  }
  final api = QuranFoundationAudioApi(
    clientId: values['QF_CLIENT_ID'] ?? '',
    clientSecret: values['QF_CLIENT_SECRET'] ?? '',
    environment: values['QF_ENV'] ?? 'prelive',
    development:
        !productionBuild && (values['QF_ENV'] ?? 'prelive') == 'prelive',
    scope: values['QF_SCOPE'] ?? 'content',
    allowedOrigins: (values['QF_ALLOWED_ORIGINS'] ?? '')
        .split(',')
        .map((origin) => origin.trim())
        .where((origin) => origin.isNotEmpty)
        .toSet(),
  );
  final port =
      int.tryParse(
        Platform.environment['PORT'] ??
            values['PORT'] ??
            values['QF_PORT'] ??
            '',
      ) ??
      8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln(
    'Quran audio backend listening on port ${server.port} (${api.environment}; configured=${api.configured})',
  );
  await for (final request in server) {
    handleAudioRequest(request, api);
  }
}
