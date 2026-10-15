// Layer 2 - stores.
//
// A store owns the WebAssembly objects that live in it; every `WasmFunc`,
// `WasmMemory`, `WasmGlobal` and `WasmTable` is bound to exactly one store.
// A store is not safe to use from two threads at the same time - the isolate
// layer gives each worker its own store instead.

import 'dart:ffi' as ffi;

import '../ffi/errors.dart';
import '../ffi/handles.dart';
import '../ffi/marshal.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'engine.dart';

/// The arena that WebAssembly objects are allocated in.
final class WasmStore extends NativeOwner<c.wasmtime_store_t> {
  WasmStore(this.engine) : super.owned(_newStore(engine), c.wasmtime_store_delete);

  final WasmEngine engine;

  /// Objects that have to stay alive as long as the store does, e.g. the
  /// `NativeCallable`s behind host functions.
  final List<void Function()> _releasers = <void Function()>[];

  /// Keeps [releaser]'s captured resources alive until this store is disposed.
  void retain(void Function() releaser) => _releasers.add(releaser);

  static ffi.Pointer<c.wasmtime_store_t> _newStore(WasmEngine engine) {
    final store = c.wasmtime_store_new(engine.pointer, ffi.nullptr, ffi.nullptr);
    if (store == ffi.nullptr) {
      throw WasmtimeException('wasmtime_store_new() returned null');
    }
    return store;
  }

  /// The `wasmtime_context_t` every C API call in this store takes.
  ffi.Pointer<c.wasmtime_context_t> get context {
    checkNotDisposed();
    return c.wasmtime_store_context(pointer);
  }

  /// The remaining fuel, or null when fuel consumption is not configured.
  int? get fuel {
    if (isDisposed) return null;
    return scoped((arena) {
      final out = arena<ffi.Uint64>();
      final error = c.wasmtime_context_get_fuel(context, out);
      if (error != ffi.nullptr) {
        c.wasmtime_error_delete(error);
        return null;
      }
      return out.value;
    });
  }

  /// Sets the fuel that WebAssembly may consume.
  ///
  /// Requires `WasmConfig.consumeFuel`.
  set fuel(int value) =>
      throwIfError(c.wasmtime_context_set_fuel(context, value));

  /// Runs a garbage collection over this store's reference values.
  void collectGarbage() => throwIfError(c.wasmtime_context_gc(context));

  @override
  void dispose() {
    for (final releaser in _releasers) {
      releaser();
    }
    _releasers.clear();
    super.dispose();
  }
}
