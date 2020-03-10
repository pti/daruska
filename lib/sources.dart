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
}

abstract class LatestEventsSource {

  SensorEvent latestForSensor(int sensorId);

  List<SensorEvent> latestEvents();
}
