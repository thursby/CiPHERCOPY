// Core copy & verify logic for ciphercopy_cli
// Renamed from ciphercopy.dart to ciphercopy_core.dart for clarity and reuse.
import 'dart:io';
import 'dart:isolate';
import 'dart:async';
import 'package:ciphercopy_core/src/ciphercopy_logger.dart';
import 'package:crypto/crypto.dart';

class Result<T> {
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  Result.success(this.value) : error = null, stackTrace = null;
  Result.failure(this.error, [this.stackTrace]) : value = null;
  bool get isSuccess => error == null;
  bool get isFailure => error != null;
}

/// Types of progress events emitted by core operations.
enum ProgressEventType { fileProgress, fileDone, overall }

/// Progress event passed to the caller-supplied callback so the UI layer
/// (CLI, GUI, etc.) can render its own progress bars without embedding
/// terminal logic inside the core library.
class ProgressEvent {
  final ProgressEventType type;
  final String? path; // Destination path for copy, file path for verify
  final int? copied; // Bytes copied / read so far for this file
  final int? total; // Total bytes for this file
  final int? completedFiles; // Number of completed files overall
  final int? totalFiles; // Total number of files overall
  ProgressEvent({
    required this.type,
    this.path,
    this.copied,
    this.total,
    this.completedFiles,
    this.totalFiles,
  });
}

/// Simple cancellation token that can be polled by long-running operations.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

Future<void> copyFilesFromList(
  String listFile,
  String destDir, {
  int? threadCount,
  bool saveLists = false,
  void Function(ProgressEvent event)? onProgress,
  CancellationToken? cancelToken,
}) async {
  final lines = await File(listFile).readAsLines();
  final hashFile = destDir.endsWith('/') ? '${destDir}hashes.sha1' : '$destDir/hashes.sha1';
  await deleteFile(hashFile);
  logger.info('Copying files from list: $listFile to $destDir');
  final queue = <Map<String, String>>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (await FileSystemEntity.isDirectory(trimmed)) continue;
    final relPath = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    final destPath = destDir.endsWith('/') ? '$destDir$relPath' : '$destDir/$relPath';
    await Directory(destPath.substring(0, destPath.lastIndexOf('/'))).create(recursive: true);
    queue.add({'source': trimmed, 'dest': destPath});
  }
  final cpuCount = threadCount ?? Platform.numberOfProcessors;
  final totalFiles = queue.length;
  logger.info('Total files to copy: $totalFiles using $cpuCount workers (pool).');
  onProgress?.call(ProgressEvent(type: ProgressEventType.overall, completedFiles: 0, totalFiles: totalFiles));
  if (totalFiles == 0) {
    logger.warning('No files to copy.');
    return;
  }
  final receivePort = ReceivePort();
  final copied = <String>[];
  final errored = <String>[];
  final hashLines = <String>[];
  var completed = 0;
  var active = 0;
  final idleWorkers = <SendPort>[];
  final isolates = <Isolate>[];
  bool shuttingDown = false;

  void tryDispatch() {
    if (shuttingDown) return;
    while (idleWorkers.isNotEmpty && queue.isNotEmpty && (cancelToken?.isCancelled != true)) {
      final worker = idleWorkers.removeLast();
      final job = queue.removeAt(0);
      active++;
      worker.send({'type': 'task', 'file': job});
    }
    if ((queue.isEmpty && active == 0) || cancelToken?.isCancelled == true) {
      shuttingDown = true;
      for (final w in idleWorkers) {
        w.send({'type': 'shutdown'});
      }
      for (final iso in isolates) {
        if (cancelToken?.isCancelled == true) {
          iso.kill(priority: Isolate.immediate);
        }
      }
      receivePort.close();
    }
  }

  for (int i = 0; i < cpuCount; i++) {
    final iso = await Isolate.spawn(_copyWorkerMain, receivePort.sendPort);
    isolates.add(iso);
  }

  await for (final msg in receivePort) {
    if (cancelToken?.isCancelled == true && !shuttingDown) {
      logger.warning('Copy operation cancelled (pool).');
      shuttingDown = true;
      tryDispatch();
      break;
    }
    if (msg is Map) {
      switch (msg['type']) {
        case 'workerReady':
          idleWorkers.add(msg['sendPort'] as SendPort);
          tryDispatch();
          break;
        case 'progress':
          onProgress?.call(ProgressEvent(
            type: ProgressEventType.fileProgress,
            path: msg['dest'] as String?,
            copied: msg['copied'] as int?,
            total: msg['total'] as int?,
            completedFiles: completed,
            totalFiles: totalFiles,
          ));
          break;
        case 'hash':
          final line = msg['line'] as String;
          hashLines.add(line);
          final parts = line.split('  ');
          if (parts.length == 2) {
            final copiedPath = parts[1].trim();
            logger.info('Copied file: $copiedPath');
            copied.add(copiedPath);
          }
          break;
        case 'fileDone':
          completed++;
            active--;
            onProgress?.call(ProgressEvent(
              type: ProgressEventType.fileDone,
              path: msg['dest'] as String?,
              completedFiles: completed,
              totalFiles: totalFiles,
            ));
            onProgress?.call(ProgressEvent(
              type: ProgressEventType.overall,
              completedFiles: completed,
              totalFiles: totalFiles,
            ));
            idleWorkers.add(msg['worker'] as SendPort);
            tryDispatch();
          break;
        case 'error':
          final src = msg['source'] as String? ?? 'unknown';
          logger.severe('Error copying file $src: ${msg['error']}');
          errored.add(src);
          active--;
          idleWorkers.add(msg['worker'] as SendPort);
          tryDispatch();
          break;
      }
    }
  }

  if (cancelToken?.isCancelled == true) {
    if (hashLines.isNotEmpty) {
      final sha1File = File(hashFile);
      await sha1File.writeAsString(hashLines.join(''), mode: FileMode.append);
      logger.info('Partial hashes written to $hashFile');
    }
    if (saveLists) {
      final copiedFile = File(destDir.endsWith('/') ? '${destDir}copied.txt' : '$destDir/copied.txt');
      final erroredFile = File(destDir.endsWith('/') ? '${destDir}errored.txt' : '$destDir/errored.txt');
      await copiedFile.writeAsString(copied.join('\n'));
      await erroredFile.writeAsString(errored.join('\n'));
      logger.info('Partial copied/errored lists written (cancelled).');
    }
    return;
  }
  if (hashLines.isNotEmpty) {
    final sha1File = File(hashFile);
    await sha1File.writeAsString(hashLines.join(''), mode: FileMode.append);
    logger.info('Hashes written to $hashFile');
  }
  if (saveLists) {
    final copiedFile = File(destDir.endsWith('/') ? '${destDir}copied.txt' : '$destDir/copied.txt');
    final erroredFile = File(destDir.endsWith('/') ? '${destDir}errored.txt' : '$destDir/errored.txt');
    if (copied.isNotEmpty) {
      await copiedFile.writeAsString('${copied.join('\n')}\n');
      logger.info('Copied file list written to ${copiedFile.path}');
    } else {
      await copiedFile.writeAsString('');
    }
    if (errored.isNotEmpty) {
      await erroredFile.writeAsString('${errored.join('\n')}\n');
      logger.info('Errored file list written to ${erroredFile.path}');
    } else {
      await erroredFile.writeAsString('');
    }
  }
}

void _copyWorkerMain(SendPort manager) async {
  final commandPort = ReceivePort();
  manager.send({'type': 'workerReady', 'sendPort': commandPort.sendPort});
  await for (final msg in commandPort) {
    if (msg is Map && msg['type'] == 'task') {
      final file = (msg['file'] as Map).cast<String, String>();
      try {
        final source = File(file['source']!);
        final dest = File(file['dest']!);
        final total = await source.length();
        var copiedBytes = 0;
        final out = dest.openWrite();
        final throttle = Stopwatch()..start();
        const updateMs = 100;
        final capture = _DigestCaptureSink();
        final hasher = sha1.startChunkedConversion(capture);
        await for (final chunk in source.openRead()) {
          out.add(chunk);
          hasher.add(chunk);
          copiedBytes += chunk.length;
          if (throttle.elapsedMilliseconds >= updateMs) {
            manager.send({
              'type': 'progress',
              'dest': file['dest'],
              'copied': copiedBytes,
              'total': total,
            });
            throttle.reset();
          }
        }
        await out.close();
        hasher.close();
        final digest = capture.digest!;
        manager.send({'type': 'hash', 'line': '${digest.toString()}  ${file['dest']!}\n'});
        manager.send({'type': 'fileDone', 'dest': file['dest'], 'worker': commandPort.sendPort});
      } catch (e, st) {
        manager.send({
          'type': 'error',
          'source': file['source'],
          'error': e.toString(),
          'stack': st.toString(),
          'worker': commandPort.sendPort,
        });
        manager.send({'type': 'fileDone', 'dest': file['dest'], 'worker': commandPort.sendPort});
      }
    } else if (msg is Map && msg['type'] == 'shutdown') {
      commandPort.close();
      break;
    }
  }
}

// _CopyFileError removed in worker pool refactor (errors sent as maps).

class _DigestCaptureSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

Future<Result<void>> copyFile(
  String sourceFile,
  String destFile,
  String hashFile,
) async {
  try {
    final source = File(sourceFile);
    final dest = File(destFile);
    final List<int> bytes = [];
    final input = source.openRead();
    final output = dest.openWrite();
    await for (final chunk in input) {
      output.add(chunk);
      bytes.addAll(chunk);
    }
    await output.close();
    final digest = sha1.convert(bytes);
    final sha1File = File(hashFile);
    await sha1File.writeAsString(
      '${digest.toString()}  $destFile\n',
      mode: FileMode.append,
    );
    return Result.success(null);
  } catch (e, st) {
    return Result.failure(e, st);
  }
}

Future<void> deleteFile(String filePath) async {
  final file = File(filePath);
  if (await file.exists()) {
    await file.delete();
  }
}

Future<void> deleteDirectory(String dirPath) async {
  final dir = Directory(dirPath);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

class VerifySummary {
  final int total;
  final int ok;
  final int mismatched;
  final int errors;
  final List<String> mismatchedFiles;
  final List<String> errorFiles;
  VerifySummary({
    required this.total,
    required this.ok,
    required this.mismatched,
    required this.errors,
    required this.mismatchedFiles,
    required this.errorFiles,
  });
}

Future<VerifySummary> verifyFromSha1(
  String sha1Path, {
  int? threadCount,
  void Function(ProgressEvent event)? onProgress,
  CancellationToken? cancelToken,
}) async {
  final manifest = File(sha1Path);
  if (!await manifest.exists()) {
    throw ArgumentError('SHA1 file not found: $sha1Path');
  }
  logger.info('Verifying hashes from: $sha1Path');
  final lines = await manifest.readAsLines();
  final entries = <Map<String, String>>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final idx = RegExp(r' {2,}| ').firstMatch(trimmed)?.start ?? -1;
    if (idx <= 0) continue;
    final hash = trimmed.substring(0, idx).trim();
    final path = trimmed.substring(idx + 2).trim();
    if (hash.isEmpty || path.isEmpty) continue;
    entries.add({'hash': hash, 'path': path});
  }
  if (entries.isEmpty) {
    logger.severe('No file entries found in manifest: $sha1Path');
    throw ArgumentError('No file entries found in manifest: $sha1Path');
  }
  final totalFiles = entries.length;
  final cpuCount = threadCount ?? Platform.numberOfProcessors;
  logger.info('Total files to verify: $totalFiles using $cpuCount threads.');
  final receivePort = ReceivePort();
  final queue = List<Map<String, String>>.from(entries);
  onProgress?.call(ProgressEvent(type: ProgressEventType.overall, completedFiles: 0, totalFiles: totalFiles));
  if (queue.isEmpty) {
    return VerifySummary(total: 0, ok: 0, mismatched: 0, errors: 0, mismatchedFiles: const [], errorFiles: const []);
  }
  int completedFiles = 0;
  int okCount = 0;
  int mismatchCount = 0;
  int errorCount = 0;
  int active = 0;
  bool shuttingDown = false;
  final mismatches = <String>[];
  final errors = <String>[];
  final idleWorkers = <SendPort>[];
  final isolates = <Isolate>[];

  void tryDispatch() {
    if (shuttingDown) return;
    while (idleWorkers.isNotEmpty && queue.isNotEmpty && (cancelToken?.isCancelled != true)) {
      final worker = idleWorkers.removeLast();
      final job = queue.removeAt(0);
      active++;
      worker.send({'type': 'task', 'job': job});
    }
    if ((queue.isEmpty && active == 0) || cancelToken?.isCancelled == true) {
      shuttingDown = true;
      for (final w in idleWorkers) {
        w.send({'type': 'shutdown'});
      }
      for (final iso in isolates) {
        if (cancelToken?.isCancelled == true) {
          iso.kill(priority: Isolate.immediate);
        }
      }
      receivePort.close();
    }
  }

  for (int i = 0; i < cpuCount; i++) {
    final iso = await Isolate.spawn(_verifyWorkerMain, receivePort.sendPort);
    isolates.add(iso);
  }

  await for (final msg in receivePort) {
    if (cancelToken?.isCancelled == true && !shuttingDown) {
      logger.warning('Verify operation cancelled (pool).');
      shuttingDown = true;
      tryDispatch();
      break;
    }
    if (msg is Map) {
      switch (msg['type']) {
        case 'workerReady':
          idleWorkers.add(msg['sendPort'] as SendPort);
          tryDispatch();
          break;
        case 'progress':
          onProgress?.call(ProgressEvent(
            type: ProgressEventType.fileProgress,
            path: msg['path'] as String?,
            copied: msg['copied'] as int?,
            total: msg['total'] as int?,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
          ));
          break;
        case 'verified':
          final ok = msg['ok'] as bool? ?? false;
          final path = msg['path'] as String? ?? '';
          if (ok) {
            okCount++;
          } else {
            mismatchCount++;
            mismatches.add(path);
            logger.warning('Hash mismatch: ${msg['expected']} != ${msg['actual']} for $path');
          }
          break;
        case 'error':
          final path = msg['path'] as String? ?? '';
          errors.add(path);
          errorCount++;
          logger.severe('Error verifying $path: ${msg['error']}');
          break;
        case 'fileDone':
          completedFiles++;
          active--;
          onProgress?.call(ProgressEvent(
            type: ProgressEventType.fileDone,
            path: msg['path'] as String?,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
          ));
          onProgress?.call(ProgressEvent(
            type: ProgressEventType.overall,
            completedFiles: completedFiles,
            totalFiles: totalFiles,
          ));
          idleWorkers.add(msg['worker'] as SendPort);
          tryDispatch();
          break;
      }
    }
  }
  final summary = VerifySummary(
    total: totalFiles,
    ok: okCount,
    mismatched: mismatchCount,
    errors: errorCount,
    mismatchedFiles: mismatches,
    errorFiles: errors,
  );
  if (cancelToken?.isCancelled == true) {
    return summary;
  }
  logger.info('Verify complete: ${summary.ok}/${summary.total} OK, ${summary.mismatched} mismatched, ${summary.errors} errors.');
  return summary;
}

void _verifyWorkerMain(SendPort manager) async {
  final commandPort = ReceivePort();
  manager.send({'type': 'workerReady', 'sendPort': commandPort.sendPort});
  await for (final msg in commandPort) {
    if (msg is Map && msg['type'] == 'task') {
      final job = (msg['job'] as Map).cast<String, String>();
      final path = job['path']!;
      final expected = job['hash']!;
      try {
        final f = File(path);
        final total = await f.length();
        var read = 0;
        final capture = _DigestCaptureSink();
        final hasher = sha1.startChunkedConversion(capture);
        final throttle = Stopwatch()..start();
        const updateMs = 100;
        await for (final chunk in f.openRead()) {
          hasher.add(chunk);
          read += chunk.length;
          if (throttle.elapsedMilliseconds >= updateMs) {
            manager.send({'type': 'progress', 'path': path, 'copied': read, 'total': total});
            throttle.reset();
          }
        }
        hasher.close();
        final actual = capture.digest!.toString();
        manager.send({'type': 'verified', 'path': path, 'ok': actual == expected, 'expected': expected, 'actual': actual});
        manager.send({'type': 'fileDone', 'path': path, 'worker': commandPort.sendPort});
      } catch (e) {
        manager.send({'type': 'error', 'path': path, 'error': e.toString(), 'worker': commandPort.sendPort});
        manager.send({'type': 'fileDone', 'path': path, 'worker': commandPort.sendPort});
      }
    } else if (msg is Map && msg['type'] == 'shutdown') {
      commandPort.close();
      break;
    }
  }
}
