import 'dart:async';

import 'package:rxdart/rxdart.dart';

import 'data.dart';
import 'extensions.dart';

/// Keeps track of average SensorData values for each sensor for which an
/// event has been received.
class Collector {

  final _statsById = <int, _SensorStats>{};
  StreamSubscription<SensorEvent> _streamSubscription;

  Collector(Stream<SensorEvent> stream) {

    _streamSubscription = stream
        .doOnData((event) {
          final stats = _statsById[event.sensorId] ??= _SensorStats();
          stats.add(event.data);
        })
        .listen(null);
  }

  void dispose() {
    _streamSubscription?.cancel();
    _streamSubscription = null;
  }

  List<SensorEvent> collect() {
    return _statsById.entries
        .where((e) => e.value.hasMeasurements)
        .map((entry) {
          final event = SensorEvent(
            entry.key,
            DateTime.now(),
            entry.value.snapshot
          );
          entry.value.reset();
          return event;
        })
        .toList(growable: false);
  }
}

class _SensorStats {

  final _temperature = _StatsCollector();
  final _humidity = _StatsCollector();
  final _pressure = _StatsCollector();
  final _batteryVoltage = _StatsCollector();
  var _measurements = 0;

  void reset() {
    _measurements = 0;
    _temperature.reset();
    _humidity.reset();
    _pressure.reset();
    _batteryVoltage.reset();
  }

  bool get hasMeasurements => _measurements > 0;

  void add(SensorData data) {
    var ok = false;
    ok |= _temperature.add(data.temperature);
    ok |= _humidity.add(data.humidity);
    ok |= _pressure.add(data.pressure);
    ok |= _batteryVoltage.add(data.batteryVoltage);

    if (ok) {
      _measurements += 1;
    }
  }

  SensorData get snapshot => SensorData(
      _temperature.average,
      _humidity.average,
      _pressure.average,
      _batteryVoltage.average
  );
}

/// Used for calculating time-weighted average of a sensor data field.
class _StatsCollector {

  double _sum;
  double _lastValue;
  DateTime _last;
  DateTime _t0;

  _StatsCollector() {
    reset();
  }

  bool add(double value) {

    if (value == null || value.isNaN) {
      return false;
    }

    _t0 ??= DateTime.now();
    _consumeLast();
    _lastValue = value;
    _last = DateTime.now();
    return true;
  }

  void _consumeLast() {

    if (_lastValue != null) {
      _sum += _lastValue * _last.since.inMilliseconds;
      _lastValue = null;
    }
  }

  double get average {
    _consumeLast();
    return _sum / _t0.since.inMilliseconds;
  }

  void reset() {
    _last = null;
    _t0 = null;
    _sum = 0.0;
    _lastValue = null;
  }
}
