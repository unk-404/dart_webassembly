// Layer 2 - the type model.
//
// Types are read into plain Dart objects; nativeness only exists for the
// duration of a call that needs a `wasm_functype_t`/`wasm_externtype_t`.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show Arena;

import '../ffi/marshal.dart';
import '../ffi/values.dart';
import '../wasmtime_bindings_generated.dart' as c;

/// A WebAssembly function signature: parameters and results.
final class WasmFuncType {
  const WasmFuncType({required this.parameters, required this.results});

  const WasmFuncType.empty() : parameters = const [], results = const [];

  final List<WasmValueKind> parameters;
  final List<WasmValueKind> results;

  /// Reads a borrowed `wasm_functype_t`.
  factory WasmFuncType.fromNative(ffi.Pointer<c.wasm_functype_t> type) =>
      WasmFuncType(
        parameters: _readValTypes(c.wasm_functype_params(type)),
        results: _readValTypes(c.wasm_functype_results(type)),
      );

  /// Calls [body] with a freshly allocated `wasm_functype_t`.
  ///
  /// The native type - and the value type vectors it owns - are released when
  /// [body] returns.
  T withNative<T>(T Function(ffi.Pointer<c.wasm_functype_t> type) body) =>
      scoped((arena) {
        final type = c.wasm_functype_new(
          _writeValTypes(arena, parameters),
          _writeValTypes(arena, results),
        );
        try {
          return body(type);
        } finally {
          c.wasm_functype_delete(type);
        }
      });

  @override
  String toString() =>
      '(${parameters.map((k) => k.wasmName).join(', ')})'
      ' -> (${results.map((k) => k.wasmName).join(', ')})';
}

/// What kind of thing an import or an export is.
enum WasmExternKind {
  func(c.WASMTIME_EXTERN_FUNC, 'function'),
  global(c.WASMTIME_EXTERN_GLOBAL, 'global'),
  table(c.WASMTIME_EXTERN_TABLE, 'table'),
  memory(c.WASMTIME_EXTERN_MEMORY, 'memory'),
  sharedMemory(c.WASMTIME_EXTERN_SHAREDMEMORY, 'shared-memory'),
  tag(c.WASMTIME_EXTERN_TAG, 'tag');

  const WasmExternKind(this.cKind, this.wasmName);

  final int cKind;
  final String wasmName;

  static WasmExternKind fromC(int kind) {
    for (final value in values) {
      if (value.cKind == kind) return value;
    }
    throw UnsupportedError('Unknown extern kind $kind');
  }
}

/// The type of an import or an export.
sealed class WasmExternType {
  const WasmExternType();

  WasmExternKind get kind;

  /// Reads a borrowed `wasm_externtype_t`.
  static WasmExternType fromNative(ffi.Pointer<c.wasm_externtype_t> type) {
    final kind = WasmExternKind.fromC(c.wasm_externtype_kind(type));
    switch (kind) {
      case WasmExternKind.func:
        return WasmFuncExternType(
          WasmFuncType.fromNative(c.wasm_externtype_as_functype(type)),
        );
      case WasmExternKind.global:
        final global = c.wasm_externtype_as_globaltype(type);
        return WasmGlobalExternType(
          content: WasmValueKind.fromWasmKind(
            c.wasm_valtype_kind(c.wasm_globaltype_content(global)),
          ),
          mutable: c.wasm_globaltype_mutability(global) != 0,
        );
      case WasmExternKind.memory:
      case WasmExternKind.sharedMemory:
        return WasmMemoryExternType(
          limits: _readLimits(
            c.wasm_memorytype_limits(c.wasm_externtype_as_memorytype(type)),
          ),
        );
      case WasmExternKind.table:
        final table = c.wasm_externtype_as_tabletype(type);
        return WasmTableExternType(
          element: WasmValueKind.fromWasmKind(
            c.wasm_valtype_kind(c.wasm_tabletype_element(table)),
          ),
          limits: _readLimits(c.wasm_tabletype_limits(table)),
        );
      case WasmExternKind.tag:
        throw UnsupportedError('Exception tags are not supported.');
    }
  }
}

/// A function import or export, with the type WebAssembly declares for it.
final class WasmFuncExternType extends WasmExternType {
  const WasmFuncExternType(this.type);

  final WasmFuncType type;

  @override
  WasmExternKind get kind => WasmExternKind.func;

  @override
  String toString() => 'function $type';
}

/// A global import or export.
final class WasmGlobalExternType extends WasmExternType {
  const WasmGlobalExternType({required this.content, required this.mutable});

  final WasmValueKind content;
  final bool mutable;

  @override
  WasmExternKind get kind => WasmExternKind.global;

  @override
  String toString() => 'global $content (mutable: $mutable)';
}

/// A memory import or export.
final class WasmMemoryExternType extends WasmExternType {
  const WasmMemoryExternType({required this.limits});

  final Limits limits;

  @override
  WasmExternKind get kind => WasmExternKind.memory;

  @override
  String toString() => 'memory $limits';
}

/// A table import or export.
final class WasmTableExternType extends WasmExternType {
  const WasmTableExternType({required this.element, required this.limits});

  final WasmValueKind element;
  final Limits limits;

  @override
  WasmExternKind get kind => WasmExternKind.table;

  @override
  String toString() => 'table $element $limits';
}

/// One entry of a module's import list.
final class WasmImport {
  const WasmImport({
    required this.module,
    required this.name,
    required this.type,
  });

  final String module;
  final String name;
  final WasmExternType type;

  WasmExternKind get kind => type.kind;

  @override
  String toString() => '$module.$name: $type';
}

/// One entry of a module's export list.
final class WasmExport {
  const WasmExport({required this.name, required this.type});

  final String name;
  final WasmExternType type;

  WasmExternKind get kind => type.kind;

  @override
  String toString() => '$name: $type';
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

List<WasmValueKind> _readValTypes(ffi.Pointer<c.wasm_valtype_vec_t> vec) {
  final ref = vec.ref;
  if (ref.size == 0) return const [];
  return <WasmValueKind>[
    for (var i = 0; i < ref.size; i++)
      WasmValueKind.fromWasmKind(c.wasm_valtype_kind(ref.data[i])),
  ];
}

ffi.Pointer<c.wasm_valtype_vec_t> _writeValTypes(
  Arena arena,
  List<WasmValueKind> kinds,
) {
  final out = arena<c.wasm_valtype_vec_t>();
  if (kinds.isEmpty) {
    c.wasm_valtype_vec_new_empty(out);
    return out;
  }
  final elements = arena<ffi.Pointer<c.wasm_valtype_t>>(kinds.length);
  for (var i = 0; i < kinds.length; i++) {
    elements[i] = c.wasm_valtype_new(kinds[i].wasmKind);
  }
  // The vector takes ownership of the value types (and `wasm_functype_new`
  // takes ownership of the vector), so only the function type is deleted.
  c.wasm_valtype_vec_new(out, kinds.length, elements);
  return out;
}

Limits _readLimits(ffi.Pointer<c.wasm_limits_t> limits) => Limits(
  limits.ref.min,
  limits.ref.max == c.wasm_limits_max_default ? null : limits.ref.max,
);
