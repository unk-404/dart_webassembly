// Layer 2 - the objects WebAssembly instances hand out.
//
// `wasmtime_func_t`, `wasmtime_memory_t`, `wasmtime_global_t` and
// `wasmtime_table_t` are values, not resources: nothing has to be released and
// they stay valid for as long as their store lives.  The wrappers here add the
// store they belong to, so that every operation has a context to pass.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show Arena;

import '../ffi/errors.dart';
import '../ffi/marshal.dart';
import '../ffi/values.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'store.dart';
import 'types.dart';

/// A WebAssembly function.
final class WasmFunc {
  WasmFunc._(this.store, this.handle);

  /// The store the function lives in.
  final WasmStore store;

  /// The raw handle, which is safe to copy and to send to another isolate.
  final FuncHandle handle;

  static WasmFunc? fromHandle(WasmStore store, FuncHandle handle) =>
      handle.isNull ? null : WasmFunc._(store, handle);

  ffi.Pointer<c.wasmtime_func_t> _native(Arena arena) {
    final out = arena<c.wasmtime_func_t>();
    writeFuncHandle(out.ref, handle);
    return out;
  }

  /// The function's signature.
  WasmFuncType get type => scoped((arena) {
    final native = c.wasmtime_func_type(store.context, _native(arena));
    try {
      return WasmFuncType.fromNative(native);
    } finally {
      c.wasm_functype_delete(native);
    }
  });

  /// Calls the function with [arguments] and returns its results.
  ///
  /// Arguments are coerced according to the signature; a single result is still
  /// returned as a one element list, use [invoke] for the ergonomic form.
  List<Object?> call(List<Object?> arguments) {
    final signature = type;
    if (arguments.length != signature.parameters.length) {
      throw ArgumentError.value(
        arguments,
        'arguments',
        'expected ${signature.parameters.length} arguments for $signature',
      );
    }
    return scoped((arena) {
      final args = arena<c.wasmtime_val_t>(signature.parameters.length);
      for (var i = 0; i < arguments.length; i++) {
        final kind = signature.parameters[i];
        writeValue(args + i, kind, toNativeValue(kind, arguments[i]));
      }
      final results = arena<c.wasmtime_val_t>(signature.results.length);
      final trapOut = arena<ffi.Pointer<c.wasm_trap_t>>();

      clearHostException();
      final error = c.wasmtime_func_call(
        store.context,
        _native(arena),
        args,
        arguments.length,
        results,
        signature.results.length,
        trapOut,
      );
      if (error != ffi.nullptr || trapOut.value != ffi.nullptr) {
        // A host function that threw is more informative than the trap.
        rethrowHostException();
        throwExecutionFailure(error, trapOut.value);
      }

      final out = <Object?>[];
      for (var i = 0; i < signature.results.length; i++) {
        final kind = signature.results[i];
        out.add(toDartValue(store, kind, readValue(results + i)));
        // Reference results arrive rooted and have to be released again.
        unrootValue(results + i);
      }
      return out;
    });
  }

  /// Calls the function, collapsing the result list the way JavaScript does:
  /// no results gives null, one result gives the value itself and several
  /// results give the list.
  Object? invoke(List<Object?> arguments) {
    final results = call(arguments);
    if (results.isEmpty) return null;
    if (results.length == 1) return results.first;
    return results;
  }

  /// A [Function] of the right arity that calls this function.
  ///
  /// This is what makes `instance.exports` look like the JavaScript API:
  /// `(exports['add'] as Function)(1, 2)`.
  Function get function => _functionFor(this);

  @override
  String toString() => 'WasmFunc($handle)';
}

/// A WebAssembly linear memory.
final class WasmMemory {
  WasmMemory._(this.store, this.handle);

  /// Creates a new memory in [store].
  factory WasmMemory.create(
    WasmStore store, {
    required int initial,
    int? maximum,
  }) => scoped((arena) {
    final limits = arena<c.wasm_limits_t>()
      ..ref.min = initial
      ..ref.max = maximum ?? c.wasm_limits_max_default;
    final type = c.wasm_memorytype_new(limits);
    try {
      final out = arena<c.wasmtime_memory_t>();
      throwIfError(c.wasmtime_memory_new(store.context, type, out));
      return WasmMemory._(store, readMemoryHandle(out.ref));
    } finally {
      c.wasm_memorytype_delete(type);
    }
  });

  final WasmStore store;
  final MemoryHandle handle;

  ffi.Pointer<c.wasmtime_memory_t> _native(Arena arena) {
    final out = arena<c.wasmtime_memory_t>();
    writeMemoryHandle(out.ref, handle);
    return out;
  }

  /// The size of the memory in bytes.
  int get lengthInBytes =>
      scoped((arena) => c.wasmtime_memory_data_size(store.context, _native(arena)));

  /// The size of the memory in 64 KiB pages.
  int get lengthInPages =>
      scoped((arena) => c.wasmtime_memory_size(store.context, _native(arena)));

  /// The size of one page in bytes.
  int get pageSize =>
      scoped((arena) => c.wasmtime_memory_page_size(store.context, _native(arena)));

  /// The memory contents, as a view onto the native memory.
  ///
  /// Like `WebAssembly.Memory.prototype.buffer` in JavaScript, the view becomes
  /// invalid when the memory grows: ask for [buffer] again afterwards.
  ///
  /// For a 64 bit or shared memory this view is not available.
  Uint8List get buffer => scoped((arena) {
    final native = _native(arena);
    final data = c.wasmtime_memory_data(store.context, native);
    if (data == ffi.nullptr) {
      throw StateError(
        'This memory has no linear byte buffer (it is shared or 64 bit).',
      );
    }
    return data.asTypedList(c.wasmtime_memory_data_size(store.context, native));
  });

  /// Grows the memory by [deltaPages] pages, returning the previous size in
  /// pages.  Throws a [WasmtimeException] when the memory cannot grow.
  int grow(int deltaPages) => scoped((arena) {
    final previous = arena<ffi.Uint64>();
    throwIfError(
      c.wasmtime_memory_grow(store.context, _native(arena), deltaPages, previous),
    );
    return previous.value;
  });

  /// The declared limits of the memory.
  WasmMemoryExternType get type => scoped((arena) {
    final native = c.wasmtime_memory_type(store.context, _native(arena));
    try {
      final limits = c.wasm_memorytype_limits(native).ref;
      return WasmMemoryExternType(
        limits: Limits(
          limits.min,
          limits.max == c.wasm_limits_max_default ? null : limits.max,
        ),
      );
    } finally {
      c.wasm_memorytype_delete(native);
    }
  });

  @override
  String toString() => 'WasmMemory($lengthInPages pages)';
}

/// A WebAssembly global variable.
final class WasmGlobal {
  WasmGlobal._(this.store, this.handle);

  /// Creates a new global in [store].
  factory WasmGlobal.create(
    WasmStore store,
    WasmValueKind type, {
    required bool mutable,
    Object? value,
  }) => scoped((arena) {
    // `wasm_globaltype_new` takes ownership of the value type.
    final globalType = c.wasm_globaltype_new(
      c.wasm_valtype_new(type.wasmKind),
      mutable ? 1 : 0,
    );
    try {
      final initial = arena<c.wasmtime_val_t>();
      writeValue(initial, type, value);
      final out = arena<c.wasmtime_global_t>();
      throwIfError(
        c.wasmtime_global_new(store.context, globalType, initial, out),
      );
      return WasmGlobal._(store, readGlobalHandle(out.ref));
    } finally {
      c.wasm_globaltype_delete(globalType);
    }
  });

  final WasmStore store;
  final GlobalHandle handle;

  ffi.Pointer<c.wasmtime_global_t> _native(Arena arena) {
    final out = arena<c.wasmtime_global_t>();
    writeGlobalHandle(out.ref, handle);
    return out;
  }

  /// The declared type of the global.
  WasmGlobalExternType get type => scoped((arena) {
    final native = c.wasmtime_global_type(store.context, _native(arena));
    try {
      return WasmGlobalExternType(
        content: WasmValueKind.fromWasmKind(
          c.wasm_valtype_kind(c.wasm_globaltype_content(native)),
        ),
        mutable: c.wasm_globaltype_mutability(native) != 0,
      );
    } finally {
      c.wasm_globaltype_delete(native);
    }
  });

  /// The current value.
  Object? get value => scoped((arena) {
    final out = arena<c.wasmtime_val_t>();
    c.wasmtime_global_get(store.context, _native(arena), out);
    final kind = WasmValueKind.fromCKind(out.ref.kind);
    final value = toDartValue(store, kind, readValue(out));
    unrootValue(out);
    return value;
  });

  /// Sets the value.  Throws for an immutable global.
  set value(Object? newValue) => scoped((arena) {
    final kind = type.content;
    final slot = arena<c.wasmtime_val_t>();
    writeValue(slot, kind, toNativeValue(kind, newValue));
    throwIfError(c.wasmtime_global_set(store.context, _native(arena), slot));
  });

  @override
  String toString() => 'WasmGlobal(${type.content})';
}

/// A WebAssembly table.
final class WasmTable {
  WasmTable._(this.store, this.handle);

  /// Creates a new table in [store].
  factory WasmTable.create(
    WasmStore store,
    WasmValueKind element, {
    required int initial,
    int? maximum,
    Object? fill,
  }) => scoped((arena) {
    final limits = arena<c.wasm_limits_t>()
      ..ref.min = initial
      ..ref.max = maximum ?? c.wasm_limits_max_default;
    // `wasm_tabletype_new` takes ownership of the element type.
    final tableType = c.wasm_tabletype_new(
      c.wasm_valtype_new(element.wasmKind),
      limits,
    );
    try {
      final init = arena<c.wasmtime_val_t>();
      writeValue(init, element, fill);
      final out = arena<c.wasmtime_table_t>();
      throwIfError(c.wasmtime_table_new(store.context, tableType, init, out));
      return WasmTable._(store, readTableHandle(out.ref));
    } finally {
      c.wasm_tabletype_delete(tableType);
    }
  });

  final WasmStore store;
  final TableHandle handle;

  ffi.Pointer<c.wasmtime_table_t> _native(Arena arena) {
    final out = arena<c.wasmtime_table_t>();
    writeTableHandle(out.ref, handle);
    return out;
  }

  /// The declared type of the table.
  WasmTableExternType get type => scoped((arena) {
    final native = c.wasmtime_table_type(store.context, _native(arena));
    try {
      final limits = c.wasm_tabletype_limits(native).ref;
      return WasmTableExternType(
        element: WasmValueKind.fromWasmKind(
          c.wasm_valtype_kind(c.wasm_tabletype_element(native)),
        ),
        limits: Limits(
          limits.min,
          limits.max == c.wasm_limits_max_default ? null : limits.max,
        ),
      );
    } finally {
      c.wasm_tabletype_delete(native);
    }
  });

  /// The number of entries.
  int get length =>
      scoped((arena) => c.wasmtime_table_size(store.context, _native(arena)));

  /// The entry at [index].  Throws a [RangeError] when out of bounds.
  Object? get(int index) => scoped((arena) {
    final out = arena<c.wasmtime_val_t>();
    final found = c.wasmtime_table_get(
      store.context,
      _native(arena),
      index,
      out,
    );
    if (!found) {
      throw RangeError.index(index, this, 'index', null, length);
    }
    final kind = WasmValueKind.fromCKind(out.ref.kind);
    final value = toDartValue(store, kind, readValue(out));
    unrootValue(out);
    return value;
  });

  /// Stores [value] at [index].
  void set(int index, Object? value) => scoped((arena) {
    final kind = type.element;
    final slot = arena<c.wasmtime_val_t>();
    writeValue(slot, kind, toNativeValue(kind, value));
    throwIfError(
      c.wasmtime_table_set(store.context, _native(arena), index, slot),
    );
  });

  /// Appends [delta] entries initialised to [initialValue], returning the
  /// previous length.
  int grow(int delta, [Object? initialValue]) => scoped((arena) {
    final kind = type.element;
    final init = arena<c.wasmtime_val_t>();
    writeValue(init, kind, toNativeValue(kind, initialValue));
    final previous = arena<ffi.Uint64>();
    throwIfError(
      c.wasmtime_table_grow(
        store.context,
        _native(arena),
        delta,
        init,
        previous,
      ),
    );
    return previous.value;
  });

  @override
  String toString() => 'WasmTable(${type.element}, $length entries)';
}

// ---------------------------------------------------------------------------
// value conversion between the value layer and the object layer
// ---------------------------------------------------------------------------

/// Converts a value read from the C API into the object layer's form.
///
/// The value layer represents a `funcref` as a bare [FuncHandle]; here it
/// becomes a [WasmFunc] so that it can be called.
Object? toDartValue(WasmStore store, WasmValueKind kind, Object? value) {
  if (kind == WasmValueKind.funcRef && value is FuncHandle) {
    return WasmFunc.fromHandle(store, value);
  }
  return value;
}

/// Converts an object layer value into what the value layer expects.
Object? toNativeValue(WasmValueKind kind, Object? value) {
  if (kind == WasmValueKind.funcRef) {
    if (value is WasmFunc) return value.handle;
    if (value is FuncHandle) return value;
  }
  return value;
}

// ---------------------------------------------------------------------------
// extern <-> Dart
// ---------------------------------------------------------------------------

/// Turns a filled `wasmtime_extern_t` into the matching wrapper and consumes it.
Object? externToDart(WasmStore store, ffi.Pointer<c.wasmtime_extern_t> item) {
  final value = item.ref;
  final kind = WasmExternKind.fromC(value.kind);
  try {
    switch (kind) {
      case WasmExternKind.func:
        return WasmFunc.fromHandle(store, readFuncHandle(value.of.func));
      case WasmExternKind.memory:
      case WasmExternKind.sharedMemory:
        return WasmMemory._(store, readMemoryHandle(value.of.memory));
      case WasmExternKind.global:
        return WasmGlobal._(store, readGlobalHandle(value.of.global));
      case WasmExternKind.table:
        return WasmTable._(store, readTableHandle(value.of.table));
      case WasmExternKind.tag:
        throw UnsupportedError('Exception tags are not supported.');
    }
  } finally {
    c.wasmtime_extern_delete(item);
  }
}

/// Writes [value] into a fresh `wasmtime_extern_t` allocated in [arena].
ffi.Pointer<c.wasmtime_extern_t> dartToExtern(Arena arena, Object value) {
  final out = arena<c.wasmtime_extern_t>();
  switch (value) {
    case WasmFunc():
      out.ref.kind = WasmExternKind.func.cKind;
      writeFuncHandle(out.ref.of.func, value.handle);
    case WasmMemory():
      out.ref.kind = WasmExternKind.memory.cKind;
      writeMemoryHandle(out.ref.of.memory, value.handle);
    case WasmGlobal():
      out.ref.kind = WasmExternKind.global.cKind;
      writeGlobalHandle(out.ref.of.global, value.handle);
    case WasmTable():
      out.ref.kind = WasmExternKind.table.cKind;
      writeTableHandle(out.ref.of.table, value.handle);
    default:
      throw ArgumentError.value(
        value,
        'value',
        'expected a WasmFunc, WasmMemory, WasmGlobal or WasmTable',
      );
  }
  return out;
}

/// Builds the arity correct adapter behind [WasmFunc.function].
Function _functionFor(WasmFunc func) {
  Object? invoke(List<Object?> arguments) => func.invoke(arguments);
  return switch (func.type.parameters.length) {
    0 => () => invoke(const <Object?>[]),
    1 => (Object? a) => invoke(<Object?>[a]),
    2 => (Object? a, Object? b) => invoke(<Object?>[a, b]),
    3 => (Object? a, Object? b, Object? c) => invoke(<Object?>[a, b, c]),
    4 => (Object? a, Object? b, Object? c, Object? d) =>
      invoke(<Object?>[a, b, c, d]),
    5 => (Object? a, Object? b, Object? c, Object? d, Object? e) =>
      invoke(<Object?>[a, b, c, d, e]),
    6 => (Object? a, Object? b, Object? c, Object? d, Object? e, Object? f) =>
      invoke(<Object?>[a, b, c, d, e, f]),
    7 => (
      Object? a,
      Object? b,
      Object? c,
      Object? d,
      Object? e,
      Object? f,
      Object? g,
    ) => invoke(<Object?>[a, b, c, d, e, f, g]),
    8 => (
      Object? a,
      Object? b,
      Object? c,
      Object? d,
      Object? e,
      Object? f,
      Object? g,
      Object? h,
    ) => invoke(<Object?>[a, b, c, d, e, f, g, h]),
    final count => throw UnsupportedError(
      'WasmFunc.function supports up to 8 parameters, this function has '
      '$count; use WasmFunc.call instead',
    ),
  };
}
