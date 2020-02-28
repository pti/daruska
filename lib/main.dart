import 'dart:async';
import 'dart:io';

import 'package:daruska/args.dart';
import 'package:daruska/event_logger.dart';
import 'package:daruska/persister.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'collector.dart';
import 'data_source.dart';

void main(List<String> args) async {
  final settings = parseArguments(args);
  if (settings == null) return;

  Logger.root.level = settings.logLevel;
  Logger.root.onRecord.listen((record) {
    print('${record.time} ${record.level.name.padRight(7, ' ')} ${record.message}');
  });

  final src = DataSource();
  final collector = Collector(src.stream);
  await src.setConfiguration(settings.monitoringConfiguration);

  final collectStream = Stream
      .periodic(settings.collectFrequency)
      .map((_) => collector.collect());

  final persister = Persister(collectStream);
  final logger = EventLogger(src.stream);

  final _ = MergeStream([
    ProcessSignal.sighup.watch(),
    ProcessSignal.sigint.watch(),
    ProcessSignal.sigterm.watch()

  ]).first.then((signal) {
    logger.dispose();
    persister.dispose();
    collector.dispose();
    src.dispose();
  });
}
