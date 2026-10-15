// Layer 4 - workers.
//
// A worker owns a wasmtime engine and store inside its own isolate (and
// therefore its own thread).  Everything the caller does is a `Future`, so the
// UI isolate never runs WebAssembly itself: compile, instantiate, call, and
// touch memory.
//
// Values that cross the isolate boundary are limited to what Dart can send
// (null, numbers, strings, lists, maps, `Uint8List`); function references and
// memories live on the worker and are addressed by name or by export.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../api/types.dart'
    show GlobalDescriptor, MemoryDescriptor, TableDescriptor;
import '../ffi/errors.dart';
import '../ffi/marshal.dart' show Limits;
import '../ffi/values.dart' show WasmValueKind;
import '../wasmtime/engine.dart';
import '../wasmtime/handles.dart';
import '../wasmtime/instance.dart';
import '../wasmtime/linker.dart';
import '../wasmtime/module.dart';
import '../wasmtime/store.dart';
import '../wasmtime/types.dart';

/// Raised when a worker cannot be talked to (a crash, or a released worker).
class WasmWorkerException implements Exception {
  WasmWorkerException(this.message);

  final String message;

  @override
  String toString() => 'WasmWorkerException: $message';
}

/// One or more isolates that run WebAssembly for the calling isolate.
///
/// ```dart
/// final worker = await WasmWorker.spawn();
/// final module = await worker.compile(wasmBytes);
/// final instance = await module.instantiate({
///   'env': {'log': (int value) => print(value)},
/// });
/// print(await instance.invoke('add', [20, 22]));
/// await worker.dispose();
/// ```
final class WasmWorker {
  WasmWorker._(this._isolate, this._commands, this._responses);

  /// Starts a worker with its own engine and store.
  static Future<WasmWorker> spawn({
    void Function(WasmConfig config)? configure,
  }) async {
    final handshake = ReceivePort();
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _WorkerStart(handshake.sendPort, responses.sendPort, configure),
      debugName: 'WasmWorker',
    );
    final commands = await handshake.first as SendPort;
    handshake.close();
    final worker = WasmWorker._(isolate, commands, responses);
    responses.listen(worker._onMessage, onError: worker._onTransportError);
    return worker;
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 1;
  bool _disposed = false;

  /// Whether the worker has been released.
  bool get isDisposed => _disposed;

  /// How many requests are in flight; useful for spreading load over a pool.
  int get pendingRequests => _pending.length;

  /// Compiles [bytes] inside the worker.
  Future<RemoteModule> compile(Uint8List bytes) async {
    final reply = await _request('compile', {'bytes': bytes});
    return RemoteModule._(this, reply['moduleId']! as int);
  }

  /// Loads a module from a blob produced by [RemoteModule.serialize].
  Future<RemoteModule> deserialize(Uint8List blob) async {
    final reply = await _request('deserialize', {'bytes': blob});
    return RemoteModule._(this, reply['moduleId']! as int);
  }

  /// Whether [bytes] is a valid module.
  Future<bool> validate(Uint8List bytes) async =>
      (await _request('validate', {'bytes': bytes}))['value']! as bool;

  Future<RemoteInstance> _instantiate(
    int moduleId,
    Map<String, Map<String, Object?>> imports,
  ) async {
    final reply = await _request('instantiate', {
      'moduleId': moduleId,
      'imports': imports,
    });
    return RemoteInstance._(this, reply['instanceId']! as int);
  }

  /// Releases the worker's engine and store and stops its isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await _request('dispose').timeout(const Duration(seconds: 5));
    } on Object {
      // A worker that cannot answer is about to be killed anyway.
    }
    _disposed = true;
    _failPending('the worker was released');
    _responses.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  // -------------------------------------------------------------------------
  // Protocol
  // -------------------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) {
    if (_disposed) {
      throw WasmWorkerException('the worker was released');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send({'id': id, 'op': op, ...arguments});
    return completer.future.then(
      (value) => (value! as Map).cast<String, Object?>(),
    );
  }

  void _onMessage(Object? message) {
    final reply = (message! as Map).cast<String, Object?>();
    final completer = _pending.remove(reply['id']! as int);
    if (completer == null) return;
    final error = reply['error'];
    if (error == null) {
      completer.complete(reply['value']);
    } else {
      final details = (error as Map).cast<String, Object?>();
      completer.completeError(
        _decodeError(
          details['type']! as String,
          details['message']! as String,
        ),
      );
    }
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    _failPending('$error');
  }

  void _failPending(String reason) {
    final pending = List<Completer<Object?>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(WasmWorkerException(reason));
      }
    }
  }
}

Object _decodeError(String type, String message) => switch (type) {
  'trap' => WasmTrapException(message),
  'wasmtime' => WasmtimeException(message),
  'range' => RangeError(message),
  'argument' => ArgumentError(message),
  _ => WasmWorkerException(message),
};

Map<String, Object?> _encodeError(Object error) => switch (error) {
  WasmTrapException(:final message) => {'type': 'trap', 'message': message},
  WasmtimeException(:final message) => {
    'type': 'wasmtime',
    'message': message,
  },
  RangeError(:final message) => {'type': 'range', 'message': '$message'},
  ArgumentError(:final message) => {'type': 'argument', 'message': '$message'},
  _ => {'type': 'other', 'message': '$error'},
};

// ---------------------------------------------------------------------------
// RemoteModule
// ---------------------------------------------------------------------------

/// A [WasmModule] that lives in a worker.
final class RemoteModule {
  RemoteModule._(this.worker, this._id);

  final WasmWorker worker;
  final int _id;

  /// Whether this module is still usable.
  bool get isDisposed => worker.isDisposed;

  /// The module's imports, with their declared types.
  Future<List<WasmImport>> imports() async => [
    for (final entry in (await _request('moduleImports'))['value']! as List)
      _decodeImport((entry as Map).cast<String, Object?>()),
  ];

  /// The module's exports, with their declared types.
  Future<List<WasmExport>> exports() async => [
    for (final entry in (await _request('moduleExports'))['value']! as List)
      _decodeExport((entry as Map).cast<String, Object?>()),
  ];

  /// The compiled artifact, which can be loaded in another worker.
  Future<Uint8List> serialize() async =>
      (await _request('moduleSerialize'))['value']! as Uint8List;

  /// Instantiates the module in the worker's store.
  ///
  /// Function imports are Dart functions; memory, table and global imports have
  /// to be given as descriptors (a `Memory`/`Table`/`Global` object cannot be
  /// sent to another isolate).
  Future<RemoteInstance> instantiate([
    Map<String, Map<String, Object?>> imports = const {},
  ]) => worker._instantiate(_id, imports);

  Future<Map<String, Object?>> _request(String op) =>
      worker._request(op, {'moduleId': _id});

  @override
  String toString() => 'RemoteModule($_id)';
}

// ---------------------------------------------------------------------------
// RemoteInstance
// ---------------------------------------------------------------------------

/// A [WasmInstance] that lives in a worker.
final class RemoteInstance {
  RemoteInstance._(this.worker, this._id);

  final WasmWorker worker;
  final int _id;

  /// The names and kinds of the exports.
  Future<Map<String, String>> exports() async => (await _request('exports'))[
          'value']!
      as Map<String, String>;

  /// Calls the exported function [name]; the result follows the JavaScript
  /// convention (null, the single value, or a list for several results).
  Future<Object?> invoke(String name, [List<Object?> arguments = const []]) async =>
      (await _request('invoke', {'name': name, 'args': arguments}))['value'];

  /// Reads [length] bytes of the exported memory [name].
  Future<Uint8List> readMemory(
    String name,
    int offset,
    int length,
  ) async =>
      (await _request('readMemory', {
        'name': name,
        'offset': offset,
        'length': length,
      }))['value']!
          as Uint8List;

  /// Writes [bytes] into the exported memory [name] at [offset].
  Future<void> writeMemory(
    String name,
    int offset,
    Uint8List bytes,
  ) => _request('writeMemory', {
    'name': name,
    'offset': offset,
    'bytes': bytes,
  });

  /// The current size of the exported memory [name], in bytes.
  Future<int> memorySize(String name) async =>
      (await _request('memorySize', {'name': name}))['value']! as int;

  /// Grows the exported memory [name] by [deltaPages] pages.
  Future<int> memoryGrow(String name, int deltaPages) async =>
      (await _request('memoryGrow', {
        'name': name,
        'deltaPages': deltaPages,
      }))['value']!
          as int;

  /// Reads the value of the exported global [name].
  Future<Object?> readGlobal(String name) async =>
      (await _request('readGlobal', {'name': name}))['value'];

  /// Writes the value of the exported global [name].
  Future<void> writeGlobal(String name, Object? value) =>
      _request('writeGlobal', {'name': name, 'value': value});

  Future<Map<String, Object?>> _request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) => worker._request(op, {'instanceId': _id, ...arguments});

  @override
  String toString() => 'RemoteInstance($_id)';
}

// ---------------------------------------------------------------------------
// The worker isolate
// ---------------------------------------------------------------------------

final class _WorkerStart {
  _WorkerStart(this.handshake, this.replies, this.configure);

  /// Where the worker sends the port it listens on.
  final SendPort handshake;

  /// Where the worker sends its responses.
  final SendPort replies;

  final void Function(WasmConfig config)? configure;
}

Future<void> _workerMain(_WorkerStart start) async {
  final engine = start.configure == null
      ? WasmEngine()
      : WasmEngine.configured(start.configure!);
  final store = WasmStore(engine);
  final incoming = ReceivePort();
  start.handshake.send(incoming.sendPort);

  final modules = <int, WasmModule>{};
  final instances = <int, WasmInstance>{};
  final importedExterns = <int, Map<String, Object>>{};
  var nextId = 1;

  final caller = start.replies;
  await for (final message in incoming) {
    final request = (message as Map).cast<String, Object?>();
    final id = request['id']! as int;
    try {
      final value = await _handle(
        request['op']! as String,
        request,
        engine: engine,
        store: store,
        modules: modules,
        instances: instances,
        importedExterns: importedExterns,
        nextId: () => nextId++,
      );
      caller.send({'id': id, 'value': value});
      if (request['op'] == 'dispose') {
        incoming.close();
        Isolate.current.kill(priority: Isolate.immediate);
        return;
      }
    } catch (error) {
      caller.send({'id': id, 'error': _encodeError(error)});
    }
  }
}

Future<Map<String, Object?>> _handle(
  String op,
  Map<String, Object?> request, {
  required WasmEngine engine,
  required WasmStore store,
  required Map<int, WasmModule> modules,
  required Map<int, WasmInstance> instances,
  required Map<int, Map<String, Object>> importedExterns,
  required int Function() nextId,
}) async {
  switch (op) {
    case 'compile':
      final module = WasmModule.compile(engine, request['bytes']! as Uint8List);
      final id = nextId();
      modules[id] = module;
      return {'moduleId': id};

    case 'deserialize':
      final module = WasmModule.deserialize(
        engine,
        request['bytes']! as Uint8List,
      );
      final id = nextId();
      modules[id] = module;
      return {'moduleId': id};

    case 'validate':
      return {'value': engine.validate(request['bytes']! as Uint8List)};

    case 'instantiate':
      final module = _module(modules, request);
      final imports = _imports(request['imports']);
      final linker = WasmLinker(engine);
      final created = <String, Object>{};
      try {
        for (final import in module.imports) {
          _defineImport(linker, store, import, imports, created);
        }
        final instance = linker.instantiate(store, module);
        final id = nextId();
        instances[id] = instance;
        importedExterns[id] = created;
        return {'instanceId': id};
      } finally {
        linker.dispose();
      }

    case 'moduleImports':
      return {
        'value': [
          for (final import in _module(modules, request).imports)
            _encodeImport(import),
        ],
      };

    case 'moduleExports':
      return {
        'value': [
          for (final export in _module(modules, request).exports)
            _encodeExport(export),
        ],
      };

    case 'moduleSerialize':
      return {'value': _module(modules, request).serialize()};

    case 'exports':
      return {
        'value': {
          for (final entry in _instance(instances, request).exports.entries)
            entry.key: _kindOf(entry.value),
        },
      };

    case 'invoke':
      final instance = _instance(instances, request);
      final export = instance.export(request['name']! as String);
      if (export is! WasmFunc) {
        throw WasmtimeException(
          'export "${request['name']}" is not a function',
        );
      }
      final results = export.call(
        (request['args'] as List?)?.cast<Object?>() ?? const <Object?>[],
      );
      return {'value': _sendable(_collapse(results))};

    case 'readMemory':
      final memory = _memory(instances, importedExterns, request);
      final offset = request['offset']! as int;
      final length = request['length']! as int;
      return {
        'value': Uint8List.fromList(
          memory.buffer.sublist(offset, offset + length),
        ),
      };

    case 'writeMemory':
      final memory = _memory(instances, importedExterns, request);
      final offset = request['offset']! as int;
      final bytes = request['bytes']! as Uint8List;
      memory.buffer.setRange(offset, offset + bytes.length, bytes);
      return const {};

    case 'memorySize':
      return {
        'value': _memory(instances, importedExterns, request).lengthInBytes,
      };

    case 'memoryGrow':
      return {
        'value': _memory(
          instances,
          importedExterns,
          request,
        ).grow(request['deltaPages']! as int),
      };

    case 'readGlobal':
      return {
        'value': _sendable(
          _global(instances, importedExterns, request).value,
        ),
      };

    case 'writeGlobal':
      _global(instances, importedExterns, request).value = request['value'];
      return const {};

    case 'dispose':
      instances.clear();
      importedExterns.clear();
      for (final module in modules.values) {
        module.dispose();
      }
      modules.clear();
      store.dispose();
      engine.dispose();
      return const {};

    default:
      throw ArgumentError('unknown worker operation "$op"');
  }
}

WasmModule _module(Map<int, WasmModule> modules, Map<String, Object?> request) =>
    modules[request['moduleId']] ??
    (throw WasmtimeException('unknown module ${request['moduleId']}'));

WasmInstance _instance(
  Map<int, WasmInstance> instances,
  Map<String, Object?> request,
) =>
    instances[request['instanceId']] ??
    (throw WasmtimeException('unknown instance ${request['instanceId']}'));

/// The memory [request] names.
///
/// That is either a memory the instance exports, or one this instance imported
/// from a descriptor, which is named `"<module>.<name>"` because it is not an
/// export and cannot be reached through `instance.exports`.
WasmMemory _memory(
  Map<int, WasmInstance> instances,
  Map<int, Map<String, Object>> imported,
  Map<String, Object?> request,
) {
  final name = request['name']! as String;
  final value = _extern(instances, imported, request, name);
  if (value is! WasmMemory) {
    throw WasmtimeException('no memory named "$name" in this instance');
  }
  return value;
}

WasmGlobal _global(
  Map<int, WasmInstance> instances,
  Map<int, Map<String, Object>> imported,
  Map<String, Object?> request,
) {
  final name = request['name']! as String;
  final value = _extern(instances, imported, request, name);
  if (value is! WasmGlobal) {
    throw WasmtimeException('no global named "$name" in this instance');
  }
  return value;
}

Object? _extern(
  Map<int, WasmInstance> instances,
  Map<int, Map<String, Object>> imported,
  Map<String, Object?> request,
  String name,
) =>
    _instance(instances, request).export(name) ??
    imported[request['instanceId']]?[name];

Map<String, Map<String, Object?>> _imports(Object? value) {
  if (value == null) return const {};
  return (value as Map).map(
    (key, nested) => MapEntry(
      key as String,
      (nested as Map).cast<String, Object?>(),
    ),
  );
}

void _defineImport(
  WasmLinker linker,
  WasmStore store,
  WasmImport import,
  Map<String, Map<String, Object?>> imports,
  Map<String, Object> created,
) {
  final value = imports[import.module]?[import.name];
  if (value == null) {
    throw WasmtimeException(
      'missing import "${import.module}"."${import.name}" '
      '(${import.kind.wasmName})',
    );
  }
  final key = '${import.module}.${import.name}';
  switch (import.type) {
    case WasmFuncExternType(:final type):
      if (value is! Function) {
        throw WasmtimeException(
          'import "${import.module}"."${import.name}" must be a Function',
        );
      }
      linker.defineFunction(
        import.module,
        import.name,
        type,
        (arguments) => Function.apply(value, arguments),
      );
    case WasmMemoryExternType():
      if (value is! MemoryDescriptor) {
        throw WasmtimeException(
          'import "${import.module}"."${import.name}" must be a '
          'MemoryDescriptor across isolates',
        );
      }
      final memory = WasmMemory.create(
        store,
        initial: value.initial,
        maximum: value.maximum,
      );
      created[key] = memory;
      linker.defineMemory(import.module, import.name, store, memory);
    case WasmTableExternType(:final element):
      if (value is! TableDescriptor) {
        throw WasmtimeException(
          'import "${import.module}"."${import.name}" must be a '
          'TableDescriptor across isolates',
        );
      }
      linker.defineTable(
        import.module,
        import.name,
        store,
        WasmTable.create(
          store,
          element,
          initial: value.initial,
          maximum: value.maximum,
        ),
      );
    case WasmGlobalExternType(:final content):
      if (value is! GlobalDescriptor) {
        throw WasmtimeException(
          'import "${import.module}"."${import.name}" must be a '
          'GlobalDescriptor across isolates',
        );
      }
      final global = WasmGlobal.create(
        store,
        content,
        mutable: value.mutable,
        value: value.initialValue,
      );
      created[key] = global;
      linker.defineGlobal(import.module, import.name, store, global);
  }
}

String _kindOf(Object? value) => switch (value) {
  WasmFunc() => 'function',
  WasmMemory() => 'memory',
  WasmTable() => 'table',
  WasmGlobal() => 'global',
  _ => 'unknown',
};

Object? _collapse(List<Object?> results) {
  if (results.isEmpty) return null;
  if (results.length == 1) return results.first;
  return results;
}

/// Rejects anything the isolate boundary cannot carry.
Object? _sendable(Object? value) => switch (value) {
  null || bool() || int() || double() || String() || Uint8List() => value,
  List() => [for (final item in value) _sendable(item)],
  _ => throw WasmtimeException(
    'a ${value.runtimeType} result cannot cross the isolate boundary; '
    'read it through the memory or global accessors instead',
  ),
};

Map<String, Object?> _encodeImport(WasmImport import) => {
  'module': import.module,
  'name': import.name,
  'kind': import.kind.wasmName,
  'type': _encodeType(import.type),
};

Map<String, Object?> _encodeExport(WasmExport export) => {
  'name': export.name,
  'kind': export.kind.wasmName,
  'type': _encodeType(export.type),
};

Map<String, Object?> _encodeType(WasmExternType type) => switch (type) {
  WasmFuncExternType(:final type) => {
    'kind': 'function',
    'parameters': [for (final kind in type.parameters) kind.wasmName],
    'results': [for (final kind in type.results) kind.wasmName],
  },
  WasmGlobalExternType(:final content, :final mutable) => {
    'kind': 'global',
    'content': content.wasmName,
    'mutable': mutable,
  },
  WasmMemoryExternType(:final limits) => {
    'kind': 'memory',
    'minimum': limits.min,
    'maximum': limits.max,
  },
  WasmTableExternType(:final element, :final limits) => {
    'kind': 'table',
    'element': element.wasmName,
    'minimum': limits.min,
    'maximum': limits.max,
  },
};

WasmImport _decodeImport(Map<String, Object?> json) => WasmImport(
  module: json['module']! as String,
  name: json['name']! as String,
  type: _decodeType(json['type']! as Map),
);

WasmExport _decodeExport(Map<String, Object?> json) => WasmExport(
  name: json['name']! as String,
  type: _decodeType(json['type']! as Map),
);

WasmExternType _decodeType(Map<Object?, Object?> json) {
  final kind = json['kind'] as String;
  return switch (kind) {
    'function' => WasmFuncExternType(
      WasmFuncType(
        parameters: [
          for (final name in json['parameters']! as List)
            _kindOfName(name as String),
        ],
        results: [
          for (final name in json['results']! as List)
            _kindOfName(name as String),
        ],
      ),
    ),
    'global' => WasmGlobalExternType(
      content: _kindOfName(json['content']! as String),
      mutable: json['mutable']! as bool,
    ),
    'memory' => WasmMemoryExternType(
      limits: Limits(
        json['minimum']! as int,
        json['maximum'] as int?,
      ),
    ),
    'table' => WasmTableExternType(
      element: _kindOfName(json['element']! as String),
      limits: Limits(
        json['minimum']! as int,
        json['maximum'] as int?,
      ),
    ),
    _ => throw ArgumentError('unknown extern type "$kind"'),
  };
}

WasmValueKind _kindOfName(String name) {
  for (final kind in WasmValueKind.values) {
    if (kind.wasmName == name) return kind;
  }
  throw ArgumentError('unknown value kind "$name"');
}
