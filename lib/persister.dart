import 'dart:async';

import 'package:daruska/collector.dart';
import 'package:daruska/data.dart';
import 'package:daruska/extensions.dart';
import 'package:daruska/sources.dart';
import 'package:logging/logging.dart';
import 'package:moor_ffi/database.dart';

final _log = Logger('db');
const _dbVersion = 1;

class CollectEvent {
  final Accuracy accuracy;
  final List<CollectData> data;

  CollectEvent(this.accuracy, this.data);
}

/// Takes care of writing sensor data to a database and provides functions for reading
/// sensor related information.
///
/// Database is split to multiple tables to keep the read performance adequate on a lower spec
/// PC (Raspberry Pi 3B) even after multiple years of use (tested using 10min write interval
/// for simulated 8 years and 8 sensors).
///
/// Sensor data is written to the database whenever events are emitted to the given stream.
/// The table is chosen based on the frequency (minimum, e.g. 10 minutes, 1h and 1d).
/// For the minimum frequency table 'event' is used and 1 year worth of data is kept in that
/// table before moving data older than a year to 'event_archive' table. Data in tables 'event_1h'
/// and 'event_1d' are never archived.
class Persister implements SensorInfoSource {

  Database _db;
  PreparedStatement _insertMinStatement;
  PreparedStatement _insert1hStatement;
  PreparedStatement _insert1dStatement;
  StreamSubscription _eventSubscription;
  var _sensorInfos = <int, SensorInfo>{};

  Persister() {
    _db = Database.open('events.db');

    if (_db.userVersion() != _dbVersion) {
      // TODO alter if schema changes.
      _db.execute(_createSensorTable);
      _db.execute(_createEventTable);
      _db.execute(_createEventArchiveTable);
      _db.execute(_createEventTableHourly);
      _db.execute(_createEventTableDaily);
      _db.setUserVersion(_dbVersion);
    }

    _sensorInfos = _readSensorInfos(_db);

    _insertMinStatement = _db.prepare(_insertMinEvent);
    _insert1hStatement = _db.prepare(_insert1hEvent);
    _insert1dStatement = _db.prepare(_insert1dEvent);
  }

  void setStream(Stream<CollectEvent> collectStream) {

    _eventSubscription = collectStream?.listen((event) {
      if (event.data.isEmpty) return;

      _log.finer('start saving');

      try {
        var statement;

        switch (event.accuracy) {
          case Accuracy.min:
            statement = _insertMinStatement;
            break;

          case Accuracy.hour:
            statement = _insert1hStatement;
            break;

          case Accuracy.day:
            statement = _insert1dStatement;
            break;
        }

        _db.execute('BEGIN TRANSACTION');

        for (final collectData in event.data) {
          statement.execute(_eventArguments(collectData, event.accuracy != Accuracy.min));

          if (!_sensorInfos.containsKey(collectData.sensorId)) {
            _log.fine('new sensor ${collectData.sensorId.toMacString()}');
            addSensor(SensorInfo(collectData.sensorId, '', true));
          }
        }

        _db.execute('END TRANSACTION');

      } catch (e) {
        _db.execute('ROLLBACK');
        _log.severe('error saving', e);

      } finally {
        _log.finer('done saving');
      }
    });
  }

  Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    [_insertMinStatement, _insert1hStatement, _insert1dStatement].forEach((s) => s.close());
    _db?.close();
    _db = null;
  }

  /// Move data older than [limit] from the 'event' table to the 'event_archive' table.
  void archive(DateTime limit) {

    try {
      _log.info('begin archiving');
      final minTimestamp = limit.secondsSinceEpoch;

      _db.execute('BEGIN TRANSACTION');

      _db.execute('INSERT INTO event_archive (sensor_id, timestamp, temperature, humidity, pressure, voltage)'
        ' SELECT sensor_id, timestamp, temperature, humidity, pressure, voltage'
        ' FROM event'
        ' WHERE timestamp < $minTimestamp');
      
      _db.execute('DELETE FROM event WHERE timestamp < $minTimestamp');

      _db.execute('END TRANSACTION');
      _log.info('done archiving');

    } catch (e) {
      _db.execute('ROLLBACK');
      _log.severe('error archiving', e);
    }
  }

  void vacuum() {
    _db.execute('VACUUM');
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
  List<SensorEvent> getSensorEvents({Accuracy accuracy = Accuracy.min,
    Frequency frequency = Frequency.min, Aggregate aggregate = Aggregate.avg,
    List<int> sensorIds, DateTime from, DateTime to, String orderBy, int offset, int limit})
  {
    assert(frequency != null);
    assert(accuracy != null);
    assert(aggregate != null);

    var timeConverter = (value) => DateTime.fromMillisecondsSinceEpoch(value * 1000);
    var groupSpec = 'sensor_id, timestamp';
    var tableName;

    switch (accuracy) {
      case Accuracy.day:
        tableName = 'event_1d';
        break;

      case Accuracy.hour:
        tableName = 'event_1h';
        break;

      case Accuracy.min:
      default:
        tableName = 'event';
        break;
    }

    switch (frequency) {
      case Frequency.daily:
        groupSpec = 'sensor_id, date(timestamp, "unixepoch", "localtime")';
        timeConverter = (value) => DateTime.parse(value);
        break;

      case Frequency.hourly:
        groupSpec = 'sensor_id, strftime("%Y-%m-%d %H", datetime(timestamp, "unixepoch", "localtime"))';
        timeConverter = (value) => DateTime.parse(value);
        break;

      case Frequency.weekly:
        // Seems that the year-changing-week can be included twice in the result. Shouldn't matter that much though.
      case Frequency.min:
      default:
        timeConverter = (value) => DateTime.fromMillisecondsSinceEpoch(value * 1000);
        break;
    }

    var selectA = groupSpec ?? 'sensor_id, timestamp';
    var selectFields = ['temperature', 'humidity', 'pressure', 'voltage'];
    // Order of the fields has a dependency to _readEvent.

    if (accuracy != Accuracy.min) {
      final af = _aggregateFunctionNames[(aggregate ?? Aggregate.avg).index].toLowerCase();
      selectFields = selectFields.map((f) => f == 'voltage' ? f : '${f}_$af').toList();
    }

    if (groupSpec != null) {
      final af = _aggregateFunctionNames[(aggregate ?? Aggregate.avg).index];
      selectFields = selectFields.map((f) => '$af($f)').toList();
    }

    final query = StringBuffer('SELECT $selectA, ${selectFields.join(',')} FROM $tableName');
    final whereParts = [];

    if (sensorIds != null) whereParts.add('sensor_id IN (${sensorIds.join(',')})');
    if (from != null) whereParts.add('timestamp >= ${from.secondsSinceEpoch}');
    if (to != null) whereParts.add('timestamp < ${to.secondsSinceEpoch}');

    if (whereParts.isNotEmpty) {
      query.write(' WHERE ');
      query.write(whereParts.join(' AND '));
    }

    if (groupSpec != null) {
      query.write(' GROUP BY $groupSpec');
    }

    const validOrderBys = {'timestamp', 'temperature', 'humidity', 'pressure', 'voltage'};

    if (orderBy != null) {
      assert(validOrderBys.contains(orderBy), 'Not a valid orderBy: $orderBy');
      query.write(' ORDER BY $orderBy');
    }

    if (limit != null) {
      query.write(' LIMIT $limit');
      if (offset != null) query.write(' OFFSET $offset');
    }

    _log.finer('get events: $query');
    final result = _db.prepare(query.toString()).select();
    return result.map((row) => _readEvent(row, timeConverter)).toList(growable: false);
  }

  @override
  Iterable<SensorInfo> getAllSensorInfos() => _sensorInfos.values;
}

const _aggregateFunctionNames = ['MIN', 'AVG', 'MAX'];

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

const _createEventArchiveTable = r'''
CREATE TABLE event_archive (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  sensor_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  temperature INTEGER,
  humidity INTEGER,
  pressure INTEGER,
  voltage INTEGER
);  
''';

const _createEventTableHourly = r'''
CREATE TABLE event_1h (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  sensor_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  temperature_avg INTEGER,
  temperature_min INTEGER,
  temperature_max INTEGER,
  humidity_avg INTEGER,
  humidity_min INTEGER,
  humidity_max INTEGER,
  pressure_avg INTEGER,
  pressure_min INTEGER,
  pressure_max INTEGER,
  voltage INTEGER
);  
''';

const _createEventTableDaily = r'''
CREATE TABLE event_1d (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  sensor_id INTEGER NOT NULL,
  timestamp INTEGER NOT NULL,
  temperature_avg INTEGER,
  temperature_min INTEGER,
  temperature_max INTEGER,
  humidity_avg INTEGER,
  humidity_min INTEGER,
  humidity_max INTEGER,
  pressure_avg INTEGER,
  pressure_min INTEGER,
  pressure_max INTEGER,
  voltage INTEGER
);  
''';

// temperature -> C * 5/1000 (0.005 accuracy)
// humidity -> % * 25/10000 (0.0025 accuracy)
// pressure -> hPa * 100 - 50000 Pa
// voltage -> V * 1000 (0.001 accuracy)

typedef _TimeConverter = DateTime Function(dynamic value);

SensorEvent _readEvent(Row row, _TimeConverter timeConverter) {
  return SensorEvent(
      row.columnAt(0),
      timeConverter(row.columnAt(1)),
      SensorData(
        row.columnAt(2) * 0.005,
        row.columnAt(3) * 0.0025,
        (row.columnAt(4) + 50000) / 100,
        row.columnAt(5) * 0.001,
      )
  );
}

const _insertMinEvent = 'INSERT INTO event(sensor_id, timestamp, temperature, humidity, pressure, voltage) VALUES (?, ?, ?, ?, ?, ?)';
const _insert1hEvent = 'INSERT INTO event_1h(sensor_id, timestamp, '
    'temperature_avg, temperature_min, temperature_max, '
    'humidity_avg, humidity_min, humidity_max, '
    'pressure_avg, pressure_min, pressure_max, '
    'voltage) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';
const _insert1dEvent = 'INSERT INTO event_1d(sensor_id, timestamp, '
    'temperature_avg, temperature_min, temperature_max, '
    'humidity_avg, humidity_min, humidity_max, '
    'pressure_avg, pressure_min, pressure_max, '
    'voltage) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

List _eventArguments(CollectData event, bool full) {

  if (full) {
    return [
      event.sensorId,
      event.timestamp.secondsSinceEpoch,
      event.avg.temperature?._toDbTemperature(),
      event.min.temperature?._toDbTemperature(),
      event.max.temperature?._toDbTemperature(),
      event.avg.humidity?._toDbHumidity(),
      event.min.humidity?._toDbHumidity(),
      event.max.humidity?._toDbHumidity(),
      event.avg.pressure?._toDbPressure(),
      event.min.pressure?._toDbPressure(),
      event.max.pressure?._toDbPressure(),
      event.avg.voltage?._toDbVoltage()
    ];

  } else {
    return [
      event.sensorId,
      event.timestamp.secondsSinceEpoch,
      event.avg.temperature?._toDbTemperature(),
      event.avg.humidity?._toDbHumidity(),
      event.avg.pressure?._toDbPressure(),
      event.avg.voltage?._toDbVoltage()
    ];
  }
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

extension on double {
  int _toDbTemperature() => (this * 200).round();
  int _toDbHumidity() => (this * 400).round();
  int _toDbPressure() => ((this * 100) - 50000).round();
  int _toDbVoltage() => (this * 1000).round();
}
