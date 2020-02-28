import 'dart:typed_data';
import 'data.dart';

const ruuviManufacturerId = 0x0499;

SensorData parseRuuviData(List<int> manufacturerData) {
  final bytes = Uint8List.fromList(manufacturerData);
  final view = ByteData.view(bytes.buffer);
  final manufacturerId = view.getUint16(0, Endian.little);

  if (manufacturerId != ruuviManufacturerId) {
    return null;
  }

  final dataFormat = view.getUint8(2);

  switch (dataFormat) {
    case 3:
      final t = view.getUint8(4);
      final humidity = view.getUint8(3) / 2.0;
      final temperature = ((t & 0x7F) + view.getUint8(5) / 100.0) * (t & 0x80 > 0 ? -1 : 1);
      final pressure = (view.getUint16(6) + 50000) / 100.0;
      final batteryVoltage = view.getUint16(14) / 1000.0;
      return SensorData(temperature, humidity, pressure, batteryVoltage);

    case 5:
      final a = view.getInt16(3);
      final b = view.getUint16(5);
      final c = view.getUint16(7);
      final d = view.getUint16(15);
      final d1 = (d >> 5) & 0x7FF;
      final d2 = d & 0x1F;
      final temperature = a == 0x8000 ? null : a * 0.005;
      final humidity = b == 0xFFFF ? null : b * 0.0025;
      final pressure = c == 0xFFFF ? null : (c + 50000) / 100.0;
      final batteryVoltage = d1 == 0x07FF ? null : 1.6 + d1 / 1000.0;
      final txPower = d2 == 0x1F ? null : -40 + d2 * 2;
      return SensorData(temperature, humidity, pressure, batteryVoltage);

    default:
      return null;
  }
}
