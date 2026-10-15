## 0.1.1

* **Fix: 0.1.0 shipped broken.** Its `.pubignore` had unrooted patterns
  (`wasmtime/`, `build/`), which match a directory of that name at *any* depth,
  so `lib/src/wasmtime/` and `lib/src/toolchain/` were left out of the archive;
  `package:webassembly/wasmtime.dart` - and therefore the unified API - did not
  compile.  The patterns are rooted now, and CI checks that every part of the
  library is in the published archive.  0.1.0 is retracted.
* **Fix: pana's resolution check.** With the lowest allowed dependencies, `dart
  pub downgrade` picked `platform` 3.0.0, whose `Platform.packageRoot` current
  SDKs removed, so ffigen's build hook no longer compiled and pub.dev reported
  `[pub-downgrade-failed]`.  `platform` now has a floor of `^3.2.0`, and CI
  compiles every build hook in the dependency graph at the lowest versions.
* The build hook helper moved from `hook/src/` to `lib/src/toolchain/`: a
  package may only contain the hook entry points (`hook/build.dart`,
  `hook/link.dart`).
* CI on every push: analysis, the published file layout, the native and browser
  test suites, the lowest allowed dependencies, and builds of the example for
  Windows and the web (the last one not on pull requests).
* `test/wasmtime_sources_test.dart` covers where the build hook gets the
  wasmtime sources from, including the pinned download when
  `WASMTIME_DOWNLOAD_TEST=1`.

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
