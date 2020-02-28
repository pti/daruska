import 'dart:async';

import 'package:daruska/data.dart';
import 'package:logging/logging.dart';

import 'package:moor_ffi/database.dart';

final _log = Logger('db');

class Persister {

  Database _db;
  PreparedStatement _insertStatement;
  StreamSubscription _eventSubscription;

  Persister(Stream<List<SensorEvent>> collectStream) {
    _db = Database.open('events.db');

    try {
//    _db.execute(_createSensorTable);
      _db.execute(_createEventTable);
    } catch (err) {
      // TODO how should 'already created' be handled? _db.userVersion() + set?
    }

    _insertStatement = _db.prepare(_insertEvent);

    _eventSubscription = collectStream.listen((data) {
      _log.finer('start saving');
      _db.execute('BEGIN TRANSACTION');

      for (final event in data) {
        _insertStatement.execute(_eventArguments(event));
      }

      _db.execute('END TRANSACTION');
      _log.finer('done saving');
    });
  }

  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _insertStatement?.close();
    _insertStatement = null;
    _db?.close();
    _db = null;
  }
}

//const _createSensorTable = r'''
//CREATE TABLE sensor (
//  id INTEGER NOT NULL PRIMARY KEY,
//  name TEXT
//);
//''';

const _createEventTable = r'''
CREATE TABLE event (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  sensor_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  temperature INTEGER,
  humidity INTEGER,
  pressure INTEGER,
  voltage INTEGER
);  
''';
//FOREIGN KEY (sensor_id) REFERENCES sensor (id)

// timestamp is seconds since epoch
// temperature -> C * 5/1000 (0.005 accuracy)
// humidity -> % * 25/10000 (0.0025 accuracy)
// pressure -> hPa * 100 - 50000 Pa
// voltage -> V * 1000 (0.001 accuracy)

SensorEvent _readEvent(Map row) {
  return SensorEvent(
    row['sensorId'],
    DateTime.fromMicrosecondsSinceEpoch(row['timestamp'] * 1000),
    SensorData(
      row['temperature'] * 0.005,
      row['humidity'] * 0.0025,
      (row['pressure'] + 50000) / 100,
      row['voltage'] * 0.001,
    )
  );
}

const _insertEvent = 'INSERT INTO event(sensor_id, timestamp, temperature, humidity, pressure, voltage) VALUES (?, ?, ?, ?, ?, ?)';

List _eventArguments(SensorEvent event) {
  final d = event.data;

  return [
    event.sensorId,
    (event.timestamp.millisecondsSinceEpoch / 1000).round(),
    d.temperature == null ? null : (d.temperature * 200).round(),
    d.humidity == null ? null : (d.humidity * 400).round(),
    d.pressure == null ? null : (d.pressure * 100 - 50000).round(),
    d.batteryVoltage == null ? null : (d.batteryVoltage * 1000).round()
  ];
}
