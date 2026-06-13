import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'jellyfin_api.dart' as jellyfin_api;

class LocalAudioProxy {
  HttpServer? _server;
  HttpClient? _cachedClient;
  SecurityContext? _cachedSecCtx;
  final _logger = Logger("LocalAudioProxy");
  int _requestCounter = 0;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  /// Rewrites an arbitrary URL through this proxy so the request uses mTLS.
  /// Returns null if the proxy isn't running.
  String? urlForProxy(String url) {
    if (!isRunning) return null;
    return "http://127.0.0.1:$port/proxy?url=${Uri.encodeFull(url)}";
  }

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _logger.info("Started on port $port");
    _server!.listen(_handleRequest, onError: (Object e) {
      _logger.severe("Server error: $e");
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _cachedClient?.close();
    _cachedClient = null;
    _cachedSecCtx = null;
  }

  HttpClient _getClient() {
    if (_cachedClient != null) return _cachedClient!;
    _cachedSecCtx = jellyfin_api.createClientCertSecurityContext();
    _cachedClient = HttpClient(context: _cachedSecCtx);
    _cachedClient!.connectionTimeout = const Duration(seconds: 10);
    _logger.info("Created cached HttpClient");
    return _cachedClient!;
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

    try {
      final client = _getClient();
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

      final pipeDone = proxyResponse.pipe(request.response);
      final clientGone = request.response.done;
      await Future.any([pipeDone, clientGone]);
      _logger.fine("[$id] Done (${proxyResponse.statusCode})");
    } catch (e) {
      _logger.warning("[$id] Failed: $e");
      try {
        request.response.statusCode = 502;
        request.response.write('Proxy error: $e');
        await request.response.close();
      } catch (_) {}
    }
  }
}
