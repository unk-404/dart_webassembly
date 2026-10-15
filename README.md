# flutter_wasm

WebAssembly for Flutter and Dart, on one API for every platform.

* on **native platforms** - Android, iOS, Linux, macOS, Windows - it runs on
  [wasmtime](https://wasmtime.dev), built from source as part of your build;
* on the **web** it runs on the browser's own `WebAssembly`.

Which one you get is decided at compile time; the code you write is the same.

The native library is **built from source as part of your build**.
`hook/build.dart` drives `src/CMakeLists.txt` through
[package:native_toolchain_cmake], which asks cargo to build the
`wasmtime-c-api` cdylib out of the `wasmtime/` git submodule. The resulting
shared library (`wasmtime.dll` / `libwasmtime.so` / `libwasmtime.dylib`) is
registered as a native code asset, so the Flutter/Dart SDK bundles it next to
your application, and the bindings in `lib/src/wasmtime_bindings_generated.dart`
resolve their symbols from it (`ffi-native.asset-id` in `ffigen.yaml`). A build
that produces no native code, such as a web build, is skipped.

## The unified API

```dart
import 'package:flutter_wasm/flutter_wasm.dart';

final module = await WebAssembly.compile(wasmBytes);
final instance = await WebAssembly.instantiate(module, {
  'env': {'log': (int value) => print(value)},
});

print((instance.exports['add'] as Function)(20, 22));
print(instance.exports['mem']! as Memory);
```

`WebAssembly`, `Module`, `Instance`, `Memory`, `Table`, `Global`,
`CompileError`, `LinkError` and `RuntimeError` follow the JavaScript API of the
same names, so this layer ports to the web unchanged; `test/unified_api_test.dart`
is run against both backends to keep it that way.

```sh
dart test test/unified_api_test.dart             # wasmtime
dart test -p chrome test/unified_api_test.dart   # the browser
```

### Entry points

| Import | Contents |
| --- | --- |
| `package:flutter_wasm/flutter_wasm.dart` | the unified API; the only import a portable application needs |
| `package:flutter_wasm/wasmtime.dart` | the wasmtime API: engines, stores, linkers, configuration, fuel, host trampolines, module serialisation, the type model |
| `package:flutter_wasm/parallel.dart` | `WasmWorker` and `WasmPool`: keep WebAssembly off the calling isolate, and spread it over several threads |
| `package:flutter_wasm/raw.dart` | the generated C bindings, unguarded |

Everything except `flutter_wasm.dart` is native only, and needs its own import -
by design, since wasmtime, isolates and the C ABI do not exist on the web.

### What differs on the web

The two backends are the same API, but they are still two different engines, and
Dart sits between them:

| | native | web |
| --- | --- | --- |
| `i64` values | `int` | `BigInt` (JavaScript has no 64 bit integers) |
| module serialisation | `Module.serialize` in `wasmtime.dart` | not available |
| engines, configuration, fuel | `wasmtime.dart` | not available |
| `WasmWorker`, `WasmPool` | isolates | not available - use the platform's own workers |
| errors | `CompileError` / `LinkError` / `RuntimeError` | the same, mapped from the browser's |

## Requirements

* **Rust** - `cargo` has to be on `PATH`; wasmtime is a Rust library and only
  cargo can compile it.
* **CMake and a C toolchain** - on Windows, Visual Studio with *Desktop
  development with C++* (the hook applies `vcvars` itself). CMake must also be
  reachable from `PATH` while cargo runs, because wasmtime's own C API build
  script shells out to it; `vcvars` provides it.
* The submodule: `git submodule update --init --recursive`.

## Features

The library is built with exactly this cargo feature set, selected in
`src/CMakeLists.txt`:

```
cranelift, threads, async, component-model, component-model-async, cache,
parallel-compilation, pooling-allocator, gc, gc-drc, gc-null, gc-copying,
demangle, addr2line, coredump
```

Upstream's `cmake/features.cmake` enables a much larger default set, so the
project starts from `WASMTIME_DISABLE_ALL_FEATURES=ON` and switches on just the
features above. `gc-copying` has no `WASMTIME_FEATURE_*` switch upstream yet, so
it is handed straight to cargo.

## Using wasmtime directly

```dart
import 'package:flutter_wasm/wasmtime.dart';

final engine = WasmEngine.configured((config) {
  config.strategy = WasmStrategy.cranelift;
  config.optLevel = WasmOptLevel.speed;
});
final module = WasmModule.compile(engine, wasmBytes);
final store = WasmStore(engine);
final instance = WasmLinker(engine).instantiate(store, module);

final add = instance.export('add')! as WasmFunc;
print(add.call([20, 22]));
```

## Running off the calling isolate

```dart
import 'package:flutter_wasm/parallel.dart';

final worker = await WasmWorker.spawn();          // its own engine and store
final module = await worker.compile(wasmBytes);
final instance = await module.instantiate();
print(await instance.invoke('add', [20, 22]));     // never blocks the caller
await worker.dispose();

// ... or spread the work over every processor:
final pool = await WasmPool.spawn(workers: 4);
final pooled = await (await pool.load(wasmBytes)).instantiate();
print(await pooled.callAll('work', [[1], [2], [3], [4]]));
await pool.dispose();
```

## Regenerating the bindings

ffigen parses the headers of the submodule, which need the generated
`wasmtime/conf.h` - the file that tells them which features exist. Configuring
the project writes it to `build/ffigen/include/`:

```sh
cmake -S src -B build/ffigen-conf
dart run ffigen --config ffigen.yaml
```

## Tests

```sh
dart test                                          # wasmtime, workers and pools
dart test -p chrome test/unified_api_test.dart      # the same API in a browser
cd example && flutter build windows                 # bundles wasmtime.dll
cd example && flutter build web                     # uses the browser instead
```

`test/unified_api_test.dart` embeds its `.wasm` fixtures, so it runs on both.

## Build cache

Cargo writes to `wasmtime/target/`, wasmtime's own default location (git-ignored
by the submodule). The first build compiles all of wasmtime and takes a while;
later builds are incremental. Set `CARGO_TARGET_DIR` to relocate it.

## Layout

| Path | Purpose |
| --- | --- |
| `src/CMakeLists.txt` | selects the features and builds the C API as a shared library |
| `hook/build.dart` | the build hook that Flutter/Dart runs |
| `ffigen.yaml` | ffigen configuration |
| `lib/flutter_wasm.dart` | the unified API: the browser shaped `WebAssembly` |
| `lib/src/api/webassembly.dart` | that API, free of any backend |
| `lib/src/api/backend_io.dart` | its wasmtime backend |
| `lib/src/api/backend_web.dart` | its browser backend (`dart:js_interop`) |
| `lib/src/ffi/` | ownership, marshalling, errors and values over the raw bindings |
| `lib/src/wasmtime/` | the wasmtime engine, store, linker, module and handle API |
| `lib/src/parallel/` | `WasmWorker` and `WasmPool` |
| `lib/src/wasmtime_bindings_generated.dart` | generated bindings (do not edit) |
| `example/` | Flutter app that builds for Windows and for the web |
| `wasmtime/` | git submodule with the wasmtime sources |

[package:native_toolchain_cmake]: https://pub.dev/packages/native_toolchain_cmake
