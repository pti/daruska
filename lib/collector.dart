import 'dart:async';

import 'data.dart';
import 'extensions.dart';

/// Keeps track of average SensorData values for each sensor for which an
/// event has been received.
class Collector {

  final _statsById = <int, _SensorStats>{};
  StreamSubscription<SensorEvent> _streamSubscription;

  Collector(List<SensorEvent> initEvents, Stream<SensorEvent> input) {
    initEvents?.forEach(_consume);
    _streamSubscription = input.listen(_consume);
  }

  Future<void> dispose() async{
    await _streamSubscription?.cancel();
    _streamSubscription = null;
  }

  void _consume(SensorEvent event) {
    final stats = _statsById[event.sensorId] ??= _SensorStats();
    stats.add(event.data, event.timestamp);
  }

  List<CollectData> collect({DateTime timestamp, bool reset = true}) {
    return _statsById.entries
        .where((e) => e.value.hasMeasurements)
        .map((entry) {
          final cd = CollectData(entry.key, timestamp ?? DateTime.now(), entry.value);
          if (reset) entry.value.reset();
          return cd;
        })
        .toList(growable: false);
  }
}

class CollectData {
  final int sensorId;
  final DateTime timestamp;
  final SensorData avg;
  final SensorData min;
  final SensorData max;

  CollectData(this.sensorId, this.timestamp, _SensorStats stats):
    avg = stats.avg,
    min = stats.min,
    max = stats.max;
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

  void add(SensorData data, DateTime timestamp) {
    var ok = false;
    ok |= _temperature.add(data.temperature, timestamp);
    ok |= _humidity.add(data.humidity, timestamp);
    ok |= _pressure.add(data.pressure, timestamp);
    ok |= _batteryVoltage.add(data.voltage, timestamp);

    if (ok) {
      _measurements += 1;
    }
  }

  SensorData get avg => SensorData(
      _temperature.average,
      _humidity.average,
      _pressure.average,
      _batteryVoltage.average
  );

  SensorData get min => SensorData(
      _temperature.min,
      _humidity.min,
      _pressure.min,
      _batteryVoltage.min
  );

  SensorData get max => SensorData(
      _temperature.max,
      _humidity.max,
      _pressure.max,
      _batteryVoltage.max
  );
}

/// Used for calculating time-weighted average of a sensor data field.
class _StatsCollector {

  double _sum;
  double _lastValue;
  double min;
  double max;
  DateTime _last;
  DateTime _t0;

  _StatsCollector() {
    reset();
  }

  bool add(double value, DateTime timestamp) {

    if (value == null || value.isNaN) {
      return false;
    }

    if (min == null || value < min) {
      min = value;
    }

    if (max == null || value > max) {
      max = value;
    }

    _t0 ??= timestamp;
    _updateSum(timestamp);
    _lastValue = value;
    _last = timestamp;
    return true;
  }

  void _updateSum(DateTime to) {

    if (_lastValue != null) {
      _sum += _lastValue * to.difference(_last).inMilliseconds;
      _last = to;
    }
  }

  double get average {

    if (_t0 == null) {
      return null;

    } else {
      _updateSum(DateTime.now());
      return _sum / _t0.since.inMilliseconds;
    }
  }

  void reset() {
    _last = null;
    _t0 = null;
    _sum = 0.0;
    _lastValue = null;
    min = null;
    max = null;
  }
}
