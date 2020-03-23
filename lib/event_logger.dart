import 'dart:async';

import 'package:daruska/data.dart';
import 'package:logging/logging.dart';

import 'extensions.dart';

class EventLogger {

  static const _level = Level.FINEST;
  final _log = Logger('log');
  StreamSubscription<SensorEvent> _subscription;

  EventLogger(Stream<SensorEvent> stream) {

    if (_log.isLoggable(_level)) {
      _subscription = stream
          .listen((e) => _log.log(_level, ''
          '${e.sensorId.toMacString()} '
          '${e.data.temperature.toStringAsFixed(2)}\u200A°C '
          '${e.data.humidity.toStringAsFixed(2)}\u200A% '
          '${e.data.pressure.toStringAsFixed(2)}\u200AhPa '
          '${e.data.voltage.toStringAsFixed(2)}\u200AV'
      ));
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
