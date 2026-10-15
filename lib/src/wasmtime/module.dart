// Layer 2 - compiled modules.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import '../ffi/errors.dart';
import '../ffi/handles.dart';
import '../ffi/marshal.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'engine.dart';
import 'types.dart';

/// A compiled WebAssembly module.
///
/// Modules belong to the engine that compiled them and can be instantiated in
/// any number of [WasmStore]s of that engine.
final class WasmModule extends NativeOwner<c.wasmtime_module_t> {
  WasmModule._(this.engine, ffi.Pointer<c.wasmtime_module_t> pointer)
    : super.owned(pointer, c.wasmtime_module_delete);

  /// The engine the module was compiled with.
  final WasmEngine engine;

  /// Compiles [bytes] (a binary `.wasm` module).
  ///
  /// Throws a [WasmtimeException] if the module is malformed or uses a feature
  /// that was not configured.
  factory WasmModule.compile(WasmEngine engine, Uint8List bytes) =>
      scoped((arena) {
        final (data, length) = copyBytes(arena, bytes);
        final out = arena<ffi.Pointer<c.wasmtime_module_t>>();
        throwIfError(c.wasmtime_module_new(engine.pointer, data, length, out));
        if (out.value == ffi.nullptr) {
          throw WasmtimeException('wasmtime_module_new() produced no module');
        }
        return WasmModule._(engine, out.value);
      });

  /// Loads a module from bytes produced by [serialize].
  factory WasmModule.deserialize(WasmEngine engine, Uint8List bytes) =>
      scoped((arena) {
        final (data, length) = copyBytes(arena, bytes);
        final out = arena<ffi.Pointer<c.wasmtime_module_t>>();
        throwIfError(
          c.wasmtime_module_deserialize(engine.pointer, data, length, out),
        );
        if (out.value == ffi.nullptr) {
          throw WasmtimeException(
            'wasmtime_module_deserialize() produced no module',
          );
        }
        return WasmModule._(engine, out.value);
      });

  /// Everything the module needs to be instantiated.
  List<WasmImport> get imports => scoped((arena) {
    final vec = arena<c.wasm_importtype_vec_t>();
    c.wasmtime_module_imports(pointer, vec);
    try {
      final ref = vec.ref;
      return <WasmImport>[
        for (var i = 0; i < ref.size; i++)
          WasmImport(
            module: nameToString(c.wasm_importtype_module(ref.data[i])),
            name: nameToString(c.wasm_importtype_name(ref.data[i])),
            type: WasmExternType.fromNative(
              c.wasm_importtype_type(ref.data[i]),
            ),
          ),
      ];
    } finally {
      c.wasm_importtype_vec_delete(vec);
    }
  });

  /// Everything the module provides once instantiated.
  List<WasmExport> get exports => scoped((arena) {
    final vec = arena<c.wasm_exporttype_vec_t>();
    c.wasmtime_module_exports(pointer, vec);
    try {
      final ref = vec.ref;
      return <WasmExport>[
        for (var i = 0; i < ref.size; i++)
          WasmExport(
            name: nameToString(c.wasm_exporttype_name(ref.data[i])),
            type: WasmExternType.fromNative(
              c.wasm_exporttype_type(ref.data[i]),
            ),
          ),
      ];
    } finally {
      c.wasm_exporttype_vec_delete(vec);
    }
  });

  /// Serialises the compiled artifact so it can be loaded again without
  /// recompiling (~`WebAssembly.Module` caching).
  ///
  /// The blob is only valid for the exact wasmtime build and the same engine
  /// configuration.
  Uint8List serialize() => scoped((arena) {
    final out = arena<c.wasm_byte_vec_t>();
    throwIfError(c.wasmtime_module_serialize(pointer, out));
    return byteVecTake(out);
  });

  @override
  String toString() => 'WasmModule(${exports.length} exports)';
}

/// Compilation helpers on the engine, kept here to avoid a circular import.
extension WasmEngineCompilation on WasmEngine {
  /// Compiles [bytes] into a module (see [WasmModule.compile]).
  WasmModule compile(Uint8List bytes) => WasmModule.compile(this, bytes);

  /// Loads a module from a [WasmModule.serialize] blob.
  WasmModule deserialize(Uint8List bytes) =>
      WasmModule.deserialize(this, bytes);
}
