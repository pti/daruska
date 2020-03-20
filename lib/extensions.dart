import 'dart:async';

extension ExtraDateTime on DateTime {

  Duration get since => DateTime.now().difference(this);

  Duration get until => difference(DateTime.now());

  int get secondsSinceEpoch => (millisecondsSinceEpoch / 1000).round();

  DateTime nextStart(DateTimeComponent accuracy) {
    assert(accuracy >= DateTimeComponent.day);
    final jump = Duration(
      days: accuracy == DateTimeComponent.day ? 1 : 0,
      hours: accuracy == DateTimeComponent.hour ? 1 : 0,
      minutes: accuracy == DateTimeComponent.minute ? 1 : 0,
      seconds: accuracy == DateTimeComponent.second ? 1 : 0,
    );
    return add(jump).truncate(accuracy);
  }

  DateTime truncate(DateTimeComponent accuracy) {
    return DateTime(
      year,
      accuracy >= DateTimeComponent.month ? month : 1,
      accuracy >= DateTimeComponent.day ? day : 1,
      accuracy >= DateTimeComponent.hour ? hour : 0,
      accuracy >= DateTimeComponent.minute ? minute : 0,
      accuracy >= DateTimeComponent.second ? second : 0,
    );
  }

  DateTime roundTime(DateTimeComponent accuracy) {
    return DateTime(
      year,
      month,
      day,
      (accuracy >= DateTimeComponent.hour ? hour : 0) + (accuracy == DateTimeComponent.hour ? (minute / 60.0).round() : 0),
      (accuracy >= DateTimeComponent.minute ? minute : 0) + (accuracy == DateTimeComponent.minute ? (second / 60.0).round() : 0),
      (accuracy >= DateTimeComponent.second ? second : 0) + (accuracy == DateTimeComponent.second ? (millisecond / 1000.0).round() : 0),
    );
  }

  String toTimestampString() {
    final str = toUtc().toIso8601String();
    final lastDot = str.lastIndexOf('.');
    return str.substring(0, lastDot) + 'Z';
  }
}

enum DateTimeComponent {
  year,
  month,
  day,
  hour,
  minute,
  second,
}

extension on DateTimeComponent {
  bool operator <(DateTimeComponent other) => index < other.index;
  bool operator >(DateTimeComponent other) => index > other.index;
  bool operator <=(DateTimeComponent other) => index <= other.index;
  bool operator >=(DateTimeComponent other) => index >= other.index;
}

extension ExtraInt on int {

  String toMacString({bool separated = true}) {
    final src = toRadixString(16).toUpperCase().padLeft(12, '0');
    final sb = StringBuffer();

    for (var i = 0; i < 12; i += 2) {
      sb.write(src.substring(i, i + 2));
      if (separated && i < 10) sb.write(':');
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

extension ExtraStream on Stream {

  /// [delay] is used to calculate the delay to the next event. Return null to end the stream.
  static Stream<T> dynamicInterval<T>(Duration Function() delay, [T Function(int) computation]) {
    StreamController<T> controller;
    Timer timer;
    var i = 0;

    void sendEvent() {
      var data = computation == null ? null : computation(i);
      i++;
      controller?.add(data);
    }

    void startTimer() {
      timer = Timer(delay(), () {
        sendEvent();
        startTimer();
      });
    }

    controller = StreamController<T>(
      onListen: () {
        startTimer();
      },
      onPause: () {
        timer?.cancel();
        timer = null;
      },
      onResume: () {
        assert(timer == null);
        startTimer();
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
        return null;
      },
    );

    return controller.stream;
  }

  static Stream<T> every<T>(DateTimeComponent accuracy, [T Function(int) computation]) {
    return ExtraStream.dynamicInterval(() => DateTime.now().nextStart(accuracy).until, computation);
  }
}

extension ExtraList<T> on List<T> {

  Map<String, T> toNameMap() => Map.fromEntries(map((value) {
    final str = value.toString();
    final lastDot = str.lastIndexOf('.');
    final name = lastDot == -1 ? str : str.substring(lastDot + 1);
    return MapEntry(name, value);
  }));
}
