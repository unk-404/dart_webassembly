// The platform neutral vocabulary of the unified API.
//
// These types are compiled for every platform: the native backend (wasmtime)
// and the web backend (`dart:js_interop` on the browser's own `WebAssembly`)
// both speak them, and nothing here references either.

/// The base of every error the unified API throws.
class WasmException implements Exception {
  const WasmException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// `WebAssembly.CompileError`: the bytes are not a valid module.
final class CompileError extends WasmException {
  const CompileError(super.message);
}

/// `WebAssembly.LinkError`: the imports do not match what the module needs.
final class LinkError extends WasmException {
  const LinkError(super.message);
}

/// `WebAssembly.RuntimeError`: WebAssembly trapped while running.
final class RuntimeError extends WasmException {
  const RuntimeError(super.message);
}

/// `new WebAssembly.Memory({initial, maximum, shared})`.
final class MemoryDescriptor {
  const MemoryDescriptor({
    required this.initial,
    this.maximum,
    this.shared = false,
  });

  /// Initial size in 64 KiB pages.
  final int initial;

  /// Maximum size in 64 KiB pages, or null for "no declared maximum".
  final int? maximum;

  final bool shared;

  @override
  String toString() =>
      'MemoryDescriptor(initial: $initial, maximum: $maximum)';
}

/// `new WebAssembly.Table({element, initial, maximum})`.
final class TableDescriptor {
  const TableDescriptor({
    required this.element,
    required this.initial,
    this.maximum,
  });

  /// `'funcref'` or `'externref'`.
  final String element;
  final int initial;
  final int? maximum;

  @override
  String toString() =>
      'TableDescriptor(element: $element, initial: $initial, maximum: $maximum)';
}

/// `new WebAssembly.Global({value, mutable}, initialValue)`.
final class GlobalDescriptor {
  const GlobalDescriptor({
    required this.value,
    this.mutable = false,
    this.initialValue,
  });

  /// `'i32'`, `'i64'`, `'f32'`, `'f64'`, `'funcref'` or `'externref'`.
  final String value;
  final bool mutable;

  /// The initial value, so that a descriptor can carry everything a global
  /// needs.  JavaScript passes it as a second constructor argument, which is
  /// what `WebAssembly.global(descriptor, value)` does.
  final Object? initialValue;

  @override
  String toString() =>
      'GlobalDescriptor(value: $value, mutable: $mutable)';
}

/// One entry of `WebAssembly.Module.imports(module)`.
final class ImportDescriptor {
  const ImportDescriptor({
    required this.module,
    required this.name,
    required this.kind,
  });

  final String module;
  final String name;

  /// `'function'`, `'table'`, `'memory'` or `'global'`.
  final String kind;

  @override
  String toString() => '$module.$name ($kind)';
}

/// One entry of `WebAssembly.Module.exports(module)`.
final class ExportDescriptor {
  const ExportDescriptor({required this.name, required this.kind});

  final String name;

  /// `'function'`, `'table'`, `'memory'` or `'global'`.
  final String kind;

  @override
  String toString() => '$name ($kind)';
}

// ---------------------------------------------------------------------------
// What a backend hands back
// ---------------------------------------------------------------------------

/// A backend's view of one import or export of a module.
final class BackendDescriptor {
  const BackendDescriptor({required this.name, required this.kind, this.module});

  final String? module;
  final String name;
  final String kind;
}

/// A backend's view of one value exported by an instance.
final class BackendExport {
  const BackendExport(this.name, this.kind, {this.function, this.handle});

  final String name;
  final String kind;

  /// Set for `'function'`, so that a caller can simply call it.
  final Function? function;

  /// Set for `'memory'`, `'table'` and `'global'`; opaque to the caller.
  final Object? handle;
}
