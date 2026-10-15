// Layer 1 - turning native failures into Dart exceptions.
//
// The C API reports failures in two different ways:
//   * `wasmtime_error_t*` returned from most operations (compile, link, grow, ..)
//   * `wasm_trap_t*` produced when WebAssembly execution aborts
// Both are `own`-annotated, so whoever receives the pointer has to release it.

import 'dart:convert';
import 'dart:ffi' as ffi;

import '../wasmtime_bindings_generated.dart' as c;
import 'marshal.dart';

/// A failure reported by wasmtime itself: compiling, linking, growing a memory,
/// setting fuel that is not configured, and so on.
class WasmtimeException implements Exception {
  WasmtimeException(this.message);

  final String message;

  @override
  String toString() => 'WasmtimeException: $message';
}

/// A trap: WebAssembly execution was aborted (unreachable, out of bounds
/// memory access, stack overflow, an uncaught host exception, ...).
class WasmTrapException implements Exception {
  WasmTrapException(this.message, {this.code});

  final String message;

  /// The `WASMTIME_TRAP_CODE_*` value, when wasmtime could attribute one.
  final int? code;

  @override
  String toString() => 'WasmTrapException: $message';
}

// ---------------------------------------------------------------------------
// Host function failures
// ---------------------------------------------------------------------------
// A host function runs inside a native call, so its exception cannot be thrown
// from there: unwinding through the C stack is not allowed.  The trampoline
// remembers the exception, returns a trap, and the call site rethrows it once
// the native call has returned - which is what JavaScript does with a host
// function that throws.

Object? _hostException;
StackTrace? _hostStackTrace;

/// Remembers [error] as the reason the current native call is about to fail.
void rememberHostException(Object error, StackTrace stackTrace) {
  _hostException = error;
  _hostStackTrace = stackTrace;
}

/// Forgets the remembered host exception; call before a native call.
void clearHostException() {
  _hostException = null;
  _hostStackTrace = null;
}

/// Rethrows what a host function threw during the last native call, if
/// anything.  Returns normally when there was no host failure.
void rethrowHostException() {
  final error = _hostException;
  if (error == null) return;
  final stack = _hostStackTrace ?? StackTrace.current;
  clearHostException();
  Error.throwWithStackTrace(error, stack);
}

/// Throws a [WasmtimeException] if [error] is not null, and always consumes it.
void throwIfError(ffi.Pointer<c.wasmtime_error_t> error) {
  if (error == ffi.nullptr) return;
  final message = _errorMessageTaking(error);
  throw WasmtimeException(
    message.isEmpty ? 'unknown wasmtime error' : message,
  );
}

/// Turns the outcome of an execution API into an exception.
///
/// `wasmtime_func_call`, `wasmtime_linker_instantiate` and friends report
/// failure either through a `wasmtime_error_t` or through a trap pointer.  A
/// trap raised inside WebAssembly comes back through the pointer, while a host
/// function that returns a trap - including one produced by a Dart exception -
/// comes back as an *error* that wraps a wasm backtrace.  Both are traps for the
/// caller.
void throwExecutionFailure(
  ffi.Pointer<c.wasmtime_error_t> error,
  ffi.Pointer<c.wasm_trap_t> trap,
) {
  if (error != ffi.nullptr) {
    if (_hasWasmTrace(error)) {
      throw WasmTrapException(_errorMessageTaking(error));
    }
    throwIfError(error);
  }
  if (trap != ffi.nullptr) throwTrap(trap);
}

/// Reads and releases an error's message.
String _errorMessageTaking(ffi.Pointer<c.wasmtime_error_t> error) {
  final message = scoped((arena) {
    final out = arena<c.wasm_name_t>();
    c.wasmtime_error_message(error, out);
    return nameTakeToString(out);
  });
  c.wasmtime_error_delete(error);
  return message;
}

/// Whether [error] wraps a wasm stack trace, i.e. is really a trap.
bool _hasWasmTrace(ffi.Pointer<c.wasmtime_error_t> error) => scoped((arena) {
  final frames = arena<c.wasm_frame_vec_t>();
  c.wasmtime_error_wasm_trace(error, frames);
  final size = frames.ref.size;
  c.wasm_frame_vec_delete(frames);
  return size > 0;
});

/// Runs [body]; if it reports an error, throws instead of returning it.
T check<T>(T Function() body) => body();

/// Consumes [trap] and throws the matching [WasmTrapException].
Never throwTrap(ffi.Pointer<c.wasm_trap_t> trap) {
  final (message, code) = scoped((arena) {
    final messageOut = arena<c.wasm_message_t>();
    c.wasm_trap_message(trap, messageOut);
    final codeOut = arena<c.wasmtime_trap_code_t>();
    final hasCode = c.wasmtime_trap_code(trap, codeOut);
    return (nameTakeToString(messageOut), hasCode ? codeOut.value : null);
  });
  c.wasm_trap_delete(trap);
  throw WasmTrapException(
    message.isEmpty ? 'WebAssembly trap' : message,
    code: code,
  );
}

/// Creates a trap carrying [message], to be returned from a host function.
///
/// wasmtime takes ownership of the returned trap.
ffi.Pointer<c.wasm_trap_t> newTrap(String message) {
  final bytes = utf8.encode(message);
  if (bytes.isEmpty) return c.wasmtime_trap_new(ffi.nullptr, 0);
  return scoped((arena) {
    final buffer = arena<ffi.Uint8>(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    return c.wasmtime_trap_new(buffer.cast(), bytes.length);
  });
}

/// The human readable name of a `WASMTIME_TRAP_CODE_*` value.
String trapCodeName(int code) {
  for (final value in c.wasmtime_trap_code_enum.values) {
    if (value.value == code) return value.name;
  }
  return 'WASMTIME_TRAP_CODE_$code';
}
