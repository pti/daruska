import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daruska/event_source.dart';
import 'package:daruska/web_socket_handler.dart';
import 'package:logging/logging.dart';

class Server {

  final _log = Logger('server');
  final int _port;
  final dynamic _address;
  final SensorEventSource src;
  final _wsHandlers = <WebSocketHandler>{};
  HttpServer _server;
  StreamSubscription<HttpRequest> _reqSubscription;

  Server(this.src, {String address, int port}):
        _port = port ?? 21800,
        _address = address == null ? InternetAddress.loopbackIPv4 : InternetAddress(address);

  Future<void> start() async {
    _server = await HttpServer.bind(_address, _port,);
    _log.info('Listening on ${_server.address.address}:${_server.port} idleTO=${_server.idleTimeout.inSeconds}s');
    _reqSubscription = _server.listen(_handleRequest);
  }

  void dispose() async {
    await Future.wait(_wsHandlers.map((wsh) => wsh.dispose()));
    _wsHandlers.clear();

    await _reqSubscription?.cancel();
    _reqSubscription = null;

    await _server.close(force: true);
  }

  void _handleRequest(HttpRequest req) async {
    _log.finer('uri=${req.uri} method=${req.method} path=${req.uri.path}');

    try {

      if (req.method == 'GET' && req.uri.path == '/api/sensors') {
        await _getSensors(req);

      } else if (req.method == 'GET' && req.uri.path == '/ws/monitor') {
        await _handleStartMonitoring(req);

      } else {
        throw RequestException(HttpStatus.notFound, 'not_found');
      }

    } catch (e) {
      _log.severe('error handling request ${req.method} ${req.uri.path}', e);
      await _handleError(req, e);
    }
  }

  Future<void> _getSensors(HttpRequest req) async {
    return req.response.sendMessage(message: 'Hello world!');
  }

  Future<void> _handleError(HttpRequest req, dynamic err) async {
    var message = 'Oops';
    var status = HttpStatus.internalServerError;

    if (err is RequestException) {
      status = err.status;
      message = err.message;

    } else if (err is FormatException) {
      status = HttpStatus.badRequest;
      message = err.message;
    }

    await req.response.sendMessage(status: status, message: message);
  }

  Future<void> _handleStartMonitoring(HttpRequest req) async {
    final params = MonitoringParameters.fromRequest(req);
    final ws = await WebSocketTransformer.upgrade(req);
    final wsh = WebSocketHandler(ws, src, params);
    await wsh.start();
    _wsHandlers.add(wsh);
  }
}

extension on HttpResponse {

  void writeJson(dynamic content) {

    if (content is Map) {
      content.removeWhere((k, v) => v == null);
    }

    write(jsonEncode(content));
  }

  Future<void> sendMessage({int status = HttpStatus.ok, String message}) async {
    statusCode = status;
    writeJson({'message': message});
    return close();
  }
}

class RequestException extends HttpException {

  final int status;

  RequestException(this.status, String message): super(message);
}
