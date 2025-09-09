import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';

final Logger logger = Logger('CipherCopyLogger');

IOSink? _fileSink;
StreamSubscription<LogRecord>? _subscription;

/// Initialize logging to both console and a log file named using [destDir]
/// and a compact timestamp (YYYY-MM-DD-HH-SS). Returns the log file path.
Future<String> initLogging(String destDir) async {
  // Prepare log file path
  final ts = _compactTimestamp();
  final destName = destDir
      .split(Platform.pathSeparator)
      .where((part) => part.isNotEmpty)
      .last;
  final logFilePath =
      '${Directory.current.path}/copy-${destName.isEmpty ? 'dest' : destName}-$ts.log';

  // Open sink for file logging
  final file = File(logFilePath);
  _fileSink = file.openWrite(mode: FileMode.writeOnlyAppend);

  // Configure root logger and attach a single listener that writes to both
  hierarchicalLoggingEnabled = false; // use root level globally
  Logger.root.level = Level.INFO;
  _subscription = Logger.root.onRecord.listen((record) {
    final line = _formatRecord(record);
    _fileSink?.writeln(line);
    if (record.error != null) {
      _fileSink?.writeln(record.error);
    }
    if (record.stackTrace != null) {
      _fileSink?.writeln(record.stackTrace);
    }
  });

  return logFilePath;
}

/// Flush and close file logging and detach listeners.
Future<void> shutdownLogging() async {
  await _subscription?.cancel();
  _subscription = null;
  if (_fileSink != null) {
    await _fileSink!.flush();
    await _fileSink!.close();
    _fileSink = null;
  }
}

String _compactTimestamp() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}${two(now.hour)}${two(now.second)}';
}

String _formatRecord(LogRecord r) {
  final time = r.time.toIso8601String();
  final level = r.level.name.padRight(7);
  final loggerName = r.loggerName;
  return '$time $level $loggerName: ${r.message}';
}
