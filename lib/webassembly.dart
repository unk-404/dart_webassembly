/// Dart/Flutter bindings for WebAssembly, on one API for every platform.
///
/// This is the entry point for normal use.  It exposes the JavaScript shaped
/// `WebAssembly` API and nothing else, and the implementation behind it is
/// chosen automatically:
///
/// * on native platforms - Android, iOS, Linux, macOS, Windows - it runs on
///   **wasmtime**, compiled from source by this package's build hook;
/// * on the web it runs on the **browser's own** `WebAssembly`.
///
/// Because the API is the same, the same Dart code runs in both places:
///
/// ```dart
/// import 'package:webassembly/webassembly.dart';
///
/// final module = await WebAssembly.compile(wasmBytes);
/// final instance = await WebAssembly.instantiate(module, {
///   'env': {'log': (int value) => print(value)},
/// });
/// print((instance.exports['add'] as Function)(20, 22));
/// ```
///
/// wasmtime itself is only reachable through a separate import, because it only
/// exists on native platforms:
///
/// * `package:webassembly/wasmtime.dart` - engines, stores, linkers,
///   configuration, fuel, host function trampolines, module serialisation and
///   the type model, all wrapped for Dart.
/// * `package:webassembly/parallel.dart` - keep WebAssembly off the calling
///   isolate and spread it over several threads (isolates; native only).
/// * `package:webassembly/raw.dart` - the generated C bindings, unguarded.
library;

export 'src/api/types.dart'
    show
        CompileError,
        ExportDescriptor,
        GlobalDescriptor,
        ImportDescriptor,
        LinkError,
        MemoryDescriptor,
        RuntimeError,
        TableDescriptor,
        WasmException;
export 'src/api/webassembly.dart'
    show
        Global,
        Instance,
        InstantiatedModule,
        Memory,
        Module,
        Table,
        WebAssembly;
