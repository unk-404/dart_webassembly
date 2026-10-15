// Layer 2 - engines and their configuration.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import '../ffi/errors.dart';
import '../ffi/handles.dart';
import '../ffi/marshal.dart';
import '../wasmtime_bindings_generated.dart' as c;

/// The code generator wasmtime compiles with.
///
/// This build of the wasmtime C API contains cranelift only.
enum WasmStrategy {
  auto,
  cranelift;

  int get cValue => switch (this) {
    WasmStrategy.auto => c.wasmtime_strategy_enum.WASMTIME_STRATEGY_AUTO.value,
    WasmStrategy.cranelift =>
      c.wasmtime_strategy_enum.WASMTIME_STRATEGY_CRANELIFT.value,
  };
}

/// How hard cranelift tries to optimise.
enum WasmOptLevel {
  none,
  speed,
  speedAndSize;

  int get cValue => switch (this) {
    WasmOptLevel.none =>
      c.wasmtime_opt_level_enum.WASMTIME_OPT_LEVEL_NONE.value,
    WasmOptLevel.speed =>
      c.wasmtime_opt_level_enum.WASMTIME_OPT_LEVEL_SPEED.value,
    WasmOptLevel.speedAndSize =>
      c.wasmtime_opt_level_enum.WASMTIME_OPT_LEVEL_SPEED_AND_SIZE.value,
  };
}

/// Configuration for a [WasmEngine].
///
/// A config is consumed by the engine that is built from it; using it
/// afterwards throws a [StateError].
final class WasmConfig extends NativeOwner<c.wasm_config_t> {
  WasmConfig() : super.owned(c.wasm_config_new(), c.wasm_config_delete);

  /// Which compiler to use.
  set strategy(WasmStrategy value) =>
      c.wasmtime_config_strategy_set(pointer, value.cValue);

  /// How hard to optimise.
  set optLevel(WasmOptLevel value) =>
      c.wasmtime_config_cranelift_opt_level_set(pointer, value.cValue);

  /// Whether to emit DWARF debug information and name the compiled symbols.
  set debugInfo(bool value) =>
      c.wasmtime_config_debug_info_set(pointer, value);

  /// Whether WebAssembly can consume fuel (`Store.fuel`).
  set consumeFuel(bool value) =>
      c.wasmtime_config_consume_fuel_set(pointer, value);

  /// Whether epoch interruption is available.
  set epochInterruption(bool value) =>
      c.wasmtime_config_epoch_interruption_set(pointer, value);

  /// Whether cranelift may use several threads to compile one module.
  set parallelCompilation(bool value) =>
      c.wasmtime_config_parallel_compilation_set(pointer, value);

  /// Whether traps are implemented with OS signals (much faster).
  set signalsBasedTraps(bool value) =>
      c.wasmtime_config_signals_based_traps_set(pointer, value);

  /// The largest stack a wasm function may use, in bytes.
  set maxWasmStack(int bytes) =>
      c.wasmtime_config_max_wasm_stack_set(pointer, bytes);

  /// The size of the stack of an async wasm function, in bytes.
  set asyncStackSize(int bytes) =>
      c.wasmtime_config_async_stack_size_set(pointer, bytes);

  /// Whether linear memories may be moved in memory when they grow.
  set memoryMayMove(bool value) =>
      c.wasmtime_config_memory_may_move_set(pointer, value);

  /// The `threads` proposal (`shared` memories and atomics).
  set threads(bool value) =>
      c.wasmtime_config_wasm_threads_set(pointer, value);

  /// Shared linear memories.
  set sharedMemory(bool value) =>
      c.wasmtime_config_shared_memory_set(pointer, value);

  /// The `simd` proposal.
  set simd(bool value) => c.wasmtime_config_wasm_simd_set(pointer, value);

  /// The `relaxed-simd` proposal.
  set relaxedSimd(bool value) =>
      c.wasmtime_config_wasm_relaxed_simd_set(pointer, value);

  /// The `gc` proposal.
  set gc(bool value) => c.wasmtime_config_wasm_gc_set(pointer, value);

  /// The `reference-types` proposal.
  set referenceTypes(bool value) =>
      c.wasmtime_config_wasm_reference_types_set(pointer, value);

  /// The `function-references` proposal.
  set functionReferences(bool value) =>
      c.wasmtime_config_wasm_function_references_set(pointer, value);

  /// The `bulk-memory` proposal.
  set bulkMemory(bool value) =>
      c.wasmtime_config_wasm_bulk_memory_set(pointer, value);

  /// The `multi-value` proposal.
  set multiValue(bool value) =>
      c.wasmtime_config_wasm_multi_value_set(pointer, value);

  /// The `multi-memory` proposal.
  set multiMemory(bool value) =>
      c.wasmtime_config_wasm_multi_memory_set(pointer, value);

  /// The `memory64` proposal.
  set memory64(bool value) =>
      c.wasmtime_config_wasm_memory64_set(pointer, value);

  /// The `tail-call` proposal.
  set tailCall(bool value) =>
      c.wasmtime_config_wasm_tail_call_set(pointer, value);

  /// The `exceptions` proposal.
  set exceptions(bool value) =>
      c.wasmtime_config_wasm_exceptions_set(pointer, value);

  /// The `stack-switching` proposal.
  set stackSwitching(bool value) =>
      c.wasmtime_config_wasm_stack_switching_set(pointer, value);

  /// The component model.
  set componentModel(bool value) =>
      c.wasmtime_config_wasm_component_model_set(pointer, value);
}

/// A wasmtime engine: it owns the compiler and the global runtime state.
///
/// One engine can back any number of [WasmStore]s, and compiled modules can be
/// instantiated in all of them.
final class WasmEngine extends NativeOwner<c.wasm_engine_t> {
  /// An engine with wasmtime's default configuration.
  WasmEngine() : super.owned(c.wasm_engine_new(), c.wasm_engine_delete);

  /// An engine built from a [WasmConfig] that [configure] fills in.
  factory WasmEngine.configured(void Function(WasmConfig config) configure) {
    final config = WasmConfig();
    try {
      configure(config);
      return WasmEngine._withConfig(config);
    } catch (_) {
      config.dispose();
      rethrow;
    }
  }

  WasmEngine._withConfig(WasmConfig config)
    : super.owned(_engineFromConfig(config), c.wasm_engine_delete);

  static ffi.Pointer<c.wasm_engine_t> _engineFromConfig(WasmConfig config) {
    // Throws if the config was already consumed.
    final raw = config.pointer;
    final engine = c.wasm_engine_new_with_config(raw);
    // `wasm_engine_new_with_config` takes ownership of the configuration.
    config.disown();
    if (engine == ffi.nullptr) {
      throw WasmtimeException(
        'wasm_engine_new_with_config() returned null; the configured strategy '
        'is probably not compiled into this build of wasmtime',
      );
    }
    return engine;
  }

  /// Whether [bytes] is a well formed module for this engine.
  bool validate(Uint8List bytes) {
    try {
      scoped((arena) {
        final (data, length) = copyBytes(arena, bytes);
        throwIfError(c.wasmtime_module_validate(pointer, data, length));
      });
      return true;
    } on WasmtimeException {
      return false;
    }
  }
}
