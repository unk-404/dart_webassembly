// Layer 2 - instantiated modules.

import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show Arena;

import '../ffi/marshal.dart';
import '../ffi/values.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'handles.dart';
import 'store.dart';

/// An instance of a [WasmModule] inside a [WasmStore].
final class WasmInstance {
  /// Wraps an existing `wasmtime_instance_t` value.
  ///
  /// This is the low level entry point used by [WasmLinker.instantiate]; the
  /// handle has to come from the C API and live in [store].
  WasmInstance.fromHandle(this.store, this.handle);

  /// The store the instance lives in.
  final WasmStore store;

  /// The raw handle; safe to copy.
  final InstanceHandle handle;

  ffi.Pointer<c.wasmtime_instance_t> _native(Arena arena) {
    final out = arena<c.wasmtime_instance_t>();
    writeInstanceHandle(out.ref, handle);
    return out;
  }

  /// The export called [name], or null when there is none.
  Object? export(String name) => scoped((arena) {
    final (chars, length) = copyChars(arena, name);
    final item = arena<c.wasmtime_extern_t>();
    final found = c.wasmtime_instance_export_get(
      store.context,
      _native(arena),
      chars,
      length,
      item,
    );
    if (!found) return null;
    return externToDart(store, item);
  });

  /// The names of all exports, in the order the module declares them.
  List<String> get exportNames => scoped((arena) {
    final names = <String>[];
    for (var index = 0; ; index++) {
      final nameOut = arena<ffi.Pointer<ffi.Char>>();
      final lengthOut = arena<ffi.Size>();
      final item = arena<c.wasmtime_extern_t>();
      final found = c.wasmtime_instance_export_nth(
        store.context,
        _native(arena),
        index,
        nameOut,
        lengthOut,
        item,
      );
      if (!found) break;
      names.add(_decode(nameOut.value, lengthOut.value));
      c.wasmtime_extern_delete(item);
    }
    return names;
  });

  /// Every export, keyed by name.
  ///
  /// Functions are [WasmFunc]s (with a [WasmFunc.function] adapter), memories
  /// are [WasmMemory]s, and so on - the same shape as `instance.exports` in
  /// JavaScript.
  Map<String, Object?> get exports => scoped((arena) {
    final result = <String, Object?>{};
    for (var index = 0; ; index++) {
      final nameOut = arena<ffi.Pointer<ffi.Char>>();
      final lengthOut = arena<ffi.Size>();
      final item = arena<c.wasmtime_extern_t>();
      final found = c.wasmtime_instance_export_nth(
        store.context,
        _native(arena),
        index,
        nameOut,
        lengthOut,
        item,
      );
      if (!found) break;
      result[_decode(nameOut.value, lengthOut.value)] = externToDart(
        store,
        item,
      );
    }
    return result;
  });

  @override
  String toString() => 'WasmInstance(${exportNames.join(', ')})';
}

String _decode(ffi.Pointer<ffi.Char> chars, int length) => length == 0
    ? ''
    : utf8.decode(chars.cast<ffi.Uint8>().asTypedList(length));
