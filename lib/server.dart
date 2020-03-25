import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daruska/data.dart';
import 'package:daruska/sources.dart';
import 'package:daruska/web_socket_handler.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'extensions.dart';

final _log = Logger('server');

class Server {

  final int _port;
  final dynamic _address;
  final SensorEventSource src;
  final LatestEventsSource latest;
  final SensorInfoSource infos;
  final _wsHandlers = <WebSocketHandler>{};
  HttpServer _server;
  StreamSubscription<HttpRequest> _reqSubscription;
  final _reqMatchers = <_RequestMatcher>[];
  final _validNamePattern = RegExp(r'^[\p{Letter}0-9-_. ]{0,32}$', unicode: true);

  Server(this.src, this.latest, this.infos, this._port, {String address}):
        _address = address == null ? InternetAddress.loopbackIPv4 : InternetAddress(address)
  {
    _register(method: 'GET', pathPattern: '/api/events/latest', handler: _getLatestEvents);
    _register(method: 'GET', pathPattern: '/api/events', handler: _queryEvents);
    _register(method: 'GET', pathPattern: '/api/sensor/all', handler: _getAllSensorInfos);
    _register(method: 'GET', pathPattern: '/api/datapoints', handler: _getDataPoints);
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

    if (pathPattern is String) {
      pathPattern = RegExp('^$pathPattern\$');
    }

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
    final json = latest.latestEvents()
        .map(_toJsonWithSensorName)
        .toList(growable: false);
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

    if (event == null) {
      throw RequestException(HttpStatus.notFound, 'event_not_found');
    }

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

    if (name != null && (!(name is String) || _validNamePattern.hasMatch(name))) {
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
    final sensorId = _parseSensorId(idStr);

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

  Future<void> _queryEvents(HttpRequest req, Match pathMatch) async {
    final events = _listEvents(req);
    await req.response.sendJson(events.map(_toJsonWithSensorName).toList(growable: false));
  }

  List<SensorEvent> _listEvents(HttpRequest req) {
    final qp = req.uri.queryParameters;

    final ids = qp['sensors']
        ?.split(',')
        ?.map(_parseSensorId)
        ?.where((sid) => sid != null)
        ?.toList(growable: false);

    return infos.getSensorEvents(
      sensorIds: ids,
      accuracy: qp['accuracy']?.toAccuracy() ?? Accuracy.min,
      frequency: qp['frequency']?.toFrequency() ?? Frequency.min,
      aggregate: qp['aggregate']?.toAggregate() ?? Aggregate.avg,
      from: _parseTimestamp(qp['from']),
      to: _parseTimestamp(qp['to']),
      orderBy: qp['sort']?.toOrderBy(),
      descending: qp['order'] == 'desc',
      offset: _parseInt(qp['offset'], min: 0),
      limit: _parseInt(qp['limit'], min: 1, max: 1000),
    );
  }

  /// Responds with a list with an object per sensor. Each object lists the requested
  /// fields in separate arrays (that only contain the field specific values).
  Future<void> _getDataPoints(HttpRequest req, Match pathMatch) async {
    final events = _listEvents(req);

    final includeFields = req.uri.queryParameters['fields']
        ?.split(',')
        ?.map((fstr) => fstr.toSensorField())
        ?.where((sf) => sf != null)
        ?.toSet();
    _log.finest('include fields: $includeFields');

    final dpcs = _asDataPointCollections(events, infos, includeFields);
    await req.response.sendJson(dpcs.map((dpc) => dpc.toJson()).toList());
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

  static int _parseSensorId(String value) {
    if (value == null) return null;
    return int.tryParse(value, radix: 16);
  }

  static int _parseInt(String value, {int min, int max}) {
    if (value == null) return null;
    final res = int.tryParse(value);
    if (res == null) throw RequestException(HttpStatus.badRequest, 'invalid_integer');
    if (min != null && res < min) throw RequestException(HttpStatus.badRequest, 'out_of_bounds');
    if (max != null && res > max) throw RequestException(HttpStatus.badRequest, 'out_of_bounds');
    return res;
  }

  /// Timestamp should be in ISO8601 format. See DateTime.parse() for more details.
  static DateTime _parseTimestamp(String value) {
    if (value == null) return null;

    try {
      return DateTime.parse(value);

    } on FormatException {
      _log.severe('invalid timestamp string "$value"');
      throw RequestException(HttpStatus.badRequest, 'invalid_timestamp');
    }
  }

  Map<String, dynamic> _toJsonWithSensorName(SensorEvent event) {
    final json = event.toJson();
    json['sensorName'] = infos.getSensorInfo(event.sensorId)?.name;
    return json;
  }
}

extension on HttpResponse {

  void writeJson(dynamic content) {
    headers.contentType = ContentType.json;

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

extension _XAccuracy on Accuracy {
  static final Map<String, Accuracy> _valueByName = Accuracy.values.toNameMap();
}

extension _XFrequency on Frequency {
  static final Map<String, Frequency> _valueByName = Frequency.values.toNameMap();
}

extension _XAggregate on Aggregate {
  static final Map<String, Aggregate> _valueByName = Aggregate.values.toNameMap();
}

extension _XOrderBy on OrderBy {
  static final Map<String, OrderBy> _valueByName = OrderBy.values.toNameMap();
}

extension _XString on String {
  Accuracy toAccuracy() => _XAccuracy._valueByName[this];
  Frequency toFrequency() => _XFrequency._valueByName[this];
  Aggregate toAggregate() => _XAggregate._valueByName[this];
  OrderBy toOrderBy() => _XOrderBy._valueByName[this];
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

/// Value arrays can contain nulls.
class _DataPointCollection {

  final int sensorId;
  final String sensorName;
  final List<double> temperature = [];
  final List<double> humidity = [];
  final List<double> pressure = [];
  final List<double> voltage = [];
  final List<DateTime> timestamps = [];

  _DataPointCollection(this.sensorId, this.sensorName);

  void add(int includeFieldsMask, SensorEvent event) {
    timestamps.add(event.timestamp);

    if (includeFieldsMask?.isIncluded(SensorField.temperature) ?? true) {
      temperature.add(event.data.temperature);
    }

    if (includeFieldsMask?.isIncluded(SensorField.humidity) ?? true) {
      humidity.add(event.data.humidity);
    }

    if (includeFieldsMask?.isIncluded(SensorField.pressure) ?? true) {
      pressure.add(event.data.pressure);
    }

    if (includeFieldsMask?.isIncluded(SensorField.voltage) ?? true) {
      voltage.add(event.data.voltage);
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'sensorId': sensorId.toMacString(separated: false),
      'sensorName': sensorName,
      'timestamps': timestamps.map((ts) => ts.secondsSinceEpoch).toList(growable: false),
      'temperature': temperature,
      'humidity': humidity,
      'pressure': pressure,
      'voltage': voltage,
    };
  }
}

List<_DataPointCollection> _asDataPointCollections(List<SensorEvent> events, SensorInfoSource infos, Set<SensorField> includeFields) {
  final collections = <int, _DataPointCollection>{};
  final includeMask = includeFields?._asIncludeMask();

  for (final event in events) {
    (collections[event.sensorId] ??= _DataPointCollection(event.sensorId, infos.getSensorInfo(event.sensorId)?.name)).add(includeMask, event);
  }

  return collections.values.toList(growable: false);
}

extension _XSensorFieldSet on Set<SensorField> {
  int _asIncludeMask() => isEmpty ? 0 : map((f) => 1 << f.index).reduce((a, b) => a | b); // + isIncluded -> :)
}

extension _XInt on int {
  bool isIncluded(SensorField field) => this & (1 << field.index) > 0;
}
