// Layer 2 - the linker.
//
// A linker collects the items a module imports (functions, memories, globals,
// tables) and instantiates modules against them.  This is the wasmtime answer
// to JavaScript's `importObject`.

import 'dart:ffi' as ffi;

import '../ffi/errors.dart';
import '../ffi/handles.dart';
import '../ffi/marshal.dart';
import '../ffi/values.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'engine.dart';
import 'handles.dart';
import 'host.dart';
import 'instance.dart';
import 'module.dart';
import 'store.dart';
import 'types.dart';

/// Defines a module's imports and instantiates it.
final class WasmLinker extends NativeOwner<c.wasmtime_linker_t> {
  WasmLinker(this.engine) : super.owned(_new(engine), c.wasmtime_linker_delete);

  final WasmEngine engine;
  final List<WasmHostTrampoline> _trampolines = <WasmHostTrampoline>[];
  bool _instantiated = false;

  static ffi.Pointer<c.wasmtime_linker_t> _new(WasmEngine engine) {
    final linker = c.wasmtime_linker_new(engine.pointer);
    if (linker == ffi.nullptr) {
      throw WasmtimeException('wasmtime_linker_new() returned null');
    }
    return linker;
  }

  /// Defines `module.name` as a host function.
  void defineFunction(
    String module,
    String name,
    WasmFuncType signature,
    WasmHostFunction function,
  ) {
    final trampoline = WasmHostTrampoline(signature, function);
    _trampolines.add(trampoline);
    scoped((arena) {
      final (modulePtr, moduleLength) = copyChars(arena, module);
      final (namePtr, nameLength) = copyChars(arena, name);
      signature.withNative((type) {
        throwIfError(
          c.wasmtime_linker_define_func(
            pointer,
            modulePtr,
            moduleLength,
            namePtr,
            nameLength,
            type,
            trampoline.callback,
            ffi.nullptr,
            ffi.nullptr,
          ),
        );
      });
    });
  }

  /// Defines `name` as the exports of [instance].
  void defineInstance(String name, WasmInstance instance) => scoped((arena) {
    final (namePtr, nameLength) = copyChars(arena, name);
    final native = arena<c.wasmtime_instance_t>();
    writeInstanceHandle(native.ref, instance.handle);
    throwIfError(
      c.wasmtime_linker_define_instance(
        pointer,
        instance.store.context,
        namePtr,
        nameLength,
        native,
      ),
    );
  });

  /// Defines `name` as the exports of [module].
  void defineModule(String name, WasmStore store, WasmModule module) =>
      scoped((arena) {
        final (namePtr, nameLength) = copyChars(arena, name);
        throwIfError(
          c.wasmtime_linker_module(
            pointer,
            store.context,
            namePtr,
            nameLength,
            module.pointer,
          ),
        );
      });

  /// Defines `module.name` as an existing memory.
  ///
  /// The memory has to belong to the store that is used for instantiation.
  void defineMemory(
    String module,
    String name,
    WasmStore store,
    WasmMemory memory,
  ) => _defineExtern(module, name, store, memory);

  /// Defines `module.name` as an existing global.
  void defineGlobal(
    String module,
    String name,
    WasmStore store,
    WasmGlobal global,
  ) => _defineExtern(module, name, store, global);

  /// Defines `module.name` as an existing table.
  void defineTable(
    String module,
    String name,
    WasmStore store,
    WasmTable table,
  ) => _defineExtern(module, name, store, table);

  void _defineExtern(
    String module,
    String name,
    WasmStore store,
    Object value,
  ) => scoped((arena) {
    final (modulePtr, moduleLength) = copyChars(arena, module);
    final (namePtr, nameLength) = copyChars(arena, name);
    // The linker copies the item, and none of these extern kinds holds a GC
    // root, so the temporary extern needs no separate release.
    throwIfError(
      c.wasmtime_linker_define(
        pointer,
        store.context,
        modulePtr,
        moduleLength,
        namePtr,
        nameLength,
        dartToExtern(arena, value),
      ),
    );
  });

  /// Satisfies every import that is not defined yet with a function that traps.
  void defineUnknownImportsAsTraps(WasmModule module) => throwIfError(
    c.wasmtime_linker_define_unknown_imports_as_traps(pointer, module.pointer),
  );

  /// Satisfies every import that is not defined yet with a zero value.
  void defineUnknownImportsAsDefaultValues(WasmStore store, WasmModule module) =>
      throwIfError(
        c.wasmtime_linker_define_unknown_imports_as_default_values(
          pointer,
          store.context,
          module.pointer,
        ),
      );

  /// Instantiates [module] in [store].
  ///
  /// Throws a [WasmtimeException] for a link error (a missing or mistyped
  /// import) and a [WasmTrapException] when a start function traps.
  WasmInstance instantiate(WasmStore store, WasmModule module) {
    // The host functions are called for as long as the store lives, so their
    // trampolines move into the store.
    _instantiated = true;
    for (final trampoline in _trampolines) {
      store.retain(trampoline.close);
    }
    return scoped((arena) {
      final out = arena<c.wasmtime_instance_t>();
      final trapOut = arena<ffi.Pointer<c.wasm_trap_t>>();
      clearHostException();
      final error = c.wasmtime_linker_instantiate(
        pointer,
        store.context,
        module.pointer,
        out,
        trapOut,
      );
      if (error != ffi.nullptr || trapOut.value != ffi.nullptr) {
        // A start function that threw is more informative than the trap.
        rethrowHostException();
        throwExecutionFailure(error, trapOut.value);
      }
      return WasmInstance.fromHandle(store, readInstanceHandle(out.ref));
    });
  }

  @override
  void dispose() {
    if (!_instantiated) {
      // Never instantiated, so no store took ownership of the trampolines.
      for (final trampoline in _trampolines) {
        trampoline.close();
      }
    }
    _trampolines.clear();
    super.dispose();
  }
}
