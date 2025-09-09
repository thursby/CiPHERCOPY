## CiPHERCOPY CLi
```
      ______ ___  __ _________  ________  _____  __
     ╱ ___(_) _ ╲╱ ╱╱ ╱ __╱ _ ╲╱ ___╱ _ ╲╱ _ ╲ ╲╱ ╱
    ╱ ╱__╱ ╱ ___╱ _  ╱ _╱╱ , _╱ ╱__╱ (/ ╱ ___╱╲  ╱ 
    ╲___╱_╱_╱  ╱_╱╱_╱___╱_╱│_│╲___╱╲___╱_╱    ╱_╱  
```

High-performance, multi-threaded file copier for large batches with live per-file progress bars and SHA-1 verification.

It reads a plain text list of file paths, copies them to a destination directory while preserving relative paths, and writes a combined SHA-1 file for verification. Concurrency uses Dart isolates for parallel I/O.

## Features

- Streamed copy for large files
- Parallelism via isolates (configurable threads)
- Live per-file progress bars + overall progress
- Combined SHA-1 output file in the destination
- Optional copied.txt and errored.txt manifests
- Structured logging to a timestamped log file (also copied to the destination)
- Verify mode to validate files against a previously generated .sha1 manifest

## Requirements

- Dart SDK 3.9+
- macOS (tested). Linux should work; Windows requires ANSI-capable terminal for progress bars.

## Installation

Clone and get dependencies:

```sh
git clone https://github.com/thursby/ciphercopy_cli.git
cd ciphercopy_cli
dart pub get
```

Optional: build a native executable:

```sh
dart compile exe bin/ciphercopy_cli.dart -o ciphercopy
```

## Usage

Run with a list file and a destination directory:

```sh
dart run bin/ciphercopy_cli.dart <list_file> <destination_directory>
```

Flags:

- `-h, --help` Show usage
- `-t, --threads <count>` Number of concurrent threads (defaults to CPU cores)
- `-l, --list` Also write `copied.txt` and `errored.txt` in the destination

Examples:

```sh
# Basic
dart run bin/ciphercopy_cli.dart ~/Downloads/list.txt ~/Downloads/dest

# Limit concurrency
dart run bin/ciphercopy_cli.dart -t 4 ~/Downloads/list.txt ~/Downloads/dest

# Also emit copied.txt and errored.txt
dart run bin/ciphercopy_cli.dart -l ~/Downloads/list.txt ~/Downloads/dest
```

### Verify files using a .sha1 manifest

Use `--verify` with the path to a `hashes.sha1` file produced by this app. The verification runs multi-threaded and shows the same per-file + overall progress bars.

```sh
# Verify using defaults (threads = CPU cores)
dart run bin/ciphercopy_cli.dart --verify ~/Downloads/dest/hashes.sha1

# Limit concurrency
dart run bin/ciphercopy_cli.dart --verify -t 4 ~/Downloads/dest/hashes.sha1
```

Output summary example:

```
Overall: ████████████████████████████  135/135 100.0%
Verify complete: 135/135 OK, 0 mismatched, 0 errors.
```

### List file format

- Plain text; one path per line
- Empty lines are ignored
- Directory entries are skipped
- Absolute or relative paths are accepted

Paths are preserved under the destination. If a path starts with `/`, the leading slash is removed to keep a relative layout under the destination.

Example list.txt:

```
/Users/alex/projects/a/big.iso
./assets/images/logo.png
relative/path/to/file.txt
```

## Library Usage

You can embed the core logic in another Dart app (e.g. GUI) by depending on this package and importing:

```dart
import 'package:ciphercopy_cli/ciphercopy_core.dart';
```

The old `ciphercopy.dart` and `ciphercopy_cli.dart` shims have been removed; use `ciphercopy_core.dart` directly.

Key functions:

```dart
await copyFilesFromList(listPath, destinationDir, threadCount: 8, saveLists: true);
final summary = await verifyFromSha1('dest/hashes.sha1');
```

## Outputs

In the destination directory:

- `hashes.sha1` Combined SHA-1 list in the format: `<sha1>  <absolute-dest-file-path>`
- `copied.txt` (with `-l`) All copied file paths
- `errored.txt` (with `-l`) Any files that failed to copy

Logging:

- A log file is created in the project working directory, e.g. `copy-<dest-name>-YYYY-MM-DD-HH-SS.log`
- In copy mode, the log is copied into the destination directory at the end
- In verify mode, the log is copied alongside the `.sha1` manifest

## Progress UI

- Per-file bars show the file name, bytes copied, and percent
- An Overall bar is always shown at the bottom and increments when files complete
- Updates use ANSI control codes; if your terminal doesn’t support them, output may not render correctly

## Exit codes

- `0` Success
- `64` Usage error (missing/invalid arguments)
- `2` Runtime error (copy or hash failures encountered)

## How it works (brief)

- Main isolate reads the list, prepares destination paths, and spawns up to N worker isolates
- Each worker streams a source file to the destination, reports periodic progress, and computes the SHA-1 while copying
- The main isolate writes the combined `hashes.sha1`, maintains progress bars, and optionally writes copied/errored manifests
- In verify mode, workers compute SHA-1 for each file listed in the manifest and compare against the expected hash; progress is reported the same way

## Troubleshooting

- “Permission denied”: ensure read access to sources and write permissions to the destination
- “No such file or directory”: verify paths in your list file exist
- Slow copies: try reducing `--threads` if I/O is saturated, or increasing it on fast storage
- Progress garbled: use a terminal with ANSI support and sufficient width

## Features To Do
- Sign hash manifest with HMAC
- Copy directories (not just file lists)
- Resume interrupted copies
- Configurable hash algorithms (e.g., SHA-256, MD5)
- Exclude/include patterns for file selection
- Cross-platform support improvements (Windows, Linux)
- Configurable logging verbosity