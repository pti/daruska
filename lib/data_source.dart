import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:convert/convert.dart';

import 'data.dart';
import 'ruuvi_parser.dart';

final _log = Logger('src');

class DataSource {

  static const _ignoreDuplicates = true;

  final _eventController = StreamController<SensorEvent>.broadcast();
  final _latestBySensorId = HashMap<int, SensorData>();
  final _inactivityController = StreamController<Object>.broadcast();

  bool _disposed = false;
  MonitoringConfiguration _cfg;
  Process _process;
  StreamSubscription<Object> _inactivitySubscription;
  Timer _intervaller;
  Timer _timeouter;

  DataSource();

  void dispose() {
    _disposed = true;
    _intervaller?.cancel();
    _intervaller = null;
    _timeouter?.cancel();
    _timeouter = null;

    _stopMonitoring();

    if (!_eventController.isClosed) {
      _eventController.close();
    }

    if (!_inactivityController.isClosed) {
      _inactivityController.close();
    }
  }

  Stream<SensorEvent> get stream => _eventController.stream;

  Future<void> setConfiguration(MonitoringConfiguration cfg) async {
    _cfg = cfg;
    return _restartMonitoring();
  }

  Future<void> _startMonitoring() async {
    if (_isMonitoring || _disposed) return;

    _intervaller?.cancel();
    _intervaller = null;

    _log.finer('start monitoring (interval=${_cfg.interval.inSeconds}s, timeout=${_cfg.timeout.inSeconds}s)');
    _process = await Process.start(_cfg.command.first, _cfg.command.sublist(1));

    _latestBySensorId.clear();

    if (_cfg.timeout != null) {
      _timeouter = Timer(_cfg.timeout, () {
        _log.finer('timed out');
        _stopMonitoring();
      });
    }

    _process.stdout
        .map((chars) => String.fromCharCodes(chars))
        .map((str) => str.split('\n'))
        .expand((line) => line)
        .listen(_handleLine);

    if (_cfg.inactivityTimeout != null && _cfg.monitorContinuously) {
      _inactivitySubscription = _inactivityController.stream
          .debounceTime(_cfg.inactivityTimeout)
          .listen((_) => _restartMonitoring());
      // In case no data is received after start, kick off the debouncer:
      _inactivityController.add(Object());
    }
  }

  bool get _isMonitoring => _process != null;

  Future<void> _restartMonitoring() async {
    _log.finer('restart');
    _stopMonitoring();
    return _startMonitoring();
  }

  void _stopMonitoring() {
    if (!_isMonitoring) return;

    _log.finer('stop monitoring');

    _timeouter?.cancel();
    _timeouter = null;

    _inactivitySubscription?.cancel();
    _inactivitySubscription = null;

    _process?.kill();
    _process = null;

    if (!_cfg.monitorContinuously && !_disposed) {
      _intervaller = Timer(_cfg.interval, () {
        _log.finer('interval elapsed');
        _startMonitoring();
      });
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;

    final linePattern = RegExp(r'^([A-F0-9:]{17}) ([0-9a-f]+)$');
    final match = linePattern.firstMatch(line);

    if (match == null) return;

    _inactivityController.add(Object());

    final sensorId = match.group(1)
        .split(':')
        .map((b) => int.parse(b, radix: 16))
        .reduce((a, b) => (a << 8) | b);

    if (_cfg.sensorIds.isNotEmpty && !_cfg.sensorIds.contains(sensorId)) {
      return;
    }

    final md = hex.decode(match.group(2));
    final data = parseRuuviData(md);
    final prev = _latestBySensorId[sensorId];

    if (!_ignoreDuplicates || prev != data) {
      _latestBySensorId[sensorId] = data;
      _eventController.add(SensorEvent(sensorId, DateTime.now(), data));
    }

    if (!_cfg.monitorContinuously && _cfg.all && _latestBySensorId.length == _cfg.sensorIds.length) {
      _stopMonitoring();
    }
  }
}

/// Specifies what sensors and how often a [DataSource] should monitor.
///
/// [interval] defines how often the source should listen for data from sensors.
/// If it is null, then the data source will monitor constantly. In that case
/// values of [all] and [timeout] will be ignored.
///
/// If [interval] is defined and [all] is false, then [timeout] specifies how
/// long to keep the monitoring enabled. If [all] is true, then keep monitoring
/// until at least one sensor data has been received from the sensors defined
/// by [sensorIds] or [timeout] has elapsed.
///
/// If [sensorIds] is null, then handle data from all sensors of a supported type.
///
/// If no data has been received from any of the sensors for [inactivityTimeout] then
/// monitoring will be restarted. [inactivityTimeout] is only applicable if [interval] is null.
class MonitoringConfiguration {

  final List<String> command;
  final Duration interval;
  final bool all;
  final Duration timeout;
  final Set<int> sensorIds;
  final Duration inactivityTimeout;

  MonitoringConfiguration({
    @required this.command,
    this.interval = Duration.zero,
    this.all = false,
    this.timeout = const Duration(seconds: 10),
    Set<String> sensorIds = const {},
    this.inactivityTimeout = const Duration(seconds: 30)
  }):
      sensorIds = sensorIds?.map(_parseSensorId)?.toSet() ?? {},
      assert(command != null && command.isNotEmpty),
      assert(interval != null),
      assert(timeout != null),
      assert(inactivityTimeout != null),
      assert(all != null),
      assert(all == false || sensorIds?.isNotEmpty == true);

  bool get monitorContinuously => interval == null || interval.inMilliseconds == 0;
}

int _parseSensorId(String id) {
  return id
      .split(':')
      .map((b) => int.parse(b, radix: 16))
      .reduce((a, b) => (a << 8) | b);
}
