import 'dart:async';
import 'dart:io';

import 'package:daruska/args.dart';
import 'package:daruska/event_logger.dart';
import 'package:daruska/persister.dart';
import 'package:daruska/server.dart';
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

  final server = Server(src);
  await server.start();

  final collector = Collector(src.eventStream);
  await src.setConfiguration(settings.monitoringConfiguration);

  final collectStream = Stream
      .periodic(settings.collectFrequency)
      .map((_) => collector.collect());

  final persister = Persister(collectStream);
  final logger = EventLogger(src.eventStream);

  final _ = MergeStream([
    ProcessSignal.sighup.watch(),
    ProcessSignal.sigint.watch(),
    ProcessSignal.sigterm.watch()

  ]).first.then((signal) async {
    log.fine('handle signal $signal');
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