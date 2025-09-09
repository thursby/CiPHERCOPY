import 'dart:io';
import 'package:ansicolor/ansicolor.dart';
import 'package:args/args.dart';
import 'package:ciphercopy_core/core.dart' as core;
import 'package:path/path.dart' as path;

String logo =
    '  ______ ___  __ _________  ________  _____  __\n'
    ' ╱ ___(_) _ ╲╱ ╱╱ ╱ __╱ _ ╲╱ ___╱ _ ╲╱ _ ╲ ╲╱ ╱\n'
    '╱ ╱__╱ ╱ ___╱ _  ╱ _╱╱ , _╱ ╱__╱ (/ ╱ ___╱╲  ╱ \n'
    '╲___╱_╱_╱  ╱_╱╱_╱___╱_╱│_│╲___╱╲___╱_╱    ╱_╱  \n'
    'CiPHERC0PY\n';

void main(List<String> arguments) async {
  final redPen = AnsiPen()..red(bold: true);
  final greenPen = AnsiPen()..green(bold: true);
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    )
    ..addFlag(
      'verify',
      abbr: 'v',
      negatable: false,
      help: 'Verify files from a .sha1 manifest instead of copying.',
    )
    ..addOption(
      'threads',
      abbr: 't',
      help:
          'Number of concurrent threads to use. Default: number of CPU cores.',
      valueHelp: 'count',
    )
    ..addFlag(
      'list',
      abbr: 'l',
      negatable: false,
      help:
          'Also save lists of copied and errored files in the destination directory.',
    );

  ArgResults argResults;
  var exitCodeToUse = 0;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    print(redPen('Argument error: $e'));
    print('');
    print('Usage:');
    print(parser.usage);
    exit(64); // EX_USAGE
  }

  if (argResults['help'] as bool) {
    print(
      '${logo}Copy files listed in a file to a destination directory, preserving paths. While files are being copied, their SHA-1 hashes are computed and written to a .sha1 file in the destination directory.',
    );
    print('');
    print('Usage:');
    print(
      '  Copy   : dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>',
    );
    print('  Verify : dart run bin/ciphercopy_cli.dart --verify <hashes.sha1>');
    print(parser.usage);
    exit(0);
  }

  final rest = argResults.rest;
  final verifyMode = argResults['verify'] as bool;
  String logPath;
  String? destDir;
  String? listFile;
  String? sha1File;
  if (verifyMode) {
    if (rest.length != 1) {
      print(
        redPen('Error: --verify requires exactly one argument: <hashes.sha1>.'),
      );
      print('');
      print('Usage: dart run bin/ciphercopy_cli.dart --verify <hashes.sha1>');
      print(parser.usage);
      exit(64);
    }
    sha1File = rest[0];
    // Initialize logging using the manifest's parent directory name
    final parent = File(sha1File).parent.path;
    logPath = await core.initLogging(parent);
  } else {
    if (rest.length != 2) {
      print(redPen('Error: Missing required arguments.'));
      print('');
      print(
        'Usage: dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>',
      );
      print(parser.usage);
      exit(64); // EX_USAGE
    }
    listFile = rest[0];
    destDir = rest[1];
    logPath = await core.initLogging(destDir);
  }
  final saveLists = argResults['list'] as bool;
  int? threadCount;
  if (argResults.wasParsed('threads')) {
    final threadStr = argResults['threads'] as String?;
    if (threadStr != null && threadStr.isNotEmpty) {
      final parsed = int.tryParse(threadStr);
      if (parsed == null || parsed < 1) {
        print(redPen('Error: --threads must be a positive integer.'));
        exit(64);
      }
      threadCount = parsed;
    }
  }

  try {
    // Simple in-CLI progress renderer collecting per-file stats.
    final renderer = _CliProgressRenderer();
    if (verifyMode) {
      core.logger.info(
        'Starting verify from manifest: $sha1File using $threadCount threads.',
      );
      final summary = await core.verifyFromSha1(
        sha1File!,
        threadCount: threadCount,
        onProgress: renderer.onEvent,
      );
      final msg =
          'Verify complete: ${summary.ok}/${summary.total} OK, ${summary.mismatched} mismatched, ${summary.errors} errors.';
      core.logger.info(msg);
      if (summary.mismatched == 0 && summary.errors == 0) {
        print(greenPen('\n$msg'));
      } else {
        print(redPen(msg));
        exitCodeToUse = 2;
      }
    } else {
      core.logger.info(
        'Starting copy from list: $listFile to $destDir using $threadCount threads.',
      );
      await core.copyFilesFromList(
        listFile!,
        destDir!,
        threadCount: threadCount,
        saveLists: saveLists,
        onProgress: renderer.onEvent,
      );
      core.logger.info('Files copied and hashes written successfully.');
      print(greenPen('\nFiles copied and hashes written successfully.'));
    }
  } catch (error, stackTrace) {
    core.logger.severe('Error: $error', error, stackTrace);
    print(redPen('Error: $error\n$stackTrace'));
    exitCodeToUse = 2;
  } finally {
    await core.shutdownLogging();
    print('Log written to: $logPath');
    // Also copy the log into the destination directory
    try {
      // If in verify mode, copy the log alongside the manifest; else copy to dest dir
      final targetDir = verifyMode ? File(sha1File!).parent.path : destDir!;
      await Directory(targetDir).create(recursive: true);
      final destLogPath = path.join(targetDir, path.basename(logPath));
      await File(logPath).copy(destLogPath);
      print('Log copied to: $destLogPath');
    } catch (e) {
      print(redPen('Warning: failed to copy log to destination: $e'));
    }
  }
  exit(exitCodeToUse);
}

class _CliProgressRenderer {
  final Map<String, _FileProgress> _files = {};
  int _overallCompleted = 0;
  int _overallTotal = 0;
  int _renderedLines = 0;
  bool _cursorHidden = false;
  final Stopwatch _throttle = Stopwatch()..start();
  static const int _minUpdateMs = 125;

  void onEvent(core.ProgressEvent event) {
    switch (event.type) {
      case core.ProgressEventType.overall:
        _overallCompleted = event.completedFiles ?? _overallCompleted;
        _overallTotal = event.totalFiles ?? _overallTotal;
        _maybeRender(force: true);
        break;
      case core.ProgressEventType.fileProgress:
        final path = event.path ?? '';
        _files[path] = _FileProgress(
          copied: event.copied ?? 0,
          total: event.total ?? 0,
          name: path,
        );
        _maybeRender();
        break;
      case core.ProgressEventType.fileDone:
        if (event.path != null) {
          _files.remove(event.path);
        }
        _maybeRender(force: true);
        break;
    }
  }

  void _maybeRender({bool force = false}) {
    if (!force && _throttle.elapsedMilliseconds < _minUpdateMs) return;
    _throttle.reset();
    _render();
  }

  void _render() {
    if (_renderedLines > 0) {
      stdout.write('\u001B[${_renderedLines}A');
    }
    if (!_cursorHidden) {
      stdout.write('\u001B[?25l');
      _cursorHidden = true;
    }
    final lines = <String>[];
    final keys = _files.keys.toList()..sort();
    for (final k in keys) {
      lines.add(_formatFile(_files[k]!));
    }
    lines.add(_formatOverall());
    for (var i = 0; i < _renderedLines; i++) {
      stdout.writeln('\u001B[2K');
    }
    for (final l in lines) {
      stdout.writeln(l);
    }
    _renderedLines = lines.length;
    if (_files.isEmpty && _overallCompleted == _overallTotal) {
      _showCursor();
    }
  }

  String _formatFile(_FileProgress fp) {
    final width = 28;
    final total = fp.total == 0 ? 1 : fp.total;
    final ratio = (fp.copied / total).clamp(0, 1);
    final filled = (ratio * width).round();
    final bar = '${'█' * filled}${'.' * (width - filled)}';
    final pct = (ratio * 100).toStringAsFixed(1).padLeft(5);
    final name = _basename(fp.name);
    return '$name : $bar ${_human(fp.copied)}/${_human(total)} $pct%';
  }

  String _formatOverall() {
    final width = 28;
    final total = _overallTotal == 0 ? 1 : _overallTotal;
    final ratio = (_overallCompleted / total).clamp(0, 1);
    final filled = (ratio * width).round();
    final bar = '${'█' * filled}${'.' * (width - filled)}';
    final pct = (ratio * 100).toStringAsFixed(1).padLeft(5);
    return 'Overall: $bar  $_overallCompleted/$_overallTotal $pct%';
  }

  String _basename(String p) {
    final idx = p.lastIndexOf('/');
    return idx >= 0 ? p.substring(idx + 1) : p;
  }

  String _human(int n) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = n.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return (u == 0 ? n.toString() : v.toStringAsFixed(1)) + units[u];
  }

  void _showCursor() {
    if (_cursorHidden) {
      stdout.write('\u001B[?25h');
      _cursorHidden = false;
    }
  }
}

class _FileProgress {
  final int copied;
  final int total;
  final String name;
  _FileProgress({
    required this.copied,
    required this.total,
    required this.name,
  });
}
