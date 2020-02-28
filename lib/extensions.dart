
extension ExtraDateTime on DateTime {
  Duration get since => DateTime.now().difference(this);
}
