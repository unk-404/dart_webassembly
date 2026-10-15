// Layer 4 - a pool of workers.
//
// A pool compiles a module on every worker and instantiates it there, so that
// calls can be spread over several threads.  Nothing here blocks the calling
// isolate.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../wasmtime/engine.dart';
import '../wasmtime/types.dart';
import 'worker.dart';

/// A set of [WasmWorker]s that share the work.
///
/// ```dart
/// final pool = await WasmPool.spawn(workers: 4);
/// final module = await pool.load(wasmBytes);
/// final instance = await module.instantiate();
/// final results = await instance.callAll('spin', [[n], [n], [n], [n]]);
/// await pool.dispose();
/// ```
final class WasmPool {
  WasmPool._(this._workers);

  /// Starts [workers] workers, each with its own engine, store and thread.
  ///
  /// Defaults to the number of processors, capped at 8.
  static Future<WasmPool> spawn({
    int? workers,
    void Function(WasmConfig config)? configure,
  }) async {
    final count = workers ?? Platform.numberOfProcessors.clamp(1, 8);
    if (count < 1) throw RangeError.range(count, 1, null, 'workers');
    final created = <WasmWorker>[];
    try {
      for (var i = 0; i < count; i++) {
        created.add(await WasmWorker.spawn(configure: configure));
      }
    } catch (_) {
      for (final worker in created) {
        await worker.dispose();
      }
      rethrow;
    }
    return WasmPool._(created);
  }

  final List<WasmWorker> _workers;

  /// The number of workers, i.e. the maximum parallelism.
  int get workerCount => _workers.length;

  /// The workers themselves, for callers that need a specific one.
  List<WasmWorker> get workers => List.unmodifiable(_workers);

  /// Compiles [bytes] on every worker.
  ///
  /// Each worker compiles independently; the per-worker module (and its
  /// instances) never crosses a thread boundary.
  Future<PooledModule> load(Uint8List bytes) async {
    final modules = <RemoteModule>[];
    for (final worker in _workers) {
      modules.add(await worker.compile(bytes));
    }
    return PooledModule._(this, modules);
  }

  /// Releases every worker.
  Future<void> dispose() async {
    for (final worker in _workers) {
      await worker.dispose();
    }
  }
}

/// A module that has been compiled on every worker of a [WasmPool].
final class PooledModule {
  PooledModule._(this.pool, this._modules);

  final WasmPool pool;
  final List<RemoteModule> _modules;

  /// The imports the module declares (from the first worker).
  Future<List<WasmImportInfo>> get imports async {
    final imports = await _modules.first.imports();
    return [for (final import in imports) WasmImportInfo.of(import)];
  }

  /// Instantiates the module on every worker.
  Future<PooledInstance> instantiate([
    Map<String, Map<String, Object?>> imports = const {},
  ]) async {
    final instances = <RemoteInstance>[];
    for (final module in _modules) {
      instances.add(await module.instantiate(imports));
    }
    return PooledInstance._(this, instances);
  }

  /// The compiled artifact, which other pools can load with
  /// [WasmWorker.deserialize].
  Future<Uint8List> serialize() => _modules.first.serialize();

  @override
  String toString() => 'PooledModule(${pool.workerCount} workers)';
}

/// A description of one import, as reported by [PooledModule.imports].
final class WasmImportInfo {
  const WasmImportInfo({
    required this.module,
    required this.name,
    required this.kind,
  });

  factory WasmImportInfo.of(WasmImport import) => WasmImportInfo(
    module: import.module,
    name: import.name,
    kind: import.kind.wasmName,
  );

  final String module;
  final String name;
  final String kind;

  @override
  String toString() => '$module.$name ($kind)';
}

/// One instance per worker, so that calls can run on several threads at once.
final class PooledInstance {
  PooledInstance._(this.module, this._instances);

  final PooledModule module;
  final List<RemoteInstance> _instances;
  int _roundRobin = 0;

  /// The number of instances, one per worker.
  int get workerCount => _instances.length;

  /// Calls the export [name] on one of the workers.
  Future<Object?> invoke(
    String name, [
    List<Object?> arguments = const [],
  ]) => _instances[_pick()].invoke(name, arguments);

  /// Calls the export [name] once for every entry of [argumentSets], spread
  /// over the workers so that they really run in parallel.
  ///
  /// The results keep the order of [argumentSets].
  Future<List<Object?>> callAll(
    String name,
    List<List<Object?>> argumentSets,
  ) async {
    final results = List<Object?>.filled(argumentSets.length, null);
    final buckets = List.generate(workerCount, (_) => <int>[]);
    for (var i = 0; i < argumentSets.length; i++) {
      buckets[i % workerCount].add(i);
    }
    await Future.wait([
      for (var worker = 0; worker < workerCount; worker++)
        () async {
          for (final index in buckets[worker]) {
            results[index] = await _instances[worker].invoke(
              name,
              argumentSets[index],
            );
          }
        }(),
    ]);
    return results;
  }

  /// Reads [length] bytes of the memory exported as [name] from one worker.
  Future<Uint8List> readMemory(String name, int offset, int length) =>
      _instances[_pick()].readMemory(name, offset, length);

  /// Which worker to use next: the least busy one, round robin on ties.
  int _pick() {
    var best = 0;
    var bestPending = _instances[0].worker.pendingRequests;
    for (var i = 1; i < workerCount; i++) {
      final pending = _instances[i].worker.pendingRequests;
      if (pending < bestPending) {
        best = i;
        bestPending = pending;
      }
    }
    if (bestPending > 0) return best;
    final chosen = _roundRobin++ % workerCount;
    return chosen;
  }

  @override
  String toString() => 'PooledInstance($workerCount workers)';
}
