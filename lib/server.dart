import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daruska/data.dart';
import 'package:daruska/sources.dart';
import 'package:daruska/web_socket_handler.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

class Server {

  final _log = Logger('server');
  final int _port;
  final dynamic _address;
  final SensorEventSource src;
  final LatestEventsSource latest;
  final SensorInfoSource infos;
  final _wsHandlers = <WebSocketHandler>{};
  HttpServer _server;
  StreamSubscription<HttpRequest> _reqSubscription;
  final _reqMatchers = <_RequestMatcher>[];

  Server(this.src, this.latest, this.infos, this._port, {String address}):
        _address = address == null ? InternetAddress.loopbackIPv4 : InternetAddress(address)
  {
    _register(method: 'GET', pathPattern: '/api/events/latest', handler: _getLatestEvents);
    _register(method: 'GET', pathPattern: '/api/sensor/all', handler: _getAllSensorInfos);
    _register(method: 'GET', pathPattern: '/ws/monitor', handler: _handleStartMonitoring);
    _register(method: 'GET', pathPattern: RegExp(r'^/api/events/([a-fA-F0-9]{1,12})/latest'), handler: _getLatestForSensor);
    _register(method: 'PUT', pathPattern: RegExp(r'^/api/sensor/([a-fA-F0-9]{1,12})/info'), handler: _saveSensor);
  }

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

  void _register({@required String method, @required Pattern pathPattern, @required _RequestHandler handler}) {
    _reqMatchers.add(_RequestMatcher(method, pathPattern, handler));
  }

  void _handleRequest(HttpRequest req) async {
    _log.finer('uri=${req.uri} method=${req.method} path=${req.uri.path}');

    try {

      for (final matcher in _reqMatchers) {
        if (req.method != matcher.method) continue;

        final pathMatch = matcher.pathPattern.matchAsPrefix(req.uri.path);
        if (pathMatch == null) continue;

        await matcher.handler(req, pathMatch);
        return;
      }

      throw RequestException(HttpStatus.notFound, 'not_found');

    } catch (e) {
      _log.severe('error handling request ${req.method} ${req.uri.path}', e);
      await _handleError(req, e);
    }
  }

  Future<void> _getLatestEvents(HttpRequest req, Match pathMatch) async {
    final json = latest.latestEvents().map((e) => e.toJson()).toList(growable: false);
    await req.response.sendJson(json);
  }

  Future<void> _getAllSensorInfos(HttpRequest req, Match pathMatch) async {
    final json = infos.getAllSensorInfos().map((info) => info.toJson()).toList(growable: false);
    await req.response.sendJson(json);
  }

  Future<void> _getLatestForSensor(HttpRequest req, Match pathMatch) async {
    final sensorId = _readSensorId(pathMatch);
    final info = _getSensorInfo(sensorId);

    final event = latest.latestForSensor(sensorId);
    final json = event.toJson();
    json['name'] = info.name;

    await req.response.sendJson(json);
  }

  Future<void> _saveSensor(HttpRequest req, Match pathMatch) async {

    if (req.headers.contentType != ContentType.json) {
      throw RequestException(HttpStatus.unsupportedMediaType, 'invalid_content_type');
    }

    final sensorId = _readSensorId(pathMatch);
    final old = _getSensorInfo(sensorId); // Validate that sensor exists - new ones cannot be created.

    final content = await utf8.decodeStream(req);
    final decoded = jsonDecode(content);

    if (!(decoded is Map<String, dynamic>)) {
      throw RequestException(HttpStatus.badRequest, 'invalid_body');
    }

    final json = decoded as Map<String, dynamic>;
    final name = json['name'];
    final active = json['active'];
    // At least one of the fields must be defined. Use old values for undefined ones.

    if (active == null && name == null) {
      throw RequestException(HttpStatus.badRequest, 'invalid_info');
    }

    if (name != null && !(name is String)) {
      throw RequestException(HttpStatus.badRequest, 'invalid_name');
    }

    if ((name?.length ?? 0) > 32) {
      throw RequestException(HttpStatus.badRequest, 'invalid_name');
    }

    if (active != null && !(active is bool)) {
      throw RequestException(HttpStatus.badRequest, 'invalid_active');
    }

    infos.saveSensorInfo(SensorInfo(sensorId, name ?? old.name, active ?? old.active));
  }

  Future<void> _handleStartMonitoring(HttpRequest req, Match pathMatch) async {
    final params = MonitoringParameters.fromRequest(req);
    final ws = await WebSocketTransformer.upgrade(req);
    final wsh = WebSocketHandler(ws, src, params);
    await wsh.start();
    _wsHandlers.add(wsh);
  }

  int _readSensorId(Match pathMatch) {
    final idStr = pathMatch.group(1);
    final sensorId = int.tryParse(idStr, radix: 16);

    if (sensorId == null) {
      _log.severe('not a valid sensorId: $sensorId');
      throw RequestException(HttpStatus.badRequest, 'invalid_sensorId');
    }

    return sensorId;
  }

  SensorInfo _getSensorInfo(int sensorId) {
    final info = infos.getSensorInfo(sensorId);

    if (info == null) {
      throw RequestException(HttpStatus.notFound, 'sensor_not_found');
    }

    return info;
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

  Future<void> sendJson(dynamic json, {int status = HttpStatus.ok}) async {
    statusCode = status;
    writeJson(json);
    return close();
  }
}

class RequestException extends HttpException {

  final int status;

  RequestException(this.status, String message): super(message);
}

typedef _RequestHandler = Future<void> Function(HttpRequest req, Match pathMatch);

class _RequestMatcher {
  final String method;
  final Pattern pathPattern;
  final _RequestHandler handler;

  _RequestMatcher(this.method, this.pathPattern, this.handler);
}
