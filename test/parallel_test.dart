// Tests for layer 4: non-blocking execution and multi-threaded pools.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_wasm/parallel.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/$name.wasm').readAsBytesSync();

/// A burn length that takes a couple of hundred milliseconds; the `spin`
/// fixture runs about 4.6 million iterations per millisecond when JITed.
const int burn = 1000000000;

void main() {
  group('WasmWorker', () {
    test('compiles, instantiates, calls and touches memory', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('arithmetic'));
      final instance = await module.instantiate();

      expect(await instance.invoke('add', [20, 22]), 42);
      expect(await instance.invoke('answer'), 42);
      expect(await instance.invoke('twice', [21]), 42);
      expect(await instance.invoke('half', [84.0]), 42.0);
      expect(await instance.invoke('swap', [1, 2]), [2, 1]);
      expect(await instance.exports(), containsPair('add', 'function'));
    });

    test('reports traps and link errors', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('arithmetic'));
      final instance = await module.instantiate();
      await expectLater(instance.invoke('boom'), throwsA(isA<WasmTrapException>()));

      final imports = await worker.compile(fixture('imports'));
      await expectLater(
        imports.instantiate(),
        throwsA(isA<WasmtimeException>()),
      );
    });

    test('host functions and memories can be imported', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('imports'));
      final instance = await module.instantiate({
        'env': {
          'log': (int value) => null,
          'sum': (int a, int b) => a + b,
          'mem': const MemoryDescriptor(initial: 1),
        },
      });

      expect(await instance.invoke('call_sum', [40, 2]), 42);

      // The memory was created inside the worker from the descriptor; it is not
      // an export, so it is addressed as "<module>.<name>".
      await instance.writeMemory('env.mem', 16, Uint8List.fromList([1, 2, 3, 4]));
      expect(await instance.readMemory('env.mem', 16, 4), [1, 2, 3, 4]);
      // ... and the module sees the very same bytes.
      expect(await instance.invoke('read_imported_memory', [16]), 0x04030201);
    });

    test('reads and writes exported memory', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('memory'));
      final instance = await module.instantiate();

      expect(await instance.memorySize('mem'), 65536);
      await instance.writeMemory('mem', 0, Uint8List.fromList([0x2a, 0, 0, 0]));
      expect(await instance.invoke('load', [0]), 0x2a);
      expect(await instance.invoke('grow', [1]), 1);
      expect(await instance.memorySize('mem'), 131072);
    });

    test('reads and writes exported globals', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('globals'));
      final instance = await module.instantiate();

      expect(await instance.readGlobal('counter'), 0);
      expect(await instance.invoke('bump'), 1);
      expect(await instance.readGlobal('counter'), 1);
      await instance.writeGlobal('counter', 41);
      expect(await instance.invoke('bump'), 42);
      expect(await instance.readGlobal('ratio'), 1.5);
    });

    test('a module can be serialised and loaded elsewhere', () async {
      final first = await WasmWorker.spawn();
      final second = await WasmWorker.spawn();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      final module = await first.compile(fixture('arithmetic'));
      final blob = await module.serialize();
      final loaded = await second.deserialize(blob);
      final instance = await loaded.instantiate();
      expect(await instance.invoke('answer'), 42);
    });

    test('is unusable once released', () async {
      final worker = await WasmWorker.spawn();
      final module = await worker.compile(fixture('arithmetic'));
      final instance = await module.instantiate();
      expect(await instance.invoke('answer'), 42);

      await worker.dispose();
      expect(worker.isDisposed, isTrue);
      await expectLater(
        instance.invoke('answer'),
        throwsA(isA<WasmWorkerException>()),
      );
    });
  });

  group('non-blocking', () {
    test('a long wasm call does not block the calling isolate', () async {
      final worker = await WasmWorker.spawn();
      addTearDown(worker.dispose);

      final module = await worker.compile(fixture('spin'));
      final instance = await module.instantiate();

      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => ticks++,
      );
      final watch = Stopwatch()..start();
      final result = await instance.invoke('spin', [burn]);
      watch.stop();
      timer.cancel();

      expect(result, burn);
      // The calling isolate stayed responsive the whole time: the timer kept
      // firing while WebAssembly was burning CPU on the worker.
      expect(
        ticks,
        greaterThanOrEqualTo(2),
        reason:
            'the calling isolate ticked $ticks times during '
            '${watch.elapsedMilliseconds} ms of WebAssembly work',
      );
    });

    test('two workers run at the same time', () async {
      final first = await WasmWorker.spawn();
      final second = await WasmWorker.spawn();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      final module = await first.compile(fixture('spin'));
      final instance = await module.instantiate();
      final otherModule = await second.compile(fixture('spin'));
      final otherInstance = await otherModule.instantiate();

      // A single call, to know what one unit of work costs.
      final single = Stopwatch()..start();
      await instance.invoke('spin', [burn]);
      single.stop();

      final both = Stopwatch()..start();
      await Future.wait([
        instance.invoke('spin', [burn]),
        otherInstance.invoke('spin', [burn]),
      ]);
      both.stop();

      // Two calls on two workers take about as long as one call on one worker;
      // run one after the other they would take twice as long.
      expect(
        both.elapsedMilliseconds,
        lessThan(single.elapsedMilliseconds * 1.8),
        reason:
            'single: ${single.elapsedMilliseconds} ms, '
            'both: ${both.elapsedMilliseconds} ms',
      );
    });
  });

  group('WasmPool', () {
    test('compiles on every worker and spreads calls over them', () async {
      final pool = await WasmPool.spawn(workers: 2);
      addTearDown(pool.dispose);

      expect(pool.workerCount, 2);
      final module = await pool.load(fixture('spin'));
      final instance = await module.instantiate();

      final single = Stopwatch()..start();
      await instance.invoke('spin', [burn]);
      single.stop();

      final all = Stopwatch()..start();
      final results = await instance.callAll('spin', [
        [burn],
        [burn],
        [burn],
        [burn],
      ]);
      all.stop();

      expect(results, [burn, burn, burn, burn]);
      // Four units of work on two workers cost about two units of time, not
      // four.
      expect(
        all.elapsedMilliseconds,
        lessThan(single.elapsedMilliseconds * 3),
        reason:
            'single: ${single.elapsedMilliseconds} ms, '
            'four calls: ${all.elapsedMilliseconds} ms',
      );
    });

    test('instances expose memory and imports', () async {
      final pool = await WasmPool.spawn(workers: 2);
      addTearDown(pool.dispose);

      final module = await pool.load(fixture('memory'));
      final instance = await module.instantiate();
      expect(await instance.readMemory('mem', 8, 5), 'hello'.codeUnits);
    });

    test('spawns one worker per processor by default', () async {
      final pool = await WasmPool.spawn();
      addTearDown(pool.dispose);
      expect(pool.workerCount, greaterThanOrEqualTo(1));
      expect(
        pool.workerCount,
        lessThanOrEqualTo(Platform.numberOfProcessors.clamp(1, 8)),
      );
    });
  });
}
