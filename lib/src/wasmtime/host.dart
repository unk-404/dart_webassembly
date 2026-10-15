// Layer 2 - host functions.
//
// A host function is a Dart callback that WebAssembly can import.  The C API
// wants a C function pointer, so every host function gets a `NativeCallable`
// trampoline that decodes the argument array, calls Dart, and encodes the
// results - or turns a Dart exception into a WebAssembly trap.

import 'dart:ffi' as ffi;

import '../ffi/errors.dart';
import '../ffi/values.dart';
import '../wasmtime_bindings_generated.dart' as c;
import 'handles.dart' show toNativeValue;
import 'types.dart';

/// A Dart function that WebAssembly imports.
///
/// [arguments] holds the decoded arguments; the return value supplies the
/// results the way JavaScript does it: nothing for a function without results,
/// the value itself for a single result, and a list for several results.
///
/// Throwing from the body aborts the WebAssembly call: the exception traps the
/// caller and is then rethrown from the Dart call that started it, which is
/// what JavaScript does with a host function that throws.
typedef WasmHostFunction = Object? Function(List<Object?> arguments);

/// The native trampoline behind one host function.
final class WasmHostTrampoline {
  WasmHostTrampoline(this.signature, this.body) {
    // `NativeCallable` takes the native signature; the Dart side of it uses
    // `int` where the native one uses `ffi.Size`, which is what `_invoke` has.
    // `_invoke` never throws (it turns failures into traps), so no exceptional
    // return value is needed - and a `Pointer` return type does not allow one.
    _callable =
        ffi.NativeCallable<c.wasmtime_func_callback_tFunction>.isolateLocal(
          _invoke,
        );
  }

  /// The signature WebAssembly declares for this import.
  final WasmFuncType signature;

  /// The Dart implementation.
  final WasmHostFunction body;

  ffi.NativeCallable<c.wasmtime_func_callback_tFunction>? _callable;
  bool _closed = false;

  /// The C function pointer to hand to wasmtime.
  c.wasmtime_func_callback_t get callback {
    final callable = _callable;
    if (callable == null || _closed) {
      throw StateError('This host function has been closed.');
    }
    return callable.nativeFunction;
  }

  /// Releases the trampoline.  Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _callable?.close();
    _callable = null;
  }

  /// The C API callback.  Must never throw across the FFI boundary, so every
  /// failure is turned into a trap.
  ffi.Pointer<c.wasm_trap_t> _invoke(
    ffi.Pointer<ffi.Void> env,
    ffi.Pointer<c.wasmtime_caller_t> caller,
    ffi.Pointer<c.wasmtime_val_t> args,
    int nargs,
    ffi.Pointer<c.wasmtime_val_t> results,
    int nresults,
  ) {
    try {
      final arguments = <Object?>[
        for (var i = 0; i < nargs; i++) readValue(args + i),
      ];
      final result = body(arguments);
      switch (nresults) {
        case 0:
          break;
        case 1:
          writeValue(
            results,
            signature.results.first,
            toNativeValue(signature.results.first, result),
          );
        default:
          if (result is! List) {
            throw ArgumentError(
              'a host function with $nresults results has to return a List, '
              'got ${result.runtimeType}',
            );
          }
          for (var i = 0; i < nresults; i++) {
            writeValue(
              results + i,
              signature.results[i],
              toNativeValue(signature.results[i], result[i]),
            );
          }
      }
      return ffi.nullptr;
    } catch (error, stackTrace) {
      rememberHostException(error, stackTrace);
      return newTrap('$error');
    }
  }
}
