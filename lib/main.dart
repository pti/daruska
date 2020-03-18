import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:daruska/args.dart';
import 'package:daruska/data.dart';
import 'package:daruska/event_logger.dart';
import 'package:daruska/extensions.dart';
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
  final logger = EventLogger(src.eventStream);
  final latest = _LatestEventsCollector(src.eventStream);

  final persister = Persister();
  final archiveLimit = DateTime.now().subtract(Duration(days: 366)).truncate(DateTimeComponent.day);
  persister.archive(archiveLimit);
  persister.vacuum();

  final collectors = _setupCollectors(persister, settings, src);

  if (collectors.isEmpty) {
    log.info('db writes disabled');
  }

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
    collectors.forEach((c) async => await c.dispose());
    await src.dispose();
    await server.dispose();
    log.finest('disposed all components');
  });
}

List<Collector> _setupCollectors(Persister persister, Settings settings, DataSource src) {
  final minFreq = settings.collectFrequency.inMinutes;

  if (minFreq.isNegative) {
    return [];
  }

  final collectors = <Collector>[];
  final streams = <Stream<CollectEvent>>[];

  if (minFreq > 0 && minFreq < 30) {
    final collectorMin = Collector([], src.eventStream);
    final collectStreamMin = ExtraStream
        // To make the timestamps nice and even do the collection every <frequency> minutes :)
        .dynamicInterval(() {
          final now = DateTime.now().roundTime(DateTimeComponent.minute);
          return now.add(Duration(minutes: minFreq - (now.minute % minFreq))).until;
        })
        .map((_) => CollectEvent(Table.eventMin, collectorMin.collect(timestamp: DateTime.now().roundTime(DateTimeComponent.minute))));
    streams.add(collectStreamMin);
    collectors.add(collectorMin);
  }

  final hourStart = DateTime.now().truncate(DateTimeComponent.hour);
  final eventsSinceHourStart = persister.getSensorEvents(orderBy: 'timestamp', from: hourStart);
  final collector1h = Collector(eventsSinceHourStart, src.eventStream);
  final collectStream1h = ExtraStream
      .every(DateTimeComponent.hour)
      .map((_) => CollectEvent(Table.event1h, collector1h.collect(timestamp: DateTime.now().roundTime(DateTimeComponent.hour))));
  streams.add(collectStream1h);
  collectors.add(collector1h);

  final dayStart = DateTime.now().truncate(DateTimeComponent.day);
  final eventsSinceDayStart = persister.getSensorEvents(orderBy: 'timestamp', from: dayStart);
  final collector1d = Collector(eventsSinceDayStart, src.eventStream);
  final collectStream1d = ExtraStream
      .every(DateTimeComponent.day)
      .map((_) => CollectEvent(Table.event1d, collector1d.collect(timestamp: DateTime.now().roundTime(DateTimeComponent.hour))));
  streams.add(collectStream1d);
  collectors.add(collector1d);

  persister.setStream(StreamGroup.merge(streams));

  return collectors;
}

void _setupLogger(Level logLevel) {
  Logger.root.level = logLevel;
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
