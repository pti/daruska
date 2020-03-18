import 'package:args/args.dart';
import 'package:daruska/data_source.dart';
import 'package:logging/logging.dart';

import 'extensions.dart';

class Settings {

  final MonitoringConfiguration monitoringConfiguration;
  final Duration collectFrequency;
  final Duration archiveAfter;
  final Level logLevel;
  final int port;
  final String serverAddress;

  Settings(this.monitoringConfiguration, this.collectFrequency, this.archiveAfter, this.port, this.serverAddress, this.logLevel):
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
    ..addOption('archive_after', abbr: 'a', defaultsTo: '366', help: 'Archive events older than the specified number of days')
    ..addOption('port', abbr: 'p', defaultsTo: '21800', help: 'HTTP server port to bind to')
    ..addOption('addr', help: 'HTTP server IP-address or hostname to bind to (defaults to 127.0.0.1)')
    ..addOption('help', abbr: 'h')
  ;

  try {
    final res = parser.parse(args);

    if (res['help'] != null) {
      parser.printHelp();
      return null;
    }

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
        Duration(days: res.getInt('archive_after')),
        res.getInt('port'),
        res.getString('addr'),
        res.getString('loglevel').toLevel(),
    );

  } catch (e) {

    if (e is FormatException) {
      print(e.message);
    } else {
      print(e);
    }

    parser.printHelp();
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

extension on ArgParser {
  void printHelp() {
    print('\n$usage\n');
  }
}
