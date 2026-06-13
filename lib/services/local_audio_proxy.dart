import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'jellyfin_api.dart' as jellyfin_api;

class LocalAudioProxy {
  HttpServer? _server;
  final _logger = Logger("LocalAudioProxy");
  int _requestCounter = 0;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _logger.info("Started on port $port");
    _server!.listen(_handleRequest, onError: (e) {
      _logger.severe("Server error: $e");
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handleRequest(HttpRequest request) async {
    final id = ++_requestCounter;
    final originalUrl = request.uri.queryParameters['url'];
    if (originalUrl == null) {
      request.response.statusCode = 400;
      request.response.write('Missing url parameter');
      await request.response.close();
      return;
    }

    _logger.fine("[$id] Proxying: $originalUrl");

    HttpClient? client;
    try {
      final secCtx = jellyfin_api.createClientCertSecurityContext();
      client = HttpClient(context: secCtx);
      client.connectionTimeout = const Duration(seconds: 10);

      final proxyRequest = await client.getUrl(Uri.parse(originalUrl));

      request.headers.forEach((name, values) {
        final lowerName = name.toLowerCase();
        if (lowerName != 'host' && lowerName != 'connection' && lowerName != 'transfer-encoding') {
          proxyRequest.headers.set(name, values);
        }
      });

      final proxyResponse = await proxyRequest.close();

      request.response.statusCode = proxyResponse.statusCode;
      proxyResponse.headers.forEach((name, values) {
        final lowerName = name.toLowerCase();
        if (lowerName != 'transfer-encoding' && lowerName != 'connection' && lowerName != 'content-length') {
          request.response.headers.set(name, values);
        }
      });

      await proxyResponse.pipe(request.response);
      _logger.fine("[$id] Done (${proxyResponse.statusCode})");
    } catch (e) {
      _logger.warning("[$id] Failed: $e");
      try {
        request.response.statusCode = 502;
        request.response.write('Proxy error: $e');
        await request.response.close();
      } catch (_) {}
    } finally {
      client?.close();
    }
  }
}
