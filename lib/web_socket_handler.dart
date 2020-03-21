import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daruska/data.dart';
import 'package:daruska/server.dart';
import 'package:daruska/sources.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'extensions.dart';

class WebSocketHandler {

  final _log = Logger('ws');

  final WebSocket _ws;
  final SensorEventSource _src;
  final MonitoringParameters _parameters;
  StreamSubscription<dynamic> _wsSubscription;
  StreamSubscription<SensorEvent> _eventSubscription;
  int _sid;

  WebSocketHandler(this._ws, this._src, this._parameters);

  Future<void> start() async {
    _sid = _src.subscribeRealtimeUpdates();
    _wsSubscription = _ws.listen(null, cancelOnError: true);
    _ws.pingInterval = Duration(seconds: 30);
    _log.fine('opened ws $_sid');

    _wsSubscription.onDone(() async {
      _log.fine('done');
      await dispose();
    });

    _wsSubscription.onError((err) async {
      _log.severe('error', err);
      await dispose();
    });

    final lastDatas = <int, SensorData>{};

    var stream = _src.eventStream
      .where((event) => _parameters.isInteresting(event, lastDatas[event.sensorId]));

    if (_parameters.sample != null) {
      stream = stream.sampleTime(_parameters.sample);
    }

    _eventSubscription = stream.listen((event) {
      lastDatas[event.sensorId] = event.data;
      _ws.add(jsonEncode(SensorEvent(event.sensorId, event.timestamp, event.data.withFields(_parameters.fields)).toJson()));
    });
  }

  Future<void> dispose() async {
    _src.unsubscribeRealtimeUpdates(_sid);

    if (_ws.closeCode == null) {
      await _ws.close();
    }

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    await _wsSubscription?.cancel();
    _wsSubscription = null;
  }
}

class MonitoringParameters {
  
  final Duration sample;

  /// If null, then monitor changes in all sensors.
  final int sensorId;

  /// Defines the fields to inspect. If none of the field values have changed since the last
  /// sent message (via websocket), then ignore the event. If empty, then inspect all fields.
  final Set<SensorField> fields;

  MonitoringParameters({this.sensorId, this.fields = const {}, this.sample}):
    assert(fields != null);

  static MonitoringParameters fromRequest(HttpRequest req) {

    final fields = req.uri.queryParameters['fields']
        ?.split(',')
        ?.map((fstr) {
          final field = fstr.toSensorField();

          if (field == null) {
            throw RequestException(HttpStatus.badRequest, 'invalid_field');
          }

          return field;
        })
        ?.toSet() ?? [];

    return MonitoringParameters(
      sensorId: req.uri.queryParameters['sensorId']?.parseSensorId(),
      fields: fields,
      sample: req.uri.queryParameters['sample']?.parseSeconds()
    );
  }

  bool isInteresting(SensorEvent event, SensorData previous) {

    if (sensorId != null && event.sensorId != sensorId) {
      return false;
    }

    return previous == null || !event.data.isSame(previous, fields);
  }
}

extension on String {
  Duration parseSeconds() => Duration(seconds: int.parse(this));
}
