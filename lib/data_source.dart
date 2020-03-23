import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:daruska/sources.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

import 'data.dart';
import 'extensions.dart';
import 'ruuvi_parser.dart';

class DataSource implements SensorEventSource {

  final _log = Logger('src');

  static const _ignoreDuplicates = true;

  final _eventController = StreamController<SensorEvent>.broadcast();
  final _latestBySensorId = HashMap<int, SensorData>();
  final _inactivityController = StreamController<Object>.broadcast();

  var _nextId = 1;
  final _realtimeSubscribers = <int>{};
  bool _disposed = false;
  MonitoringConfiguration _cfg;
  _MonitoringProcess _process;
  StreamSubscription<Object> _inactivitySubscription;
  Timer _intervaller;
  Timer _timeouter;

  DataSource();

  void dispose() {
    _disposed = true;

    _process?.dispose();
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

  @override
  Stream<SensorEvent> get eventStream => _eventController.stream;

  @override
  int subscribeRealtimeUpdates() {
    final id = _nextId++;
    _realtimeSubscribers.add(id);

    if (_realtimeSubscribers.length == 1) {
      _log.fine('start monitoring continuously');
      _restartMonitoring();
    }

    return id;
  }

  @override
  void unsubscribeRealtimeUpdates(int id) {

    if (_realtimeSubscribers.remove(id) && _realtimeSubscribers.isEmpty) {
      _log.fine('no more rt subscribers');
      _stopMonitoring();
    }
  }

  bool get _monitorContinuously => _cfg.monitorContinuously || _realtimeSubscribers.isNotEmpty;

  Future<void> setConfiguration(MonitoringConfiguration cfg) async {
    _cfg = cfg;
    return _restartMonitoring();
  }

  Future<void> _startMonitoring() async {
    if (_isMonitoring || _disposed) return;

    _intervaller?.cancel();
    _intervaller = null;

    _process = _MonitoringProcess();
    await _process.start(_cfg, _onProcessEnded, _handleLine);
    _log.finer('started monitoring (pid=${_process.pid}, interval=${_cfg.interval.inSeconds}s, timeout=${_cfg.timeout.inSeconds}s, devices=${_cfg.sensorIds.map((sid) => sid.toMacString()).join(', ')})');

    _latestBySensorId.clear();

    if (_cfg.timeout != null && !_monitorContinuously) {
      _timeouter = Timer(_cfg.timeout, () {
        _log.finer('timed out');
        _stopMonitoring();
      });
    }

    if (_cfg.inactivityTimeout != null && _monitorContinuously) {
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

  void _onProcessEnded() {

    if (_monitorContinuously) {
      _restartMonitoring();
    } else {
      _stopMonitoring();
    }
  }

  void _stopMonitoring() {
    if (!_isMonitoring) return;

    _log.finer('stop monitoring');

    _timeouter?.cancel();
    _timeouter = null;

    _inactivitySubscription?.cancel();
    _inactivitySubscription = null;

    _process?.dispose();
    _process = null;

    if (!_monitorContinuously && !_disposed) {
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

    if (match == null) {
     _log.finer('ignore nonmatching line: $line');
      return;
    }

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

    if (!_monitorContinuously && _cfg.all && _latestBySensorId.length == _cfg.sensorIds.length) {
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
  final bool useActive;

  MonitoringConfiguration({
    @required this.command,
    this.interval = Duration.zero,
    this.all = false,
    this.timeout = const Duration(seconds: 10),
    this.sensorIds = const {},
    this.inactivityTimeout = const Duration(seconds: 30),
    this.useActive = false
  }):
      assert(command != null && command.isNotEmpty),
      assert(interval != null),
      assert(timeout != null),
      assert(inactivityTimeout != null),
      assert(all != null),
      assert(sensorIds != null),
      assert(useActive != null),
      assert(all == false || sensorIds.isNotEmpty);

  bool get monitorContinuously => interval == null || interval.inMilliseconds == 0;

  MonitoringConfiguration copyWith({
    List<String> command,
    Duration interval,
    bool all,
    Duration timeout,
    Set<int> sensorIds,
    Duration inactivityTimeout,
    bool useActive})
  {
    return MonitoringConfiguration(
      command: command ?? this.command,
      interval: interval ?? this.interval,
      all: all ?? this.all,
      timeout: timeout ?? this.timeout,
      sensorIds: sensorIds ?? this.sensorIds,
      inactivityTimeout: inactivityTimeout ?? this.inactivityTimeout,
      useActive: useActive ?? this.useActive
    );
  }
}

extension on Stream<List<int>> {
  Stream<String> mapCharCodesToLines() {
    return map((chars) => String.fromCharCodes(chars))
        .map((str) => str.split('\n'))
        .expand((line) => line);
  }
}

class _MonitoringProcess {

  final _log = Logger('proc');

  Process _process;
  int _pid;
  StreamSubscription<String> _stdOutSubscription;
  StreamSubscription<String> _stdErrSubscription;

  int get pid => _pid;

  void start(MonitoringConfiguration cfg, void Function() onProcessEnded, void Function(String line) onLine) async {
    _process = await Process.start(cfg.command.first, cfg.command.sublist(1));
    _pid = _process.pid;

    _stdErrSubscription = _process.stderr
        .mapCharCodesToLines()
        .listen(
          (line) {
            _log.warning('[$_pid] stderr: $line');
          },
          onError: (err) {
            _log.severe('[$_pid] stderr error', err);
            onProcessEnded();
          },
          onDone: () {
            _log.finer('[$_pid] stderr done');
            onProcessEnded();
          }
        );

    _stdOutSubscription = _process.stdout
        .mapCharCodesToLines()
        .listen(
          onLine,
          onError: (err) {
            _log.severe('[$_pid] stdout error', err);
            onProcessEnded();
          },
          onDone: () {
            _log.finer('[$_pid] stdout done');
            onProcessEnded();
          }
        );
  }

  Future<void> dispose({int retriesLeft = 3}) async {
    if (_process == null) return;

    final delivered = _process?.kill(ProcessSignal.sigint);
    if (!delivered) _log.fine('[$_pid] interrupt signal was not delivered');

    await _stdErrSubscription?.cancel();
    _stdErrSubscription = null;

    await _stdOutSubscription?.cancel();
    _stdOutSubscription = null;

    final exitCode = await _process.exitCode.timeout(Duration(seconds: 5), onTimeout: () => -999);

    if (exitCode == -999 && retriesLeft > 0) {
      // Sometimes the process doesn't exit after the first kill() and it remains alive until
      // killed again. Prolly the problem is in blepp_scan and how it checks interruptions, but
      // couldn't figure it out so retry a few times (2nd try often seems to be enough).
      _log.fine('[$_pid] process did not exit - retriesLeft=$retriesLeft');
      return dispose(retriesLeft: retriesLeft - 1);

    } else {
      if (exitCode != 0) _log.warning('[$_pid] exitCode=$exitCode');
      _process = null;
    }
  }
}
