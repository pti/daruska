
extension ExtraDateTime on DateTime {
  Duration get since => DateTime.now().difference(this);
}

extension ExtraInt on int {

  String toMacString() {
    final src = toRadixString(16).toUpperCase().padLeft(12, '0');
    final sb = StringBuffer();

    for (var i = 0; i < 12; i += 2) {
      sb.write(src.substring(i, i + 2));
      if (i < 10) sb.write(':');
    }

    return sb.toString();
  }
}

extension ExtraString on String {

  int parseSensorId() {
    return split(':')
        .map((b) => int.parse(b, radix: 16))
        .reduce((a, b) => (a << 8) | b);
  }
}
