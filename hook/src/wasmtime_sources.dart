// Where the wasmtime sources come from.
//
// They are not part of this package.  A checkout of
// https://github.com/bytecodealliance/wasmtime is about 100 MB, so instead of
// shipping (and re-publishing) it, it is looked up in this order:
//
//   1. the `WASMTIME_SOURCE_DIR` environment variable,
//   2. the `wasmtime/` git submodule, which is how this package is developed,
//   3. a user level cache, filled by a shallow fetch of one revision.
//
// The revision is the one the submodule of the source repository points at, so
// a development checkout and a published package build the same code.

import 'dart:io';

/// The wasmtime revision this package is built against.
///
/// It is the commit the `wasmtime/` submodule of the source repository is at.
const String wasmtimeRevision = '5af334209f6a230c167f836bcbfdef5fa8cbad01';

/// The repository the sources come from.
const String wasmtimeUrl = 'https://github.com/bytecodealliance/wasmtime';

/// Points at an existing checkout, instead of downloading one.
///
/// Build hooks run in a semi-hermetic environment that strips almost every
/// environment variable, so this only has an effect when the hook is invoked
/// directly; inside a Flutter or Dart build use [sourceDirDefine] instead.
const String wasmtimeSourceDirVariable = 'WASMTIME_SOURCE_DIR';

/// The `hooks.user_defines` key that points at an existing checkout.
///
/// ```yaml
/// hooks:
///   user_defines:
///     webassembly:
///       wasmtime_source_dir: /path/to/wasmtime
/// ```
const String sourceDirDefine = 'wasmtime_source_dir';

/// Whether [directory] holds a wasmtime checkout with the C API in it.
bool isWasmtimeCheckout(Directory directory) => File(
  '${directory.path}/crates/c-api/CMakeLists.txt',
).existsSync();

/// Where a downloaded checkout is cached, given the revision.
Directory wasmtimeCacheDirectory({Directory? cacheRoot}) => Directory(
  '${(cacheRoot ?? defaultCacheRoot()).path}/dart_webassembly/wasmtime/'
  '$wasmtimeRevision',
);

/// The per-user cache directory of this platform.
Directory defaultCacheRoot() {
  final environment = Platform.environment;
  String? base;
  if (Platform.isWindows) {
    base =
        environment['LOCALAPPDATA'] ??
        environment['APPDATA'] ??
        environment['USERPROFILE'];
  } else if (Platform.isMacOS) {
    final home = environment['HOME'];
    base = home == null ? null : '$home/Library/Caches';
  } else {
    final home = environment['HOME'];
    base =
        environment['XDG_CACHE_HOME'] ??
        (home == null ? null : '$home/.cache');
  }
  return Directory(base ?? Directory.systemTemp.path);
}

/// Resolves the directory that holds the wasmtime sources.
///
/// Throws a [StateError] with something actionable in it when the sources are
/// neither available locally nor downloadable.
Future<Directory> resolveWasmtimeSources({
  required Directory packageRoot,
  Directory? cacheRoot,
  Object? configuredSourceDir,
  bool forceDownload = false,
  void Function(String message)? log,
}) async {
  void report(String message) => log?.call(message);

  if (!forceDownload) {
    final candidates = <String, String?>{
      if (configuredSourceDir != null)
        sourceDirDefine: configuredSourceDir is String
            ? configuredSourceDir
            : throw StateError(
                'hooks.user_defines.$sourceDirDefine must be a path, '
                'got ${configuredSourceDir.runtimeType}.',
              ),
      wasmtimeSourceDirVariable: Platform.environment[wasmtimeSourceDirVariable],
    };
    for (final entry in candidates.entries) {
      final value = entry.value;
      if (value == null || value.isEmpty) continue;
      final directory = Directory(value);
      if (!isWasmtimeCheckout(directory)) {
        throw StateError(
          '${entry.key} is "${directory.path}", which does not contain the '
          'wasmtime C API (crates/c-api/CMakeLists.txt is missing).',
        );
      }
      report('${entry.key} = ${directory.path}');
      return directory;
    }

    final submodule = Directory('${packageRoot.path}/wasmtime');
    if (isWasmtimeCheckout(submodule)) {
      report('wasmtime submodule = ${submodule.path}');
      return submodule;
    }
  }

  final cache = wasmtimeCacheDirectory(cacheRoot: cacheRoot);
  if (isWasmtimeCheckout(cache)) {
    report('cached wasmtime checkout = ${cache.path}');
    return cache;
  }

  report('downloading wasmtime $wasmtimeRevision from $wasmtimeUrl');
  await downloadWasmtime(cache);
  report('wasmtime checkout = ${cache.path}');
  return cache;
}

/// Shallow-fetches [wasmtimeRevision] into [destination].
Future<void> downloadWasmtime(Directory destination) async {
  // Anything already there is a half finished download.
  if (destination.existsSync()) {
    destination.deleteSync(recursive: true);
  }
  await destination.create(recursive: true);
  await _git(['init', '--quiet'], destination);
  await _git(['remote', 'add', 'origin', wasmtimeUrl], destination);
  await _git(
    ['fetch', '--depth', '1', '--quiet', 'origin', wasmtimeRevision],
    destination,
  );
  await _git(['checkout', '--quiet', '--detach', 'FETCH_HEAD'], destination);
  if (!isWasmtimeCheckout(destination)) {
    throw StateError(
      'the wasmtime checkout in ${destination.path} is incomplete; delete it '
      'and try again.',
    );
  }
}

Future<void> _git(List<String> arguments, Directory workingDirectory) async {
  final ProcessResult result;
  try {
    result = await Process.run(
      'git',
      arguments,
      workingDirectory: workingDirectory.path,
    );
  } on ProcessException catch (error) {
    throw StateError(
      'could not run git (${error.message}). Install it, or set '
      '$wasmtimeSourceDirVariable to a wasmtime checkout '
      '($wasmtimeUrl at $wasmtimeRevision).',
    );
  }
  if (result.exitCode != 0) {
    throw StateError(
      'git ${arguments.join(' ')} failed with ${result.exitCode}:\n'
      '${result.stderr}',
    );
  }
}
