import 'extensions.dart';

/// Any of the fields may be null (sensor reading was invalid or information wasn't available).
class SensorData {

  /// °C
  final double temperature;

  /// %
  final double humidity;

  /// hPa
  final double pressure;

  /// Battery voltage (V).
  final double voltage;

  SensorData(this.temperature, this.humidity, this.pressure, this.voltage);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorData &&
          runtimeType == other.runtimeType &&
          temperature == other.temperature &&
          humidity == other.humidity &&
          pressure == other.pressure &&
          voltage == other.voltage;

  @override
  int get hashCode =>
      temperature.hashCode ^
      humidity.hashCode ^
      pressure.hashCode ^
      voltage.hashCode;

  @override
  String toString() {
    return 'SensorData{temperature: $temperature\u200A°C, humidity: $humidity\u200A%, pressure: $pressure\u200AhPa, voltage: $voltage\u200AV}';
  }

  Map<String, dynamic> toJson() {
    final json = {
      'temperature': temperature,
      'humidity': humidity,
      'pressure': pressure,
      'voltage': voltage
    };

    json.removeWhere((k, v) => v == null);
    return json;
  }

  bool isSame(SensorData other, Set<SensorField> fields) {
    return (!fields.contains(SensorField.temperature) || temperature == other.temperature)
        && (!fields.contains(SensorField.humidity) || humidity == other.humidity)
        && (!fields.contains(SensorField.pressure) || pressure == other.pressure)
        && (!fields.contains(SensorField.voltage) || voltage == other.voltage);
  }

  SensorData withFields(Set<SensorField> fields) {

    if (fields.isEmpty || fields.length == SensorField.values.length) {
      return this;

    } else {
      return SensorData(
        fields.contains(SensorField.temperature) ? temperature : null,
        fields.contains(SensorField.humidity) ? humidity : null,
        fields.contains(SensorField.pressure) ? pressure : null,
        fields.contains(SensorField.voltage) ? voltage : null,
      );
    }
  }
}

class SensorEvent {

  final int sensorId;
  final DateTime timestamp;
  final SensorData data;

  SensorEvent(this.sensorId, this.timestamp, this.data);

  Map<String, dynamic> toJson() {
    return {
      // Use the same format as is used in API endpoint paths.
      'sensorId': sensorId.toMacString(separated: false),
      'timestamp': timestamp.toTimestampString(),
      'data': data.toJson(),
    };
  }
}

enum SensorField {
  temperature,
  humidity,
  pressure,
  voltage
}

extension XSensorField on SensorField {
  static final Map<String, SensorField> _valueByName = SensorField.values.toNameMap();
}

extension SensorFieldString on String {
  SensorField toSensorField() => XSensorField._valueByName[this];
}

class SensorInfo {

  final int sensorId;
  final String name;
  final bool active;

  SensorInfo(this.sensorId, this.name, this.active);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SensorInfo &&
          runtimeType == other.runtimeType &&
          sensorId == other.sensorId &&
          active == other.active &&
          name == other.name;

  @override
  int get hashCode => sensorId.hashCode;

  Map<String, dynamic> toJson() {
    return {
      'sensorId': sensorId.toMacString(separated: false),
      'name': name,
      'active': active,
    };
  }
}
