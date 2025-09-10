import 'package:flutter/material.dart';

class ThreadControl extends StatelessWidget {
  final int threadCount;
  final void Function(int) onChanged;
  final int minThreads;
  final int maxThreads;
  const ThreadControl({
    super.key,
    required this.threadCount,
    required this.onChanged,
    this.minThreads = 1,
    int? maxThreads,
  }) : maxThreads = maxThreads ?? 128;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Threads'),
      subtitle: const Text('Reduce if I/O is the bottleneck'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Decrease',
            icon: const Icon(Icons.remove),
            onPressed: threadCount > minThreads
                ? () => onChanged(
                    (threadCount - 1).clamp(minThreads, this.maxThreads),
                  )
                : null,
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$threadCount',
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
            onPressed: threadCount < maxThreads
                ? () => onChanged(
                    (threadCount + 1).clamp(minThreads, this.maxThreads),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
