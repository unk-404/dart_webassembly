## 0.1.0

* First release.
* `package:webassembly/webassembly.dart` - the JavaScript shaped `WebAssembly`
  API (`WebAssembly`, `Module`, `Instance`, `Memory`, `Table`, `Global`,
  `CompileError`, `LinkError`, `RuntimeError`), implemented by
  [wasmtime](https://wasmtime.dev) on native platforms and by the browser's own
  `WebAssembly` on the web.
* `package:webassembly/wasmtime.dart` - the wasmtime API: engine, store, linker,
  module, the value and type model, host function trampolines, configuration,
  fuel, and module serialisation.
* `package:webassembly/parallel.dart` - `WasmWorker` and `WasmPool`, which keep
  WebAssembly off the calling isolate and spread it over several threads.
* `package:webassembly/raw.dart` - the generated C bindings.
* wasmtime is compiled from source by the build hook, with the feature set
  `cranelift, threads, async, component-model, component-model-async, cache,
  parallel-compilation, pooling-allocator, gc, gc-drc, gc-null, gc-copying,
  demangle, addr2line, coredump`.
* The wasmtime sources are a pinned download at build time; they are not part of
  the published package.
