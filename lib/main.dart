import 'dart:async';
import 'dart:io';

import 'package:daruska/args.dart';
import 'package:daruska/data.dart';
import 'package:daruska/event_logger.dart';
import 'package:daruska/persister.dart';
import 'package:daruska/server.dart';
import 'package:daruska/sources.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'collector.dart';
import 'data_source.dart';

void main(List<String> args) async {
  final settings = parseArguments(args);
  if (settings == null) return;

  _setupLogger(settings.logLevel);
  final log = Logger('main');

  final src = DataSource();
  final latest = _LatestEventsCollector(src.eventStream);

  final collector = Collector(src.eventStream);
  final collectStream = Stream
      .periodic(settings.collectFrequency)
      .map((_) => collector.collect());

  final persister = Persister(collectStream);
  final logger = EventLogger(src.eventStream);

  final server = Server(src, latest, persister);
  await server.start();

  var moc = settings.monitoringConfiguration;

  if (moc.useActive) {
    final activeIds = persister
        .getAllSensorInfos()
        .where((info) => info.active)
        .map((info) => info.sensorId)
        .toSet();
    moc = moc.copyWith(sensorIds: activeIds, all: true);
  }

  await src.setConfiguration(moc);

  final _ = MergeStream([
    ProcessSignal.sighup.watch(),
    ProcessSignal.sigint.watch(),
    ProcessSignal.sigterm.watch()

  ]).first.then((signal) async {
    log.fine('handle signal $signal');
    await latest.dispose();
    await logger.dispose();
    await persister.dispose();
    await collector.dispose();
    await src.dispose();
    await server.dispose();
    log.finest('disposed all components');
  });
}

void _setupLogger(Level logLevel) {
  Logger.root.level = logLevel;
  Logger.root.level = Level.FINEST;
  Logger.root.onRecord.listen((rec) {
    final err = rec.error;

    if (err == null) {
      print('${rec.time} ${rec.loggerName.padRight(6, ' ')} ${rec.level.name.padRight(7, ' ')} ${rec.message}');
    } else {
      print('${rec.time} ${rec.loggerName.padRight(6, ' ')} ${rec.level.name.padRight(7, ' ')} ${rec.message}: $err');
    }

    final st = (err != null && err is Error) ? err.stackTrace : rec.stackTrace;
    if (st != null) print(st);
  });
}

class _LatestEventsCollector implements LatestEventsSource {

  final _latestBySensorId = <int, SensorEvent>{};
  StreamSubscription<SensorEvent> _eventSubscription;

  _LatestEventsCollector(Stream<SensorEvent> eventStream) {

    _eventSubscription = eventStream.listen((event) {
      _latestBySensorId[event.sensorId] = event;
    });
  }

  Future<void> dispose() async {
    await _eventSubscription?.cancel();
  }

  @override
  List<SensorEvent> latestEvents() => _latestBySensorId.values.toList();

  @override
  SensorEvent latestForSensor(int sensorId) => _latestBySensorId[sensorId];
}
