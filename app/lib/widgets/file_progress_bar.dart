import 'package:flutter/material.dart';
import 'package:ciphercopy/models/active_file_progress.dart';

class FileProgressBar extends StatelessWidget {
  final ActiveFileProgress fp;
  const FileProgressBar({super.key, required this.fp});
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
