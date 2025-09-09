import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:ciphercopy_core/core.dart' as core;
import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const CipherCopyApp());
}

class CipherCopyApp extends StatelessWidget {
  const CipherCopyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CiPHERCOPY',
      theme: ThemeData(primarySwatch: Colors.lightGreen),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: ThemeMode.system,
      home: const CipherCopySteps(),
    );
  }
}

enum OperationType { verify, copy }

class CipherCopySteps extends StatefulWidget {
  const CipherCopySteps({super.key});

  @override
  State<CipherCopySteps> createState() => _CipherCopyStepsState();
}

class _CipherCopyStepsState extends State<CipherCopySteps> {
  int _step = 0;
  OperationType? _operation;
  String? _sha1File;
  String? _fileList;
  String? _destDir;
  bool _saveLists = false;
  int _threadCount = Platform.numberOfProcessors - 1; // Adjustable thread count
  double _progress = 0;
  // Track active file progress (currently copying / verifying) only.
  final Map<String, _ActiveFileProgress> _activeFiles = {};
  int _overallCompleted = 0;
  int _overallTotal = 0;
  String? _statusMessage;
  String? _logPath;
  bool _isRunning = false;
  bool _cancelRequested = false;
  core.CancellationToken? _cancellationToken;
  StreamController<String>? _logController;

  @override
  void dispose() {
    _logController?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleTextStyle: TextStyle(
          fontFamily: "monospace",
          fontFamilyFallback: const <String>["Courier", "Courier New"],
          color: colorScheme.primary,
          fontSize: 48,
        ),
        title: const Text('CiPHERCOPY'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
            onPressed: _isRunning ? null : _resetAll,
          ),
        ],
      ),
      body: Stepper(
        currentStep: _step,
        onStepContinue: _nextStep,
        onStepCancel: _prevStep,
        steps: [
          Step(
            title: const Text('Select an Operation'),
            content: Column(
              children: [
                RadioListTile<OperationType>(
                  title: const Text('Verify existing hashes'),
                  value: OperationType.verify,
                  groupValue: _operation,
                  onChanged: (val) => setState(() => _operation = val),
                ),
                RadioListTile<OperationType>(
                  title: const Text('Copy using a file list'),
                  value: OperationType.copy,
                  groupValue: _operation,
                  onChanged: (val) => setState(() => _operation = val),
                ),
              ],
            ),
            isActive: _step == 0,
          ),
          Step(
            title: const Text('Options'),
            content: _operation == OperationType.verify
                ? _buildVerifyInputs()
                : _buildCopyInputs(),
            isActive: _step == 1,
          ),
          Step(
            title: const Text('Progress'),
            content: _buildProgress(),
            isActive: _step == 2,
          ),
        ],
        controlsBuilder: (context, details) {
          return Row(
            children: <Widget>[
              if (_step < 2)
                ElevatedButton(
                  onPressed: details.onStepContinue,
                  child: const Text('Next'),
                ),
              // Disable Back button on final progress step
              if (_step > 0 && _step < 2)
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVerifyInputs() {
    TextStyle? errorTextStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error);
    return Column(
      children: [
        ListTile(
          title: Text('Select .sha1 file'),
          subtitle: _sha1File == null
              ? Text('Required', style: errorTextStyle)
              : Text(_sha1File!),
          trailing: const Icon(Icons.attach_file),
          onTap: () async {
            final typeGroup = XTypeGroup(label: 'SHA1', extensions: ['sha1']);
            final file = await openFile(acceptedTypeGroups: [typeGroup]);
            if (file != null) {
              setState(() => _sha1File = file.path);
            }
          },
        ),
        _buildThreadControl(),
        _buildSaveListsSwitch(),
      ],
    );
  }

  Widget _buildCopyInputs() {
    return Column(
      children: [
        ListTile(
          title: Text(_fileList ?? 'Select file list'),
          trailing: const Icon(Icons.attach_file),
          onTap: () async {
            final file = await openFile();
            if (file != null) {
              setState(() => _fileList = file.path);
            }
          },
        ),
        ListTile(
          title: Text(_destDir ?? 'Select destination directory'),
          trailing: const Icon(Icons.folder),
          onTap: () async {
            final dir = await getDirectoryPath();
            if (dir != null) {
              setState(() => _destDir = dir);
            }
          },
        ),
        _buildThreadControl(),
        _buildSaveListsSwitch(),
      ],
    );
  }

  Widget _buildThreadControl() {
    const minThreads = 1;
    final maxThreads = (Platform.numberOfProcessors).clamp(
      4,
      128,
    ); // generous upper bound
    return ListTile(
      title: const Text('Threads'),
      subtitle: Text('Reduce if I/O is the bottleneck'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Decrease',
            icon: const Icon(Icons.remove),
            onPressed: _threadCount > minThreads
                ? () => setState(
                    () => _threadCount = (_threadCount - 1).clamp(
                      minThreads,
                      maxThreads,
                    ),
                  )
                : null,
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$_threadCount',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Increase',
            icon: const Icon(Icons.add),
            onPressed: _threadCount < maxThreads
                ? () => setState(
                    () => _threadCount = (_threadCount + 1).clamp(
                      minThreads,
                      maxThreads,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSaveListsSwitch() {
    return SwitchListTile(
      title: const Text('Save copied and errored file lists'),
      value: _saveLists,
      onChanged: (val) => setState(() => _saveLists = val),
    );
  }

  Widget _buildProgress() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_operation == OperationType.verify && _sha1File != null)
          Text('Verifying: $_sha1File'),
        if (_operation == OperationType.copy &&
            _fileList != null &&
            _destDir != null)
          Text('Copying from list: $_fileList to $_destDir'),
        if (_saveLists && _operation == OperationType.copy)
          const Text('Saving copied/errored file lists'),
        const SizedBox(height: 16),
        if (_isRunning)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_activeFiles.isNotEmpty)
                ..._activeFiles.values.map((fp) => _FileProgressBar(fp: fp)),
              if (_activeFiles.isEmpty)
                Text(
                  _overallTotal > 0
                      ? 'Processing ($_overallCompleted / $_overallTotal)...'
                      : 'Starting...',
                ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _overallTotal == 0 ? null : _progress,
              ),
              const SizedBox(height: 4),
              Text('Overall: $_overallCompleted / $_overallTotal'),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _cancelRequested ? null : _cancelOperation,
                    icon: const Icon(Icons.stop),
                    label: Text(_cancelRequested ? 'Cancelling…' : 'Cancel'),
                  ),
                ],
              ),
            ],
          ),
        if (!_isRunning)
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _startOperation,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              ElevatedButton.icon(
                onPressed: _resetAll,
                icon: const Icon(Icons.refresh),
                label: const Text('Reset'),
              ),
            ],
          ),
        if (_statusMessage != null) ...[
          const SizedBox(height: 12),
          Text(_statusMessage!),
        ],
        if (_logPath != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Log: '),
                ),
              ),
              Expanded(
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: _openLogFile,
                  child: Text(_logPath!, overflow: TextOverflow.ellipsis),
                ),
              ),
              Tooltip(
                message: 'Copy path',
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: _copyLogPath,
                ),
              ),
              Tooltip(
                message: Platform.isMacOS
                    ? 'Reveal in Finder'
                    : 'Show in Folder',
                child: IconButton(
                  icon: const Icon(Icons.folder_open, size: 18),
                  onPressed: _revealLogFile,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _nextStep() {
    if (_step == 0 && _operation != null) {
      setState(() => _step++);
    } else if (_step == 1) {
      // Validate required fields
      if ((_operation == OperationType.verify && _sha1File != null) ||
          (_operation == OperationType.copy &&
              _fileList != null &&
              _destDir != null)) {
        setState(() => _step++);
      }
    }
  }

  void _prevStep() {
    if (_step > 0) setState(() => _step--);
  }

  void _startOperation() async {
    setState(() {
      _isRunning = true;
      _progress = 0;
      _activeFiles.clear();
      _overallCompleted = 0;
      _overallTotal = 0;
      _statusMessage = null;
      _cancelRequested = false;
      _cancellationToken = core.CancellationToken();
    });
    try {
      // Determine a base directory (used for resolving relative paths and logging)
      final baseDir = _operation == OperationType.verify
          ? File(_sha1File!).parent.path
          : (_destDir ?? Directory.current.path);
      final previousCwd = Directory.current;
      Directory.current =
          baseDir; // so relative paths in manifests/lists resolve
      try {
        // Initialize logging (log file will be created under current working directory)
        _logPath = await core.initLogging(baseDir);
        if (_operation == OperationType.verify) {
          core.logger.info('Starting verify from manifest: $_sha1File');
        } else {
          core.logger.info('Starting copy from list: $_fileList -> $_destDir');
        }
      } finally {
        // Restore current directory for rest of UI code
        Directory.current = previousCwd;
      }

      void onProgress(core.ProgressEvent e) {
        if (!mounted) return;
        if (_cancelRequested) return; // Stop updating UI after cancel request
        setState(() {
          switch (e.type) {
            case core.ProgressEventType.fileProgress:
              final path = e.path ?? '';
              if (path.isNotEmpty) {
                _activeFiles[path] = _ActiveFileProgress(
                  path: path,
                  copied: e.copied ?? 0,
                  total: (e.total ?? 0),
                );
              }
              break;
            case core.ProgressEventType.fileDone:
              if (e.path != null) {
                _activeFiles.remove(e.path);
              }
              _overallCompleted = e.completedFiles ?? _overallCompleted;
              _overallTotal = e.totalFiles ?? _overallTotal;
              _progress = _overallTotal == 0
                  ? 0
                  : (_overallCompleted / _overallTotal).clamp(0, 1);
              break;
            case core.ProgressEventType.overall:
              _overallCompleted = e.completedFiles ?? _overallCompleted;
              _overallTotal = e.totalFiles ?? _overallTotal;
              _progress = _overallTotal == 0
                  ? 0
                  : (_overallCompleted / _overallTotal).clamp(0, 1);
              break;
          }
        });
      }

      if (_operation == OperationType.verify) {
        // Run verify with working directory set so relative paths resolve
        final prev = Directory.current;
        Directory.current = File(_sha1File!).parent;
        final summary = await core.verifyFromSha1(
          _sha1File!,
          threadCount: _threadCount,
          onProgress: onProgress,
          cancelToken: _cancellationToken,
        );
        Directory.current = prev;
        core.logger.info(
          'Verify complete: ${summary.ok}/${summary.total} OK, ${summary.mismatched} mismatched, ${summary.errors} errors.',
        );
        setState(() {
          _statusMessage = _cancelRequested
              ? 'Cancelled.'
              : 'Verify complete: ${summary.ok}/${summary.total} OK, ${summary.mismatched} mismatched, ${summary.errors} errors.';
        });
      } else {
        // Set current directory to list file parent for relative sources
        final prev = Directory.current;
        Directory.current = File(_fileList!).parent;
        await core.copyFilesFromList(
          _fileList!,
          _destDir!,
          threadCount: _threadCount,
          saveLists: _saveLists,
          onProgress: onProgress,
          cancelToken: _cancellationToken,
        );
        Directory.current = prev;
        core.logger.info('Copy complete.');
        setState(() {
          _statusMessage = _cancelRequested ? 'Cancelled.' : 'Copy complete.';
        });
      }
    } catch (err, st) {
      core.logger.severe('Error: $err', err, st);
      setState(() {
        _statusMessage = 'Error: $err';
      });
      if (mounted) {
        // Show error in a SnackBar as requested
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $err'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () {},
            ),
          ),
        );
      }
    } finally {
      await core.shutdownLogging();
      // Copy log file to target (same logic as CLI)
      if (_logPath != null) {
        try {
          final fileName = _logPath!.substring(
            _logPath!.lastIndexOf(Platform.pathSeparator) + 1,
          );
          final targetDir = _operation == OperationType.verify
              ? File(_sha1File!).parent.path
              : _destDir!;
          final destLog = targetDir + Platform.pathSeparator + fileName;
          await Directory(targetDir).create(recursive: true);
          await File(_logPath!).copy(destLog);
        } catch (_) {
          // Ignore UI-level log copy errors.
        }
      }
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  void _cancelOperation() {
    if (!_isRunning) return;
    setState(() {
      _cancelRequested = true;
      _statusMessage = 'Cancelling…';
    });
    _cancellationToken?.cancel();
  }

  void _resetAll() {
    setState(() {
      _step = 0;
      _operation = null;
      _sha1File = null;
      _fileList = null;
      _destDir = null;
      _saveLists = false;
      _progress = 0;
      _activeFiles.clear();
      _overallCompleted = 0;
      _overallTotal = 0;
      _statusMessage = null;
      _logPath = null;
      _isRunning = false;
      _cancelRequested = false;
      _cancellationToken = null;
    });
  }

  Future<void> _openLogFile() async {
    final lp = _logPath;
    if (lp == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [lp]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [lp]);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', lp]);
      } else {
        // Fallback: no-op
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open log: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _copyLogPath() async {
    final lp = _logPath;
    if (lp == null) return;
    await Clipboard.setData(ClipboardData(text: lp));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Log path copied to clipboard')),
      );
    }
  }

  Future<void> _revealLogFile() async {
    final lp = _logPath;
    if (lp == null) return;
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', lp]);
      } else if (Platform.isLinux) {
        // Best effort: open the directory containing the log
        final dir = File(lp).parent.path;
        await Process.run('xdg-open', [dir]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,"$lp"']);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reveal log: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}

class _ActiveFileProgress {
  final String path;
  final int copied;
  final int total;
  _ActiveFileProgress({
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

class _FileProgressBar extends StatelessWidget {
  final _ActiveFileProgress fp;
  const _FileProgressBar({required this.fp});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fp.name),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: fp.ratio),
        ],
      ),
    );
  }
}
