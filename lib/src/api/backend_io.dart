// The unified API on native platforms, backed by wasmtime.
//
// Selected automatically by `webassembly.dart` through a conditional import;
// never imported directly.  Every function here has a counterpart in
// `backend_web.dart` with the same signature.

import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/errors.dart';
import '../ffi/values.dart' show WasmValueKind;
import '../wasmtime/engine.dart';
import '../wasmtime/handles.dart';
import '../wasmtime/instance.dart';
import '../wasmtime/linker.dart';
import '../wasmtime/module.dart';
import '../wasmtime/store.dart';
import '../wasmtime/types.dart';
import 'types.dart';

// ---------------------------------------------------------------------------
// The realm backing the unified API
// ---------------------------------------------------------------------------

/// The engine, store and objects the unified API works with.
///
/// JavaScript has one implicit realm per `WebAssembly` namespace, so this one
/// is created lazily and lives as long as the process (or until
/// [disposeDefaultRealm]).
final class _Realm {
  _Realm() {
    engine = WasmEngine();
    store = WasmStore(engine);
  }

  late final WasmEngine engine;
  late final WasmStore store;
}

_Realm? _realm;

_Realm get _default => _realm ??= _Realm();

/// Releases the realm's engine and store.
void disposeDefaultRealm() {
  final realm = _realm;
  _realm = null;
  realm?.store.dispose();
  realm?.engine.dispose();
}

// ---------------------------------------------------------------------------
// Functions produced by the backend
// ---------------------------------------------------------------------------

/// Maps an adapter [Function] back to the [WasmFunc] it calls, so that a
/// function taken out of one table or instance can be put into another.
final Expando<WasmFunc> _functions = Expando<WasmFunc>();

/// Marks an argument that was not supplied.
const Object _absent = Object();

/// A Dart [Function] that calls [func].
///
/// The bridge accepts optional arguments (Dart has no variadic functions) and
/// forwards only the ones that were actually supplied, so that `f()`, `f(1)`
/// and `f(1, 2)` all work - the same shape the web backend produces.
///
/// wasmtime's own failures are translated here: a trap becomes a [RuntimeError]
/// and anything else that goes wrong while running becomes one too, so that the
/// unified API reports the same errors on every platform.
Function _adapterFor(WasmFunc func) {
  Object? bridge([
    Object? a0 = _absent,
    Object? a1 = _absent,
    Object? a2 = _absent,
    Object? a3 = _absent,
    Object? a4 = _absent,
    Object? a5 = _absent,
    Object? a6 = _absent,
    Object? a7 = _absent,
  ]) {
    final all = <Object?>[a0, a1, a2, a3, a4, a5, a6, a7];
    var count = all.length;
    while (count > 0 && identical(all[count - 1], _absent)) {
      count--;
    }
    try {
      return _neutralValue(func.invoke(all.sublist(0, count)));
    } on WasmTrapException catch (error) {
      throw RuntimeError(error.message);
    } on WasmtimeException catch (error) {
      throw RuntimeError(error.message);
    }
  }

  _functions[bridge] = func;
  return bridge;
}

/// Turns anything wasmtime specific into what the unified API promises.
Object? _neutralValue(Object? value) =>
    value is WasmFunc ? _adapterFor(value) : value;

// ---------------------------------------------------------------------------
// Backend surface
// ---------------------------------------------------------------------------

bool validate(Uint8List bytes) => _default.engine.validate(bytes);

Future<Object> compile(Uint8List bytes) async {
  final realm = _default;
  try {
    // Compiling can take a while for a large module, so do it on a worker
    // isolate and load the resulting artifact here; the wasmtime artifact is a
    // faithful stand-in for `WebAssembly.Module`'s background compilation.
    final blob = await Isolate.run(() => _compileToBlob(bytes));
    try {
      return WasmModule.deserialize(realm.engine, blob);
    } on WasmtimeException {
      // A custom engine configuration cannot load the default artifact; fall
      // back to compiling here.
      return realm.engine.compile(bytes);
    }
  } on WasmtimeException catch (error) {
    throw CompileError(error.message);
  }
}

Future<(Object, Object)> instantiateBytes(
  Uint8List bytes,
  Map<String, Map<String, Object?>> imports,
) async {
  final module = await compile(bytes);
  return (module, _instantiate(module, imports));
}

Future<Object> instantiate(
  Object module,
  Map<String, Map<String, Object?>> imports,
) async => _instantiate(module, imports);

Object _instantiate(
  Object module,
  Map<String, Map<String, Object?>> imports,
) {
  final realm = _default;
  final native = module as WasmModule;
  final linker = WasmLinker(realm.engine);
  try {
    for (final import in native.imports) {
      _defineImport(linker, import, imports);
    }
    return linker.instantiate(realm.store, native);
  } on WasmtimeException catch (error) {
    throw LinkError(error.message);
  } on WasmTrapException catch (error) {
    // A start function trapped.
    throw RuntimeError(error.message);
  } finally {
    linker.dispose();
  }
}

List<BackendDescriptor> moduleImports(Object module) => [
  for (final import in (module as WasmModule).imports)
    BackendDescriptor(
      module: import.module,
      name: import.name,
      kind: import.kind.wasmName,
    ),
];

List<BackendDescriptor> moduleExports(Object module) => [
  for (final export in (module as WasmModule).exports)
    BackendDescriptor(name: export.name, kind: export.kind.wasmName),
];

List<BackendExport> instanceExports(Object instance) => [
  for (final entry in (instance as WasmInstance).exports.entries)
    _describe(entry.key, entry.value),
];

BackendExport? instanceExport(Object instance, String name) {
  final value = (instance as WasmInstance).export(name);
  if (value == null) return null;
  return _describe(name, value);
}

BackendExport _describe(String name, Object? value) => switch (value) {
  WasmFunc() => BackendExport(
    name,
    'function',
    function: _adapterFor(value),
  ),
  WasmMemory() => BackendExport(name, 'memory', handle: value),
  WasmGlobal() => BackendExport(name, 'global', handle: value),
  WasmTable() => BackendExport(name, 'table', handle: value),
  _ => BackendExport(name, 'unknown', handle: value),
};

// ---------------------------------------------------------------------------
// Memory, globals and tables
// ---------------------------------------------------------------------------

Object createMemory(MemoryDescriptor descriptor) {
  try {
    return WasmMemory.create(
      _default.store,
      initial: descriptor.initial,
      maximum: descriptor.maximum,
    );
  } on WasmtimeException catch (error) {
    throw RangeError(error.message);
  }
}

int memoryLengthBytes(Object memory) => (memory as WasmMemory).lengthInBytes;

int memoryLengthPages(Object memory) => (memory as WasmMemory).lengthInPages;

Uint8List memoryBuffer(Object memory) => (memory as WasmMemory).buffer;

int memoryGrow(Object memory, int deltaPages) {
  try {
    return (memory as WasmMemory).grow(deltaPages);
  } on WasmtimeException catch (error) {
    throw RangeError(error.message);
  }
}

Object createGlobal(GlobalDescriptor descriptor, Object? initialValue) {
  final kind = _valueKind(descriptor.value);
  return WasmGlobal.create(
    _default.store,
    kind,
    mutable: descriptor.mutable,
    value: toNativeValue(kind, initialValue ?? descriptor.initialValue),
  );
}

Object? globalValue(Object global) => (global as WasmGlobal).value;

void setGlobalValue(Object global, Object? value) {
  final native = global as WasmGlobal;
  if (!native.type.mutable) throw TypeError();
  try {
    native.value = value;
  } on Object {
    throw TypeError();
  }
}

Object createTable(TableDescriptor descriptor, Object? initialValue) {
  try {
    return WasmTable.create(
      _default.store,
      _valueKind(descriptor.element),
      initial: descriptor.initial,
      maximum: descriptor.maximum,
      fill: _tableValue(initialValue),
    );
  } on WasmtimeException catch (error) {
    throw RangeError(error.message);
  }
}

int tableLength(Object table) => (table as WasmTable).length;

Object? tableGet(Object table, int index) {
  final value = (table as WasmTable).get(index);
  return value is WasmFunc ? _adapterFor(value) : null;
}

void tableSet(Object table, int index, Object? value) =>
    (table as WasmTable).set(index, _tableValue(value));

int tableGrow(Object table, int delta, Object? initialValue) =>
    (table as WasmTable).grow(delta, _tableValue(initialValue));

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Uint8List _compileToBlob(Uint8List bytes) {
  final engine = WasmEngine();
  try {
    final module = WasmModule.compile(engine, bytes);
    try {
      return module.serialize();
    } finally {
      module.dispose();
    }
  } finally {
    engine.dispose();
  }
}

void _defineImport(
  WasmLinker linker,
  WasmImport import,
  Map<String, Map<String, Object?>> importObject,
) {
  final value = importObject[import.module]?[import.name];
  if (value == null) {
    throw WasmtimeException(
      'Missing import "${import.module}"."${import.name}" '
      '(${import.kind.wasmName})',
    );
  }
  final store = _default.store;
  switch (import.type) {
    case WasmFuncExternType(:final type):
      if (value is! Function) {
        throw WasmtimeException(
          'Import "${import.module}"."${import.name}" must be a Function, '
          'got ${value.runtimeType}',
        );
      }
      linker.defineFunction(
        import.module,
        import.name,
        type,
        (arguments) => Function.apply(value, arguments),
      );
    case WasmMemoryExternType():
      if (value is! WasmMemory) {
        throw WasmtimeException(
          'Import "${import.module}"."${import.name}" must be a Memory',
        );
      }
      linker.defineMemory(import.module, import.name, store, value);
    case WasmGlobalExternType():
      if (value is! WasmGlobal) {
        throw WasmtimeException(
          'Import "${import.module}"."${import.name}" must be a Global',
        );
      }
      linker.defineGlobal(import.module, import.name, store, value);
    case WasmTableExternType():
      if (value is! WasmTable) {
        throw WasmtimeException(
          'Import "${import.module}"."${import.name}" must be a Table',
        );
      }
      linker.defineTable(import.module, import.name, store, value);
  }
}

Object? _tableValue(Object? value) {
  if (value is WasmFunc || value == null) return value;
  if (value is Function) {
    final func = _functions[value];
    if (func == null) {
      throw TypeError();
    }
    return func;
  }
  throw TypeError();
}

WasmValueKind _valueKind(String name) => switch (name) {
  'i32' => WasmValueKind.i32,
  'i64' => WasmValueKind.i64,
  'f32' => WasmValueKind.f32,
  'f64' => WasmValueKind.f64,
  'funcref' || 'anyfunc' => WasmValueKind.funcRef,
  'externref' => WasmValueKind.externRef,
  _ => throw RangeError('Unknown value type "$name"'),
};
