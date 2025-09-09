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
  final hashFile = destDir.endsWith('/')
      ? '${destDir}hashes.sha1'
      : '$destDir/hashes.sha1';
  await deleteFile(hashFile);
  logger.info('Copying files from list: $listFile to $destDir');
  final files = <Map<String, String>>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (await FileSystemEntity.isDirectory(trimmed)) continue;
    final relPath = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
    final destPath = destDir.endsWith('/')
        ? '$destDir$relPath'
        : '$destDir/$relPath';
    await Directory(
      destPath.substring(0, destPath.lastIndexOf('/')),
    ).create(recursive: true);
    files.add({'source': trimmed, 'dest': destPath});
  }
  final cpuCount = threadCount ?? Platform.numberOfProcessors;
  final fileQueue = List<Map<String, String>>.from(files);
  final totalFiles = fileQueue.length;
  logger.info('Total files to copy: $totalFiles using $cpuCount threads.');
  final hashLines = <String>[];
  final receivePort = ReceivePort();
  final copied = <String>[];
  final errored = <String>[];
  int completedFiles = 0;
  int active = 0;
  bool done = false;
  // Notify initial overall state
  onProgress?.call(
    ProgressEvent(
      type: ProgressEventType.overall,
      completedFiles: 0,
      totalFiles: totalFiles,
    ),
  );

  final isolates = <Isolate>[];

  void startNext() {
    if (cancelToken?.isCancelled == true) return;
    if (fileQueue.isEmpty) {
      if (active == 0 && !done) {
        done = true;
        receivePort.close();
      }
      return;
    }
    final file = fileQueue.removeAt(0);
    active++;
    Isolate.spawn(_copyFileEntrySingleWriter, [file, receivePort.sendPort])
        .then((iso) {
      isolates.add(iso);
      if (cancelToken?.isCancelled == true) {
        iso.kill(priority: Isolate.immediate);
      }
    });
  }

  for (int i = 0; i < cpuCount && fileQueue.isNotEmpty; i++) {
    startNext();
  }
  await for (final msg in receivePort) {
    if (cancelToken?.isCancelled == true) {
      // Kill any remaining isolates and stop spawning.
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
      logger.warning('Copy operation cancelled.');
      done = true;
      receivePort.close();
      break;
    }
    if (msg is Map && msg['type'] == 'done') {
      final dest = (msg['dest'] ?? '') as String;
      completedFiles++;
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.fileDone,
          path: dest,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.overall,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
      active--;
      if (cancelToken?.isCancelled != true) startNext();
      if (fileQueue.isEmpty && active == 0 && !done) {
        done = true;
        receivePort.close();
      }
    } else if (msg == 'done') {
      completedFiles++;
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.overall,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
      active--;
      if (cancelToken?.isCancelled != true) startNext();
      if (fileQueue.isEmpty && active == 0 && !done) {
        done = true;
        receivePort.close();
      }
    } else if (msg is String) {
      hashLines.add(msg);
      final parts = msg.split('  ');
      if (parts.length == 2) {
        final copiedPath = parts[1].trim();
        logger.info('Copied file: $copiedPath');
        copied.add(copiedPath);
      }
    } else if (msg is Map && msg['type'] == 'progress') {
      final dest = (msg['dest'] ?? '') as String;
      final copiedNow = (msg['copied'] ?? 0) as int;
      final total = (msg['total'] ?? 0) as int;
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.fileProgress,
          path: dest,
          copied: copiedNow,
          total: total,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
    } else if (msg is _CopyFileError) {
      logger.severe('Error copying file ${msg.file['source']}: ${msg.error}');
      errored.add(msg.file['source'] ?? '');
    }
  }
  if (cancelToken?.isCancelled == true) {
    // Write partial results if any, then return early.
    if (hashLines.isNotEmpty) {
      final sha1File = File(hashFile);
      await sha1File.writeAsString(hashLines.join(''), mode: FileMode.append);
      logger.info('Partial hashes written to $hashFile');
    }
    if (saveLists) {
      final copiedFile = File(
        destDir.endsWith('/') ? '${destDir}copied.txt' : '$destDir/copied.txt',
      );
      final erroredFile = File(
        destDir.endsWith('/') ? '${destDir}errored.txt' : '$destDir/errored.txt',
      );
      await copiedFile.writeAsString(copied.join('\n'));
      await erroredFile.writeAsString(errored.join('\n'));
      logger.info('Partial copied/errored lists written (cancelled).');
    }
    return; // Cancelled: skip normal completion log
  }
  if (hashLines.isNotEmpty) {
    final sha1File = File(hashFile);
    await sha1File.writeAsString(hashLines.join(''), mode: FileMode.append);
    logger.info('Hashes written to $hashFile');
  }
  if (saveLists) {
    final copiedFile = File(
      destDir.endsWith('/') ? '${destDir}copied.txt' : '$destDir/copied.txt',
    );
    final erroredFile = File(
      destDir.endsWith('/') ? '${destDir}errored.txt' : '$destDir/errored.txt',
    );
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

void _copyFileEntrySingleWriter(List args) async {
  final Map<String, String> file = args[0];
  final SendPort sendPort = args[1];
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
        sendPort.send({
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
    final hashLine = '${digest.toString()}  ${file['dest']!}\n';
    sendPort.send(hashLine);
  } catch (e, st) {
    sendPort.send(_CopyFileError(error: e, stackTrace: st, file: file));
  } finally {
    sendPort.send({'type': 'done', 'dest': file['dest']});
  }
}

class _CopyFileError {
  final Object error;
  final StackTrace stackTrace;
  final Map<String, String> file;
  _CopyFileError({
    required this.error,
    required this.stackTrace,
    required this.file,
  });
}

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
  int completedFiles = 0;
  onProgress?.call(
    ProgressEvent(
      type: ProgressEventType.overall,
      completedFiles: 0,
      totalFiles: totalFiles,
    ),
  );
  int active = 0;
  int okCount = 0;
  int mismatchCount = 0;
  int errorCount = 0;
  final mismatches = <String>[];
  final errors = <String>[];
  // Throttling previously used for rendering; no longer needed in core.
  final isolates = <Isolate>[];
  void startNext() {
    if (cancelToken?.isCancelled == true) return;
    if (queue.isEmpty) return;
    final job = queue.removeAt(0);
    active++;
    Isolate.spawn(_verifyFileEntry, [job, receivePort.sendPort]).then((iso) {
      isolates.add(iso);
      if (cancelToken?.isCancelled == true) {
        iso.kill(priority: Isolate.immediate);
      }
    });
  }

  for (int i = 0; i < cpuCount && queue.isNotEmpty; i++) {
    startNext();
  }
  await for (final msg in receivePort) {
    if (cancelToken?.isCancelled == true) {
      for (final iso in isolates) {
        iso.kill(priority: Isolate.immediate);
      }
      logger.warning('Verify operation cancelled.');
      receivePort.close();
      break;
    }
    if (msg is Map && msg['type'] == 'progress') {
      final path = (msg['path'] ?? '') as String;
      final copiedNow = (msg['copied'] ?? 0) as int;
      final total = (msg['total'] ?? 0) as int;
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.fileProgress,
          path: path,
          copied: copiedNow,
          total: total,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
    } else if (msg is Map && msg['type'] == 'verified') {
      final ok = (msg['ok'] ?? false) as bool;
      final path = (msg['path'] ?? '') as String;
      if (ok) {
        okCount++;
      } else {
        mismatchCount++;
        mismatches.add(path);
        logger.warning(
          'Hash mismatch: ${msg['expected']} != ${msg['actual']} for $path',
        );
      }
    } else if (msg is Map && msg['type'] == 'error') {
      errorCount++;
      final path = (msg['path'] ?? '') as String;
      final err = (msg['error'] ?? 'unknown error').toString();
      errors.add(path);
      logger.severe('Error verifying $path: $err');
    } else if (msg is Map && msg['type'] == 'done') {
      final path = (msg['path'] ?? msg['dest'] ?? '') as String;
      completedFiles++;
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.fileDone,
          path: path,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
      onProgress?.call(
        ProgressEvent(
          type: ProgressEventType.overall,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
        ),
      );
      active--;
      if (cancelToken?.isCancelled != true) startNext();
      if (queue.isEmpty && active == 0) {
        receivePort.close();
      }
    }
  }
  if (cancelToken?.isCancelled == true) {
    // Return partial summary
    final summary = VerifySummary(
      total: totalFiles,
      ok: okCount,
      mismatched: mismatchCount,
      errors: errorCount,
      mismatchedFiles: mismatches,
      errorFiles: errors,
    );
    return summary;
  }
  final summary = VerifySummary(
    total: totalFiles,
    ok: okCount,
    mismatched: mismatchCount,
    errors: errorCount,
    mismatchedFiles: mismatches,
    errorFiles: errors,
  );
  logger.info(
    'Verify complete: ${summary.ok}/${summary.total} OK, ${summary.mismatched} mismatched, ${summary.errors} errors.',
  );
  return summary;
}

void _verifyFileEntry(List args) async {
  final Map<String, String> job = args[0];
  final SendPort sendPort = args[1];
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
        sendPort.send({
          'type': 'progress',
          'path': path,
          'copied': read,
          'total': total,
        });
        throttle.reset();
      }
    }
    hasher.close();
    final actual = capture.digest!.toString();
    sendPort.send({
      'type': 'verified',
      'path': path,
      'ok': actual == expected,
      'expected': expected,
      'actual': actual,
    });
  } catch (e) {
    sendPort.send({'type': 'error', 'path': path, 'error': e.toString()});
  } finally {
    sendPort.send({'type': 'done', 'path': path});
  }
}
