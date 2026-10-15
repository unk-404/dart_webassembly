// Tests for where the build hook gets the wasmtime sources from.
//
// The download test is skipped by default, because it fetches ~100 MB.  Set
// `WASMTIME_DOWNLOAD_TEST=1` to run it; CI does, which keeps the published
// path - "no submodule, so fetch the pinned revision" - working.

import 'dart:io';

import 'package:test/test.dart';
import 'package:webassembly/src/toolchain/wasmtime_sources.dart';

/// Makes [directory] look like a wasmtime checkout to [isWasmtimeCheckout].
Directory _makeCheckout(Directory directory) {
  File('${directory.path}/crates/c-api/CMakeLists.txt')
    ..createSync(recursive: true)
    ..writeAsStringSync('');
  return directory;
}

Directory _tempDirectory(String prefix) {
  final directory = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

/// Both are absolute paths, only the separators may differ.
String _normalise(String path) => path.replaceAll(r'\', '/');

void main() {
  test('the revision is a full commit', () {
    expect(wasmtimeRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(wasmtimeUrl, startsWith('https://'));
  });

  group('the cache', () {
    test('is under the cache root, keyed by the revision', () {
      expect(
        _normalise(wasmtimeCacheDirectory(cacheRoot: Directory('/cache')).path),
        '/cache/dart_webassembly/wasmtime/$wasmtimeRevision',
      );
    });

    test('is somewhere in the user profile by default', () {
      expect(wasmtimeCacheDirectory().path, isNotEmpty);
    });
  });

  group('isWasmtimeCheckout', () {
    test('accepts a checkout with the C API in it', () {
      final root = _tempDirectory('webassembly-checkout-');
      expect(isWasmtimeCheckout(_makeCheckout(Directory('${root.path}/x'))), isTrue);
    });

    test('rejects anything else', () {
      final root = _tempDirectory('webassembly-not-a-checkout-');
      expect(isWasmtimeCheckout(root), isFalse);
      expect(isWasmtimeCheckout(Directory('${root.path}/missing')), isFalse);
    });
  });

  group('resolveWasmtimeSources', () {
    test('uses the wasmtime submodule of the package', () async {
      final root = _tempDirectory('webassembly-submodule-');
      final submodule = _makeCheckout(Directory('${root.path}/wasmtime'));
      final sources = await resolveWasmtimeSources(
        packageRoot: root,
        cacheRoot: Directory('${root.path}/cache'),
      );
      expect(sources.path, submodule.path);
    });

    test('prefers a configured checkout over everything', () async {
      final root = _tempDirectory('webassembly-configured-');
      _makeCheckout(Directory('${root.path}/wasmtime')); // a submodule is there too
      final configured = _makeCheckout(Directory('${root.path}/elsewhere'));
      final sources = await resolveWasmtimeSources(
        packageRoot: root,
        cacheRoot: Directory('${root.path}/cache'),
        configuredSourceDir: configured.path,
      );
      expect(sources.path, configured.path);
    });

    test('uses a cached checkout instead of downloading', () async {
      final root = _tempDirectory('webassembly-cached-');
      final cached = _makeCheckout(wasmtimeCacheDirectory(cacheRoot: root));
      final sources = await resolveWasmtimeSources(
        packageRoot: root,
        cacheRoot: root,
        forceDownload: true,
      );
      expect(sources.path, cached.path);
    });

    test('rejects a configured path that is not a checkout', () async {
      final root = _tempDirectory('webassembly-bad-path-');
      await expectLater(
        resolveWasmtimeSources(
          packageRoot: _tempDirectory('webassembly-empty-'),
          cacheRoot: root,
          configuredSourceDir: root.path,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains(sourceDirDefine), contains('does not contain')),
          ),
        ),
      );
    });

    test('rejects a user define that is not a path', () async {
      await expectLater(
        resolveWasmtimeSources(
          packageRoot: _tempDirectory('webassembly-not-a-path-'),
          cacheRoot: _tempDirectory('webassembly-not-a-path-cache-'),
          configuredSourceDir: 42,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('must be a path'),
          ),
        ),
      );
    });
  });

  group('downloading', () {
    test(
      'fetches the pinned revision into the cache',
      () async {
        final cacheRoot = _tempDirectory('webassembly-download-');
        final sources = await resolveWasmtimeSources(
          packageRoot: _tempDirectory('webassembly-no-submodule-'),
          cacheRoot: cacheRoot,
          forceDownload: true,
          log: print,
        );

        expect(isWasmtimeCheckout(sources), isTrue);
        expect(sources.path, wasmtimeCacheDirectory(cacheRoot: cacheRoot).path);
        for (final path in const [
          'crates/c-api/include/wasmtime.h',
          'Cargo.toml',
          'Cargo.lock',
        ]) {
          expect(
            File('${sources.path}/$path').existsSync(),
            isTrue,
            reason: '$path is missing from the checkout',
          );
        }
      },
      skip: Platform.environment['WASMTIME_DOWNLOAD_TEST'] == '1'
          ? false
          : 'set WASMTIME_DOWNLOAD_TEST=1 to fetch ~100 MB',
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}
