// Layer 1 - native ownership.
//
// Every wasmtime object that has to be released (`wasmtime_module_delete`,
// `wasm_engine_delete`, ...) is owned by exactly one Dart object that derives
// from [NativeOwner].  Nothing above this layer ever sees a `Pointer` that it
// is responsible for.

import 'dart:ffi' as ffi;

/// Releases a native object: the `*_delete` function of its type.
typedef NativeFree = void Function(ffi.Pointer<ffi.NativeType> pointer);

/// A pointer together with the function that releases it.
///
/// This lives in its own object so that the [Finalizer] token used by
/// [NativeOwner] does not reference the owner itself - a token that kept the
/// owner alive would mean the finalizer never runs.
final class NativeAllocation {
  NativeAllocation(this.pointer, this.free);

  final ffi.Pointer<ffi.NativeType> pointer;
  final NativeFree free;
  bool released = false;

  void release() {
    if (released) return;
    released = true;
    free(pointer);
  }
}

final Finalizer<NativeAllocation> _finalizer = Finalizer<NativeAllocation>(
  (allocation) => allocation.release(),
);

/// A Dart object that exclusively owns a native wasmtime object.
///
/// The object is released by [dispose].  As a safety net it is also released
/// when the Dart object is collected without having been disposed, so a missing
/// `dispose` leaks only until the next garbage collection instead of forever.
/// Note that this safety net cannot run for an isolate that has already exited.
abstract base class NativeOwner<P extends ffi.NativeType> {
  NativeOwner.owned(ffi.Pointer<P> pointer, void Function(ffi.Pointer<P>) free)
    : _allocation = NativeAllocation(
        pointer.cast<ffi.NativeType>(),
        (raw) => free(raw.cast<P>()),
      ) {
    _finalizer.attach(this, _allocation, detach: this);
  }

  final NativeAllocation _allocation;

  /// The native pointer, for use by the layers above.
  ///
  /// Throws a [StateError] once this object has been disposed; after that the
  /// pointer is dangling and must not be touched.
  ffi.Pointer<P> get pointer {
    checkNotDisposed();
    return _allocation.pointer.cast<P>();
  }

  /// Whether the native object has already been released.
  bool get isDisposed => _allocation.released;

  /// Throws a [StateError] if this object has been disposed.
  void checkNotDisposed() {
    if (_allocation.released) {
      throw StateError('$runtimeType has been disposed.');
    }
  }

  /// Releases the native object.  Idempotent.
  void dispose() {
    _finalizer.detach(this);
    _allocation.release();
  }

  /// Gives up ownership without releasing the object.
  ///
  /// Used where the C API transfers ownership to another object, e.g.
  /// `wasm_engine_new_with_config` consuming a `wasm_config_t`.  After this the
  /// Dart object behaves as if disposed.
  void disown() {
    _finalizer.detach(this);
    _allocation.released = true;
  }

  @override
  String toString() => '$runtimeType(${isDisposed ? 'disposed' : 'live'})';
}
