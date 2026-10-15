// Layer 1 - the value model.
//
// `wasmtime_val_t` is a tagged union.  This file is the only place that knows
// its layout; above it, WebAssembly values are plain Dart objects:
//
//   i32, i64  ->  int
//   f32, f64  ->  double
//   v128      ->  Uint8List (16 bytes, little endian)
//   funcref   ->  FuncHandle, or null for a null reference
//   externref ->  null (see the limitation below)
//
// Limitation: non-null `externref`/`anyref` values are rejected.  Passing a
// Dart object into WebAssembly as an `externref` requires wasmtime to root it
// and to be told when WebAssembly drops it (`wasmtime_externref_new` plus a
// native finalizer), which this layer does not implement; null references,
// which is what an unused `externref` parameter normally is, work.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import '../wasmtime_bindings_generated.dart' as c;

/// The kinds of value that can cross the WebAssembly boundary.
enum WasmValueKind {
  i32(c.WASMTIME_I32, 'i32'),
  i64(c.WASMTIME_I64, 'i64'),
  f32(c.WASMTIME_F32, 'f32'),
  f64(c.WASMTIME_F64, 'f64'),
  v128(c.WASMTIME_V128, 'v128'),
  funcRef(c.WASMTIME_FUNCREF, 'funcref'),
  externRef(c.WASMTIME_EXTERNREF, 'externref'),
  anyRef(c.WASMTIME_ANYREF, 'anyref');

  const WasmValueKind(this.cKind, this.wasmName);

  /// The `WASMTIME_*` discriminant used by `wasmtime_val_t.kind`.
  final int cKind;

  /// The WebAssembly name of this type, e.g. `i32`.
  final String wasmName;

  bool get isReference =>
      this == funcRef || this == externRef || this == anyRef;

  /// The `WASM_*` discriminant used by the wasm-c-api's `wasm_valtype_t`.
  ///
  /// `v128` and `anyref` have no encoding there; WebAssembly's base value types
  /// stop at `f64`, `funcref` and `externref`.
  int get wasmKind => switch (this) {
    i32 => c.wasm_valkind_enum.WASM_I32.value,
    i64 => c.wasm_valkind_enum.WASM_I64.value,
    f32 => c.wasm_valkind_enum.WASM_F32.value,
    f64 => c.wasm_valkind_enum.WASM_F64.value,
    funcRef => c.wasm_valkind_enum.WASM_FUNCREF.value,
    externRef => c.wasm_valkind_enum.WASM_EXTERNREF.value,
    v128 || anyRef => throw UnsupportedError(
      '$this cannot be expressed as a wasm-c-api value type',
    ),
  };

  static WasmValueKind fromCKind(int kind) => switch (kind) {
    c.WASMTIME_I32 => i32,
    c.WASMTIME_I64 => i64,
    c.WASMTIME_F32 => f32,
    c.WASMTIME_F64 => f64,
    c.WASMTIME_V128 => v128,
    c.WASMTIME_FUNCREF => funcRef,
    c.WASMTIME_EXTERNREF => externRef,
    c.WASMTIME_ANYREF => anyRef,
    _ => throw UnsupportedError('Unknown value kind $kind'),
  };

  /// Decodes a `WASM_*` / `wasm_valkind_t` discriminant.
  ///
  /// The numbers are the values of `wasm_valkind_t` in `wasm.h`; they cannot be
  /// written as switch patterns from the generated enum because Dart requires
  /// patterns to be compile time constants and enum fields are not.
  static WasmValueKind fromWasmKind(int kind) => switch (kind) {
    0 => i32, // WASM_I32
    1 => i64, // WASM_I64
    2 => f32, // WASM_F32
    3 => f64, // WASM_F64
    4 => v128, // wasmtime's extension
    128 => externRef, // WASM_EXTERNREF
    129 => funcRef, // WASM_FUNCREF
    _ => throw UnsupportedError('Unknown wasm value kind $kind'),
  };

  @override
  String toString() => wasmName;
}

/// A `wasmtime_func_t`, copied out of a value or an extern.
///
/// Function references are plain index-like values bound to a store; they are
/// not owned and nothing has to be released.  The fields are plain integers so
/// that the value can be sent to another isolate.
final class FuncHandle {
  const FuncHandle(this.storeId, this.privateAddress);

  /// A reference that does not point at any function (`funcref` `null`).
  static const FuncHandle nullRef = FuncHandle(0, 0);

  final int storeId;
  final int privateAddress;

  bool get isNull => storeId == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FuncHandle &&
          other.storeId == storeId &&
          other.privateAddress == privateAddress;

  @override
  int get hashCode => Object.hash(storeId, privateAddress);

  @override
  String toString() => isNull ? 'FuncHandle.null' : 'FuncHandle($storeId)';
}

/// Clears a value slot, so that a partially written union can never be read
/// back with stale payload.
void clearValue(ffi.Pointer<c.wasmtime_val_t> slot) {
  final bytes = slot
      .cast<ffi.Uint8>()
      .asTypedList(ffi.sizeOf<c.wasmtime_val_t>());
  bytes.fillRange(0, bytes.length, 0);
}

/// Writes [value] into [slot], tagged with [kind].
void writeValue(
  ffi.Pointer<c.wasmtime_val_t> slot,
  WasmValueKind kind,
  Object? value,
) {
  clearValue(slot);
  slot.ref.kind = kind.cKind;
  switch (kind) {
    case WasmValueKind.i32:
      slot.ref.of.i32 = requireI32(value);
    case WasmValueKind.i64:
      slot.ref.of.i64 = requireI64(value);
    case WasmValueKind.f32:
      slot.ref.of.f32 = requireF32(value);
    case WasmValueKind.f64:
      slot.ref.of.f64 = requireF64(value);
    case WasmValueKind.v128:
      writeV128(slot, requireV128(value));
    case WasmValueKind.funcRef:
      writeFuncRef(slot, value);
    case WasmValueKind.externRef:
    case WasmValueKind.anyRef:
      if (value != null) {
        throw UnsupportedError(
          'Passing a non-null $kind into WebAssembly is not supported.',
        );
      }
      // A null reference is the all-zero payload written by clearValue.
  }
}

/// Reads the value in [slot].  Reference kinds return a [FuncHandle] or null.
Object? readValue(ffi.Pointer<c.wasmtime_val_t> slot) {
  switch (WasmValueKind.fromCKind(slot.ref.kind)) {
    case WasmValueKind.i32:
      return slot.ref.of.i32;
    case WasmValueKind.i64:
      return slot.ref.of.i64;
    case WasmValueKind.f32:
      return slot.ref.of.f32;
    case WasmValueKind.f64:
      return slot.ref.of.f64;
    case WasmValueKind.v128:
      return _readV128(slot);
    case WasmValueKind.funcRef:
      final func = slot.ref.of.funcref;
      return FuncHandle(func.store_id, func.privateData.address);
    case WasmValueKind.externRef:
      return _readNullReference(slot.ref.kind, slot.ref.of.externref.store_id);
    case WasmValueKind.anyRef:
      return _readNullReference(slot.ref.kind, slot.ref.of.anyref.store_id);
  }
}

/// Releases any GC root held by a reference value produced by the C API.
///
/// wasmtime hands out rooted references; not unrooting them keeps the
/// referenced object alive forever.
void unrootValue(ffi.Pointer<c.wasmtime_val_t> slot) {
  switch (WasmValueKind.fromCKind(slot.ref.kind)) {
    case WasmValueKind.externRef:
    case WasmValueKind.anyRef:
      c.wasmtime_val_unroot(slot);
    // funcrefs are kept alive by the store's function table, not by a root.
    case WasmValueKind.i32:
    case WasmValueKind.i64:
    case WasmValueKind.f32:
    case WasmValueKind.f64:
    case WasmValueKind.v128:
    case WasmValueKind.funcRef:
      break;
  }
}

// ---------------------------------------------------------------------------
// Scalar coercion
// ---------------------------------------------------------------------------

/// The inclusive range of a WebAssembly `i32` interpreted as signed.
const int minI32 = -0x80000000;
const int maxI32 = 0x7FFFFFFF;
const int maxU32 = 0xFFFFFFFF;
const int maxI64 = 0x7FFFFFFFFFFFFFFF;
const int maxU64 = -1; // all bits set when reinterpreted

int requireI32(Object? value) {
  final int v = _requireInt(value, WasmValueKind.i32);
  if (v < minI32 || v > maxU32) {
    throw RangeError.range(v, minI32, maxU32, 'value', 'i32 out of range');
  }
  return v & 0xFFFFFFFF >= 0x80000000 ? v - 0x100000000 : v;
}

int requireI64(Object? value) => _requireInt(value, WasmValueKind.i64);

double requireF32(Object? value) {
  if (value is! num) {
    throw ArgumentError.value(value, 'value', 'expected a num for f32');
  }
  return value.toDouble();
}

double requireF64(Object? value) => requireF32(value);

Uint8List requireV128(Object? value) {
  if (value is! Uint8List || value.length != 16) {
    throw ArgumentError.value(
      value,
      'value',
      'expected a Uint8List of 16 bytes for v128',
    );
  }
  return value;
}

int _requireInt(Object? value, WasmValueKind kind) {
  if (value is! int) {
    throw ArgumentError.value(value, 'value', 'expected an int for $kind');
  }
  return value;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Uint8List _readV128(ffi.Pointer<c.wasmtime_val_t> slot) {
  final out = Uint8List(16);
  final lanes = slot.ref.of.v128;
  for (var i = 0; i < 16; i++) {
    out[i] = lanes[i];
  }
  return out;
}

void writeV128(ffi.Pointer<c.wasmtime_val_t> slot, Uint8List value) {
  final lanes = slot.ref.of.v128;
  for (var i = 0; i < 16; i++) {
    lanes[i] = value[i];
  }
}

void writeFuncRef(ffi.Pointer<c.wasmtime_val_t> slot, Object? value) {
  final FuncHandle handle = switch (value) {
    null => FuncHandle.nullRef,
    FuncHandle() => value,
    _ => throw ArgumentError.value(value, 'value', 'expected a FuncHandle'),
  };
  final func = slot.ref.of.funcref;
  func.store_id = handle.storeId;
  func.privateData = ffi.Pointer.fromAddress(handle.privateAddress);
}

Object? _readNullReference(int kind, int storeId) {
  if (storeId == 0) return null;
  throw UnsupportedError(
    'Non-null reference values (kind $kind) are not supported.',
  );
}

// ---------------------------------------------------------------------------
// Store scoped handles
// ---------------------------------------------------------------------------
// `wasmtime_memory_t`, `wasmtime_table_t` and `wasmtime_global_t` - like
// [FuncHandle] - are value structs that point into a store; nothing has to be
// released.  They are copied into records of plain integers so that they do not
// depend on the native allocation they came from and can be sent to another
// isolate.

/// A `wasmtime_memory_t`.
final class MemoryHandle {
  const MemoryHandle(this.storeId, this.privateData1, this.privateData2);

  static const MemoryHandle none = MemoryHandle(0, 0, 0);

  final int storeId;
  final int privateData1;
  final int privateData2;

  bool get isNull => storeId == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryHandle &&
          other.storeId == storeId &&
          other.privateData1 == privateData1 &&
          other.privateData2 == privateData2;

  @override
  int get hashCode => Object.hash(storeId, privateData1, privateData2);

  @override
  String toString() => isNull ? 'MemoryHandle.none' : 'MemoryHandle($storeId)';
}

/// A `wasmtime_table_t`.
final class TableHandle {
  const TableHandle(this.storeId, this.privateData1, this.privateData2);

  static const TableHandle none = TableHandle(0, 0, 0);

  final int storeId;
  final int privateData1;
  final int privateData2;

  bool get isNull => storeId == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TableHandle &&
          other.storeId == storeId &&
          other.privateData1 == privateData1 &&
          other.privateData2 == privateData2;

  @override
  int get hashCode => Object.hash(storeId, privateData1, privateData2);

  @override
  String toString() => isNull ? 'TableHandle.none' : 'TableHandle($storeId)';
}

/// A `wasmtime_global_t`.
final class GlobalHandle {
  const GlobalHandle(
    this.storeId,
    this.privateData1,
    this.privateData2,
    this.privateData3,
  );

  static const GlobalHandle none = GlobalHandle(0, 0, 0, 0);

  final int storeId;
  final int privateData1;
  final int privateData2;
  final int privateData3;

  bool get isNull => storeId == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlobalHandle &&
          other.storeId == storeId &&
          other.privateData1 == privateData1 &&
          other.privateData2 == privateData2 &&
          other.privateData3 == privateData3;

  @override
  int get hashCode =>
      Object.hash(storeId, privateData1, privateData2, privateData3);

  @override
  String toString() =>
      isNull ? 'GlobalHandle.none' : 'GlobalHandle($storeId)';
}

FuncHandle readFuncHandle(c.wasmtime_func_t value) =>
    FuncHandle(value.store_id, value.privateData.address);

void writeFuncHandle(c.wasmtime_func_t value, FuncHandle handle) {
  value.store_id = handle.storeId;
  value.privateData = ffi.Pointer.fromAddress(handle.privateAddress);
}

MemoryHandle readMemoryHandle(c.wasmtime_memory_t value) => MemoryHandle(
  value.unnamed.store_id,
  value.unnamed.privateData1,
  value.privateData2,
);

void writeMemoryHandle(c.wasmtime_memory_t value, MemoryHandle handle) {
  value.unnamed.store_id = handle.storeId;
  value.unnamed.privateData1 = handle.privateData1;
  value.privateData2 = handle.privateData2;
}

TableHandle readTableHandle(c.wasmtime_table_t value) =>
    TableHandle(value.unnamed.store_id, value.unnamed.privateData1, value.privateData2);

void writeTableHandle(c.wasmtime_table_t value, TableHandle handle) {
  value.unnamed.store_id = handle.storeId;
  value.unnamed.privateData1 = handle.privateData1;
  value.privateData2 = handle.privateData2;
}

GlobalHandle readGlobalHandle(c.wasmtime_global_t value) => GlobalHandle(
  value.store_id,
  value.privateData1,
  value.privateData2,
  value.privateData3,
);

void writeGlobalHandle(c.wasmtime_global_t value, GlobalHandle handle) {
  value.store_id = handle.storeId;
  value.privateData1 = handle.privateData1;
  value.privateData2 = handle.privateData2;
  value.privateData3 = handle.privateData3;
}

/// A `wasmtime_instance_t`.
final class InstanceHandle {
  const InstanceHandle(this.storeId, this.privateData);

  static const InstanceHandle none = InstanceHandle(0, 0);

  final int storeId;
  final int privateData;

  bool get isNull => storeId == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstanceHandle &&
          other.storeId == storeId &&
          other.privateData == privateData;

  @override
  int get hashCode => Object.hash(storeId, privateData);

  @override
  String toString() =>
      isNull ? 'InstanceHandle.none' : 'InstanceHandle($storeId)';
}

InstanceHandle readInstanceHandle(c.wasmtime_instance_t value) =>
    InstanceHandle(value.store_id, value.privateData);

void writeInstanceHandle(c.wasmtime_instance_t value, InstanceHandle handle) {
  value.store_id = handle.storeId;
  value.privateData = handle.privateData;
}

