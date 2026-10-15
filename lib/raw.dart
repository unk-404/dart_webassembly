/// The raw C API, exactly as ffigen generated it.
///
/// Everything here maps one to one to a function, struct or constant of the
/// wasmtime C API in `lib/src/wasmtime_bindings_generated.dart`.  It is
/// exported so that nothing is out of reach, but it is also unguarded: the
/// pointers are raw and nothing is released for you.
///
/// Prefer:
///
/// * `package:webassembly/webassembly.dart` - the JavaScript shaped
///   `WebAssembly` API and the non-blocking worker API.
/// * `package:webassembly/wasmtime.dart` - the wasmtime engine/store/linker
///   API, which owns its native objects.
library;

export 'src/wasmtime_bindings_generated.dart';
