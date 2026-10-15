// Layer 1 - marshalling between Dart values and the C API's containers.
//
// The C API uses `wasm_byte_vec_t` for owned byte buffers, `wasm_name_t` (the
// same struct) for borrowed ones, and `wasmtime_val_t` arrays for function
// arguments and results.  Everything below is mechanical conversion; no
// ownership decision is left to the caller except where a `Take` suffix says
// that the native buffer is consumed.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../wasmtime_bindings_generated.dart' as c;

/// Runs [body] with a temporary [Arena] that is released afterwards.
///
/// Use this for every short-lived argument buffer; it makes leaks in this
/// layer impossible to write by accident.
T scoped<T>(T Function(Arena arena) body) {
  final arena = Arena();
  try {
    return body(arena);
  } finally {
    arena.releaseAll();
  }
}

/// Reads a `wasm_name_t`/`wasm_byte_vec_t` **borrowed** from the C API.
///
/// The buffer is not freed; whoever handed it out still owns it.
Uint8List nameBytes(ffi.Pointer<c.wasm_name_t> name) {
  final ref = name.ref;
  if (ref.size == 0 || ref.data == ffi.nullptr) return Uint8List(0);
  return Uint8List.fromList(ref.data.cast<ffi.Uint8>().asTypedList(ref.size));
}

/// Reads a `wasm_name_t` used as a string (it holds UTF-8).
String nameToString(ffi.Pointer<c.wasm_name_t> name) {
  final bytes = nameBytes(name);
  return bytes.isEmpty ? '' : utf8.decode(bytes, allowMalformed: true);
}

/// Reads a `wasm_byte_vec_t`/`wasm_name_t` that the C API handed over as
/// `own` (its docs use that annotation), then frees it.
Uint8List byteVecTake(ffi.Pointer<c.wasm_byte_vec_t> vec) {
  final bytes = nameBytes(vec);
  c.wasm_byte_vec_delete(vec);
  return bytes;
}

/// [byteVecTake] for a buffer that holds a UTF-8 string.
String nameTakeToString(ffi.Pointer<c.wasm_name_t> name) {
  final bytes = nameBytes(name);
  c.wasm_byte_vec_delete(name);
  return bytes.isEmpty ? '' : utf8.decode(bytes, allowMalformed: true);
}

/// Fills [out] with a copy of [bytes]; the caller owns the vector and must
/// release it with `wasm_byte_vec_delete`.
void byteVecSet(ffi.Pointer<c.wasm_byte_vec_t> out, Uint8List bytes) {
  if (bytes.isEmpty) {
    c.wasm_byte_vec_new_empty(out);
    return;
  }
  final data = calloc<c.wasm_byte_t>(bytes.length);
  data.cast<ffi.Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  c.wasm_byte_vec_new(out, bytes.length, data);
  // `wasm_byte_vec_new` copies, so the staging buffer can go away.
  calloc.free(data);
}

/// Copies [value] as UTF-8 into [arena], returning the pointer and its length.
///
/// The C API functions that take module/export names take a pointer and a
/// length, so no terminator is needed.
(ffi.Pointer<ffi.Char>, int) copyChars(Arena arena, String value) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty) return (ffi.nullptr, 0);
  final buffer = arena<ffi.Char>(bytes.length);
  buffer.cast<ffi.Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  return (buffer, bytes.length);
}

/// Copies [bytes] into [arena].
///
/// Returns the pointer and the length to pass to the C API; an empty list
/// yields a null pointer and a length of zero.
(ffi.Pointer<ffi.Uint8>, int) copyBytes(Arena arena, Uint8List bytes) {
  if (bytes.isEmpty) return (ffi.nullptr, 0);
  final data = arena<ffi.Uint8>(bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  return (data, bytes.length);
}

/// A `wasm_limits_t` value, as used for memories and tables.
final class Limits {
  const Limits(this.min, [this.max]);

  final int min;
  final int? max;

  @override
  String toString() => 'Limits(min: $min, max: $max)';
}
