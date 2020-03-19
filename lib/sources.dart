import 'package:daruska/data.dart';

abstract class SensorEventSource {

  Stream<SensorEvent> get eventStream;

  /// If there are no subscribers to realtime updates, then the source can monitor the sensors
  /// less frequently. Use the returned identifier when unsubscribing.
  int subscribeRealtimeUpdates();

  void unsubscribeRealtimeUpdates(int id);
}

abstract class SensorInfoSource {

  SensorInfo getSensorInfo(int sensorId);

  Iterable<SensorInfo> getAllSensorInfos();

  void saveSensorInfo(SensorInfo info);

  List<SensorEvent> getSensorEvents({Accuracy accuracy = Accuracy.min,
    Frequency frequency = Frequency.min, Aggregate aggregate = Aggregate.avg,
    List<int> sensorIds, DateTime from, DateTime to, String orderBy, int offset, int limit});
}

abstract class LatestEventsSource {

  SensorEvent latestForSensor(int sensorId);

  List<SensorEvent> latestEvents();
}

enum Accuracy {
  min,
  hour,
  day,
}

enum Frequency {
  min,
  hourly,
  daily,
  weekly
}

enum Aggregate {
  min,
  avg,
  max
}
