// The unified API.
//
// One API, two backends, chosen automatically at compile time: wasmtime on
// native platforms, the browser's own `WebAssembly` on the web.  Nothing in
// this file (or in the types it exposes) mentions either of them, so the same
// Dart code runs in both places:
//
// ```dart
// import 'package:webassembly/webassembly.dart';
//
// final module = await WebAssembly.compile(wasmBytes);
// final instance = await WebAssembly.instantiate(module, {
//   'env': {'log': (int value) => print(value)},
// });
// print((instance.exports['add'] as Function)(20, 22));
// ```
//
// wasmtime specific things - engines, stores, links, configuration, fuel, host
// function trampolines, module serialisation, and running on other isolates -
// are deliberately *not* here; see `package:webassembly/wasmtime.dart` and
// `package:webassembly/parallel.dart`.

import 'dart:typed_data';

import 'backend_io.dart'
    if (dart.library.js_interop) 'backend_web.dart'
    as backend;
import 'types.dart';

export 'types.dart'
    show
        CompileError,
        ExportDescriptor,
        GlobalDescriptor,
        ImportDescriptor,
        LinkError,
        MemoryDescriptor,
        RuntimeError,
        TableDescriptor,
        WasmException;

/// What `WebAssembly.instantiate(bytes, ...)` resolves to.
final class InstantiatedModule {
  const InstantiatedModule({required this.module, required this.instance});

  final Module module;
  final Instance instance;
}

/// The `WebAssembly` namespace.
abstract final class WebAssembly {
  /// `WebAssembly.validate(bytes)`.
  static bool validate(Uint8List bytes) => backend.validate(bytes);

  /// `WebAssembly.compile(bytes)`.
  ///
  /// On native platforms the module is compiled on a worker isolate, so a large
  /// module does not block the calling isolate; on the web the browser does the
  /// same thing behind its own promise.
  static Future<Module> compile(Uint8List bytes) async =>
      Module._(await backend.compile(bytes));

  /// `WebAssembly.instantiate(module, importObject)`.
  static Future<Instance> instantiate(
    Module module, [
    Map<String, Map<String, Object?>> importObject = const {},
  ]) async => Instance._(
    await backend.instantiate(module._handle, _nativeImports(importObject)),
  );

  /// `WebAssembly.instantiate(bytes, importObject)`, which also hands back the
  /// module it compiled.
  static Future<InstantiatedModule> instantiateBytes(
    Uint8List bytes, [
    Map<String, Map<String, Object?>> importObject = const {},
  ]) async {
    final (module, instance) = await backend.instantiateBytes(
      bytes,
      _nativeImports(importObject),
    );
    return InstantiatedModule(
      module: Module._(module),
      instance: Instance._(instance),
    );
  }

  /// `new WebAssembly.Memory({initial, maximum})`.
  static Memory memory(MemoryDescriptor descriptor) =>
      Memory._(backend.createMemory(descriptor));

  /// `new WebAssembly.Table({element, initial, maximum})`.
  static Table table(TableDescriptor descriptor, [Object? initialValue]) =>
      Table._(backend.createTable(descriptor, _nativeValue(initialValue)));

  /// `new WebAssembly.Global({value, mutable}, initialValue)`.
  static Global global(GlobalDescriptor descriptor, [Object? initialValue]) =>
      Global._(backend.createGlobal(descriptor, _nativeValue(initialValue)));

  /// Releases whatever the backend holds for this API.
  ///
  /// The browser owns its realm, so this does nothing there; on native
  /// platforms it releases the engine and store created for the unified API.
  static void disposeDefaultRealm() => backend.disposeDefaultRealm();
}

/// A compiled WebAssembly module (`WebAssembly.Module`).
final class Module {
  Module._(this._handle);

  final Object _handle;

  /// `WebAssembly.Module.imports(module)`.
  List<ImportDescriptor> get imports => [
    for (final descriptor in backend.moduleImports(_handle))
      ImportDescriptor(
        module: descriptor.module ?? '',
        name: descriptor.name,
        kind: descriptor.kind,
      ),
  ];

  /// `WebAssembly.Module.exports(module)`.
  List<ExportDescriptor> get exports => [
    for (final descriptor in backend.moduleExports(_handle))
      ExportDescriptor(name: descriptor.name, kind: descriptor.kind),
  ];

  @override
  String toString() => 'Module(${exports.length} exports)';
}

/// An instance of a [Module] (`WebAssembly.Instance`).
final class Instance {
  Instance._(this._handle);

  final Object _handle;

  /// `instance.exports`: functions are callable Dart [Function]s, memories,
  /// tables and globals are the matching objects.
  Map<String, Object?> get exports => {
    for (final export in backend.instanceExports(_handle))
      export.name: _wrap(export),
  };

  /// The named export, or null.
  Object? operator [](String name) {
    final export = backend.instanceExport(_handle, name);
    return export == null ? null : _wrap(export);
  }

  Object? _wrap(BackendExport export) =>
      export.function ??
      switch (export.kind) {
        'memory' => Memory._(export.handle!),
        'global' => Global._(export.handle!),
        'table' => Table._(export.handle!),
        _ => export.handle,
      };

  @override
  String toString() => 'Instance(${exports.keys.join(', ')})';
}

/// A WebAssembly linear memory (`WebAssembly.Memory`).
final class Memory {
  Memory._(this._handle);

  /// `new WebAssembly.Memory({initial, maximum})`.
  factory Memory({required int initial, int? maximum, bool shared = false}) =>
      WebAssembly.memory(
        MemoryDescriptor(initial: initial, maximum: maximum, shared: shared),
      );

  final Object _handle;

  /// The number of bytes, like `memory.buffer.byteLength`.
  int get lengthInBytes => backend.memoryLengthBytes(_handle);

  /// The size in 64 KiB pages.
  int get lengthInPages => backend.memoryLengthPages(_handle);

  /// `memory.buffer`.
  ///
  /// As in JavaScript the view is invalidated by [grow]: ask for [buffer]
  /// again afterwards.
  Uint8List get buffer => backend.memoryBuffer(_handle);

  /// `memory.grow(delta)`, returning the previous size in pages.
  ///
  /// Throws a [RangeError] when the memory cannot grow.
  int grow(int deltaPages) => backend.memoryGrow(_handle, deltaPages);

  @override
  String toString() => 'Memory($lengthInPages pages)';
}

/// A WebAssembly global (`WebAssembly.Global`).
final class Global {
  Global._(this._handle);

  /// `new WebAssembly.Global({value, mutable}, initialValue)`.
  factory Global(GlobalDescriptor descriptor, [Object? initialValue]) =>
      WebAssembly.global(descriptor, initialValue);

  final Object _handle;

  /// `global.value`.
  Object? get value => backend.globalValue(_handle);

  /// `global.value = v`; assigning to an immutable global throws a [TypeError],
  /// as in JavaScript.
  set value(Object? newValue) => backend.setGlobalValue(_handle, newValue);

  /// `global.valueOf()`.
  Object? valueOf() => value;

  @override
  String toString() => 'Global(value: $value)';
}

/// A WebAssembly table (`WebAssembly.Table`).
final class Table {
  Table._(this._handle);

  /// `new WebAssembly.Table({element, initial, maximum}, initialValue)`.
  factory Table(TableDescriptor descriptor, [Object? initialValue]) =>
      WebAssembly.table(descriptor, initialValue);

  final Object _handle;

  /// `table.length`.
  int get length => backend.tableLength(_handle);

  /// `table.get(index)`: the function at [index], or null.
  Object? get(int index) => backend.tableGet(_handle, index);

  /// `table.set(index, value)`, where [value] is null or a function that came
  /// from a table or from [Instance.exports].
  void set(int index, Object? value) =>
      backend.tableSet(_handle, index, _nativeValue(value));

  /// `table.grow(delta)`, returning the previous length.
  int grow(int delta, [Object? initialValue]) =>
      backend.tableGrow(_handle, delta, _nativeValue(initialValue));

  @override
  String toString() => 'Table($length entries)';
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Map<String, Map<String, Object?>> _nativeImports(
  Map<String, Map<String, Object?>> importObject,
) => {
  for (final entry in importObject.entries)
    entry.key: {
      for (final inner in entry.value.entries)
        inner.key: _nativeValue(inner.value),
    },
};

/// Replaces a wrapper by the handle its backend knows.
Object? _nativeValue(Object? value) {
  if (value is Memory) return value._handle;
  if (value is Global) return value._handle;
  if (value is Table) return value._handle;
  return value;
}
