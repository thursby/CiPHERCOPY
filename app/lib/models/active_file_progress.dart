import 'dart:io';

class ActiveFileProgress {
  final String path;
  final int copied;
  final int total;
  const ActiveFileProgress({
    required this.path,
    required this.copied,
    required this.total,
  });
  double get ratio => total == 0 ? 0 : (copied / total).clamp(0, 1);
  String get name {
    final idx = path.lastIndexOf(Platform.pathSeparator);
    return idx >= 0 ? path.substring(idx + 1) : path;
  }
}
