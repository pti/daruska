import 'package:args/args.dart';
import 'package:daruska/data_source.dart';
import 'package:logging/logging.dart';

import 'extensions.dart';

class Settings {

  final MonitoringConfiguration monitoringConfiguration;
  final Duration collectFrequency;
  final Level logLevel;

  Settings(this.monitoringConfiguration, this.collectFrequency, this.logLevel):
        assert(monitoringConfiguration != null),
        assert(logLevel != null);
}

/// Returns null if provided arguments were not valid. If that is the case instructions will be
/// printed and program execution should stop.
Settings parseArguments(List<String> args) {

  final parser = ArgParser()
    ..addOption('command', abbr: 'c', help: 'Run this command to produce scan results')
    ..addOption('interval', defaultsTo: '60', abbr: 'i', help: 'Number of seconds between active scan periods')
    ..addOption('timeout', defaultsTo: '10', abbr: 't', help: 'Defines the maximum number of seconds to keep the scanner active')
    ..addMultiOption('devices', abbr: 'd', help: 'List of device MAC addresses to scan for, e.g. AA:BB:CC:11:22:33')
    ..addFlag('use_saved', abbr: 'u', defaultsTo: false, help: 'Only scan the active devices defined in the database')
    ..addOption('frequency', defaultsTo: '10', abbr: 'f', help: 'Defines how often to store collected data to database (in minutes)')
    ..addOption('loglevel', abbr: 'l', defaultsTo: 'severe', help: 'Log level', allowed: Level.LEVELS.map((l) => l.name.toLowerCase()))
  ;

  try {
    final res = parser.parse(args);

    if (res['command'] == null) {
      throw FormatException('Missing cmd option');
    }

    final devices = res.getList('devices').toSet();

    return Settings(
        MonitoringConfiguration(
          command: res.getString('command').split(' '),
          interval: Duration(seconds: res.getInt('interval')),
          timeout: Duration(seconds: res.getInt('timeout')),
          sensorIds: devices?.map((str) => str.parseSensorId())?.toSet() ?? {},
          all: devices.isNotEmpty,
          useActive: res.getBool('use_saved'),
        ),
        Duration(minutes: res.getInt('frequency')),
        res.getString('loglevel').toLevel(),
    );

  } catch (e) {

    if (e is FormatException) {
      print(e.message);
    } else {
      print(e);
    }

    print('');
    print(parser.usage);
    return null;
  }
}

extension on ArgResults {
  int getInt(String name) => int.parse(this[name]);
  bool getBool(String name) => this[name] as bool;
  String getString(String name) => this[name] as String;
  List<String> getList(String name) => this[name] as List<String>;
}

extension on String {
  Level toLevel() => Level.LEVELS.firstWhere((l) => this == l.name.toLowerCase());
}
