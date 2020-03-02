import 'dart:async';

import 'package:daruska/data.dart';
import 'package:logging/logging.dart';

class EventLogger {

  static const _level = Level.FINE;
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

extension on int {

  String toMacString() {
    final src = toRadixString(16).toUpperCase().padLeft(12, '0');
    final sb = StringBuffer();

    for (var i = 0; i < 12; i += 2) {
      sb.write(src.substring(i, i + 2));
      if (i < 10) sb.write(':');
    }

    return sb.toString();
  }
}
