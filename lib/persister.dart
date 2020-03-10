import 'dart:async';

import 'package:daruska/data.dart';
import 'package:daruska/extensions.dart';
import 'package:daruska/sources.dart';
import 'package:logging/logging.dart';
import 'package:moor_ffi/database.dart';

final _log = Logger('db');
const _dbVersion = 1;

class Persister implements SensorInfoSource {

  Database _db;
  PreparedStatement _insertStatement;
  StreamSubscription _eventSubscription;
  var _sensorInfos = <int, SensorInfo>{};

  Persister(Stream<List<SensorEvent>> collectStream) {
    _db = Database.open('events.db');

    if (_db.userVersion() != _dbVersion) {
      // TODO alter if schema changes.
      _db.execute(_createSensorTable);
      _db.execute(_createEventTable);
      _db.setUserVersion(_dbVersion);
    }

    _sensorInfos = _readSensorInfos(_db);

    _insertStatement = _db.prepare(_insertEvent);

    _eventSubscription = collectStream.listen((data) {

      try {
        _log.finer('start saving');
        _db.execute('BEGIN TRANSACTION');

        for (final event in data) {
          _insertStatement.execute(_eventArguments(event));

          if (!_sensorInfos.containsKey(event.sensorId)) {
            _log.fine('new sensor ${event.sensorId.toMacString()}');
            addSensor(SensorInfo(event.sensorId, '', true));
          }
        }

        _db.execute('END TRANSACTION');
        _log.finer('done saving');

      } catch (e) {
        _log.severe('error saving', e);
      }
    });
  }

  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    _insertStatement?.close();
    _insertStatement = null;
    _db?.close();
    _db = null;
  }

  @override
  void saveSensorInfo(SensorInfo info) {
    _db.execute('UPDATE sensor SET name = "${info.name}", active = ${info.active._toInt()} WHERE id = ${info.sensorId}');
    _sensorInfos[info.sensorId] = info;
  }

  void addSensor(SensorInfo info) {
    _db.execute('INSERT INTO sensor VALUES (${info.sensorId}, "${info.name}", ${info.active._toInt()})');
    _sensorInfos[info.sensorId] = info;
  }

  @override
  SensorInfo getSensorInfo(int sensorId) {
    return _sensorInfos[sensorId];
  }

  @override
  Iterable<SensorInfo> getAllSensorInfos() => _sensorInfos.values;
}

const _createSensorTable = r'''
CREATE TABLE sensor (
  id INTEGER NOT NULL PRIMARY KEY,
  name TEXT,
  active INTEGER
);
''';

const _createEventTable = r'''
CREATE TABLE event (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  sensor_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  temperature INTEGER,
  humidity INTEGER,
  pressure INTEGER,
  voltage INTEGER,
  FOREIGN KEY (sensor_id) REFERENCES sensor (id)
);  
''';

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
    d.voltage == null ? null : (d.voltage * 1000).round()
  ];
}

Map<int, SensorInfo> _readSensorInfos(Database db) {
  final infos = <int, SensorInfo>{};
  PreparedStatement statement;

  try {
    statement = db.prepare('SELECT id, name, active FROM sensor');
    final result = statement.select();

    for (final row in result) {
      final sensorId = row['id'] as int;
      infos[sensorId] = SensorInfo(sensorId, row['name'], row['active'] == 1);
    }

  } finally {
    statement?.close();
  }

  return infos;
}

extension on bool {
  int _toInt() => this ? 1 : 0;
}
