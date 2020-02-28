
/// Any of the fields may be null (sensor reading was invalid or information wasn't available).
class SensorData {

  /// °C
  final double temperature;

  /// %
  final double humidity;

  /// hPa
  final double pressure;

  /// V
  final double batteryVoltage;

  SensorData(this.temperature, this.humidity, this.pressure, this.batteryVoltage);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorData &&
          runtimeType == other.runtimeType &&
          temperature == other.temperature &&
          humidity == other.humidity &&
          pressure == other.pressure &&
          batteryVoltage == other.batteryVoltage;

  @override
  int get hashCode =>
      temperature.hashCode ^
      humidity.hashCode ^
      pressure.hashCode ^
      batteryVoltage.hashCode;

  @override
  String toString() {
    return 'SensorData{temperature: $temperature\u200A°C, humidity: $humidity\u200A%, pressure: $pressure\u200AhPa, batteryVoltage: $batteryVoltage\u200AV}';
  }
}

class SensorEvent {

  final int sensorId;
  final DateTime timestamp;
  final SensorData data;

  SensorEvent(this.sensorId, this.timestamp, this.data);
}
