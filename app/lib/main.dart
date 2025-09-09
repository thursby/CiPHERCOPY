
import 'package:flutter/material.dart';
import 'package:ciphercopy_core/core.dart' as core;
import 'dart:async';
import 'package:file_selector/file_selector.dart';

void main() {
  runApp(const CipherCopyApp());
}

class CipherCopyApp extends StatelessWidget {
  const CipherCopyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CipherCopy Wizard',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const CipherCopyWizard(),
    );
  }
}

enum OperationType { verify, copy }

class CipherCopyWizard extends StatefulWidget {
  const CipherCopyWizard({super.key});

  @override
  State<CipherCopyWizard> createState() => _CipherCopyWizardState();
}

class _CipherCopyWizardState extends State<CipherCopyWizard> {
  int _step = 0;
  OperationType? _operation;
  String? _sha1File;
  String? _fileList;
  String? _destDir;
  bool _saveLists = false;
  double _progress = 0;
  double _fileProgress = 0;
  String? _currentFile;
  bool _isRunning = false;
  StreamController<String>? _logController;

  @override
  void dispose() {
    _logController?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CipherCopy Wizard')),
      body: Stepper(
        currentStep: _step,
        onStepContinue: _nextStep,
        onStepCancel: _prevStep,
        steps: [
          Step(
            title: const Text('Select Operation'),
            content: Column(
              children: [
                RadioListTile<OperationType>(
                  title: const Text('Verify existing hashes'),
                  value: OperationType.verify,
                  groupValue: _operation,
                  onChanged: (val) => setState(() => _operation = val),
                ),
                RadioListTile<OperationType>(
                  title: const Text('Copy using file list'),
                  value: OperationType.copy,
                  groupValue: _operation,
                  onChanged: (val) => setState(() => _operation = val),
                ),
              ],
            ),
            isActive: _step == 0,
          ),
          Step(
            title: const Text('Select Requirements'),
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
              if (_step > 0)
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
    return Column(
      children: [
        ListTile(
          title: Text(_sha1File ?? 'Select .sha1 file'),
          trailing: const Icon(Icons.attach_file),
          onTap: () async {
            final typeGroup = XTypeGroup(label: 'SHA1', extensions: ['sha1']);
            final file = await openFile(acceptedTypeGroups: [typeGroup]);
            if (file != null) {
              setState(() => _sha1File = file.path);
            }
          },
        ),
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
        _buildSaveListsSwitch(),
      ],
    );
  }

  Widget _buildSaveListsSwitch() {
    return SwitchListTile(
      title: const Text('Save copied/errored file lists (-l)'),
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
        if (_operation == OperationType.copy && _fileList != null && _destDir != null)
          Text('Copying from list: $_fileList to $_destDir'),
  if (_saveLists) const Text('Saving copied/errored file lists'),
        const SizedBox(height: 16),
        if (_isRunning)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_currentFile != null) Text('Current file: $_currentFile'),
              LinearProgressIndicator(value: _fileProgress),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              const Text('Overall progress'),
            ],
          ),
        if (!_isRunning)
          ElevatedButton(
            onPressed: _startOperation,
            child: const Text('Start'),
          ),
      ],
    );
  }

  void _nextStep() {
    if (_step == 0 && _operation != null) {
      setState(() => _step++);
    } else if (_step == 1) {
      // Validate required fields
    if ((_operation == OperationType.verify && _sha1File != null) ||
      (_operation == OperationType.copy && _fileList != null && _destDir != null)) {
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
      _fileProgress = 0;
      _currentFile = null;
    });
    // TODO: Call ciphercopy_core logic and handle ProgressEvent callbacks
    // TODO: Use same logging as ciphercopy_cli.dart
  }
}
