import 'package:daruska/data.dart';

abstract class SensorEventSource {

  Stream<SensorEvent> get eventStream;

  /// If there are no subscribers to realtime updates, then the source can monitor the sensors
  /// less frequently. Use the returned identifier when unsubscribing.
  int subscribeRealtimeUpdates();

  void unsubscribeRealtimeUpdates(int id);
}
