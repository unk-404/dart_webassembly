# webassembly

WebAssembly for Dart and Flutter, on one API for every platform.

* on **native platforms** - Android, iOS, Linux, macOS, Windows - it runs on
  [wasmtime](https://wasmtime.dev), which this package compiles from source as
  part of your build;
* on the **web** it runs on the browser's own `WebAssembly`.

Which engine you get is decided at compile time by a conditional import, so the
code you write is the same either way.

## The unified API

```dart
import 'package:webassembly/webassembly.dart';

final module = await WebAssembly.compile(wasmBytes);
final instance = await WebAssembly.instantiate(module, {
  'env': {'log': (int value) => print(value)},
});

print((instance.exports['add'] as Function)(20, 22));
print(instance.exports['mem']! as Memory);
```

`WebAssembly`, `Module`, `Instance`, `Memory`, `Table`, `Global`,
`CompileError`, `LinkError` and `RuntimeError` follow the JavaScript API of the
same names. `test/unified_api_test.dart` is one platform neutral file - it
embeds its `.wasm` fixtures instead of reading files - and is run against both
engines:

```sh
dart test test/unified_api_test.dart             # wasmtime
dart test -p chrome test/unified_api_test.dart   # a real browser
```

### Entry points

| Import | Contents |
| --- | --- |
| `package:webassembly/webassembly.dart` | the unified API; the only import a portable application needs |
| `package:webassembly/wasmtime.dart` | the wasmtime API: engines, stores, linkers, the type model, host function trampolines, configuration, fuel, module serialisation |
| `package:webassembly/parallel.dart` | `WasmWorker` and `WasmPool`: run WebAssembly off the calling isolate, or on several threads |
| `package:webassembly/raw.dart` | the generated C bindings, unguarded |

Everything except `webassembly.dart` is native only and needs its own import -
by design, since wasmtime, isolates and the C ABI do not exist on the web.

### What differs on the web

| | native | web |
| --- | --- | --- |
| `i64` values | `int` | `BigInt` (JavaScript has no 64 bit integers) |
| module serialisation | `Module.serialize` in `wasmtime.dart` | not available |
| engines, configuration, fuel | `wasmtime.dart` | not available |
| `WasmWorker`, `WasmPool` | isolates | not available |
| errors | `CompileError` / `LinkError` / `RuntimeError` | the same, mapped from the browser's |

The web backend maps the browser's linking failures onto `LinkError`, which is
what the specification and wasmtime report, so both engines hand you the same
error types.

## Requirements

* a **Dart/Flutter SDK with build hooks and code assets** - verified with Dart
  3.13.5 and Flutter 3.47.7;
* **Rust** - `cargo` has to be on `PATH`; wasmtime is a Rust library, and only
  cargo can compile it;
* **CMake and a C toolchain** - on Windows, Visual Studio with *Desktop
  development with C++* (the hook applies `vcvars` itself). CMake must also be
  reachable from `PATH` while cargo runs, because wasmtime's own C API build
  script shells out to it; `vcvars` provides it;
* **git** - the first native build downloads the pinned wasmtime revision.

The first native build downloads about 100 MB of sources and compiles wasmtime,
which takes a while; every build after that is incremental. A web build does no
native work at all.

## Where wasmtime comes from

The wasmtime sources are **not** part of the published package. The build hook
resolves them in this order:

1. `hooks.user_defines` from your `pubspec.yaml`:

   ```yaml
   hooks:
     user_defines:
       webassembly:
         wasmtime_source_dir: /path/to/a/wasmtime/checkout
   ```

2. `$WASMTIME_SOURCE_DIR`. Build hooks run in a semi-hermetic environment that
   strips almost every environment variable, so this one only applies when the
   hook is invoked directly; inside a Flutter or Dart build use the user define
   above.
3. the `wasmtime/` git submodule, which is how this package is developed;
4. otherwise a shallow download of one pinned revision into the per-user cache
   (`%LOCALAPPDATA%\dart_webassembly` on Windows, `~/Library/Caches/...` on
   macOS, `$XDG_CACHE_HOME` elsewhere), where later builds find it again.

Notes:

* A checkout is whatever `git clone` of
  `https://github.com/bytecodealliance/wasmtime` at the revision in
  `hook/src/wasmtime_sources.dart` gives you.
* Leave `CARGO_TARGET_DIR` unset. Upstream's CMake lets cargo choose its own
  target directory but derives the path it installs from from
  `$CARGO_TARGET_DIR`, which do not always agree.

## Using wasmtime directly

```dart
import 'package:webassembly/wasmtime.dart';

final engine = WasmEngine.configured((config) {
  config.strategy = WasmStrategy.cranelift;
  config.optLevel = WasmOptLevel.speed;
});
final module = WasmModule.compile(engine, wasmBytes);
final store = WasmStore(engine);
final instance = WasmLinker(engine).instantiate(store, module);

print((instance.export('add')! as WasmFunc).call([20, 22]));
```

## Running off the calling isolate

```dart
import 'package:webassembly/parallel.dart';

final worker = await WasmWorker.spawn();          // its own engine and store
final module = await worker.compile(wasmBytes);
final instance = await module.instantiate();
print(await instance.invoke('add', [20, 22]));    // never blocks the caller
await worker.dispose();

// ... or spread the work over every processor:
final pool = await WasmPool.spawn(workers: 4);
final pooled = await (await pool.load(wasmBytes)).instantiate();
print(await pooled.callAll('work', [[1], [2], [3], [4]]));
await pool.dispose();
```

## Regenerating the bindings

ffigen parses the headers of the wasmtime checkout, which need the generated
`wasmtime/conf.h` - the file that says which features exist. Configuring the
project writes it to `build/ffigen/include/`:

```sh
cmake -S src -B build/ffigen-conf
dart run ffigen --config ffigen.yaml
```

## Development

```sh
dart test                                      # wasmtime, workers and pools
dart test -p chrome test/unified_api_test.dart  # the same API in a browser
cd example && flutter build windows             # bundles wasmtime.dll
cd example && flutter build web                 # uses the browser instead
```

Cargo writes to the checkout's own `target/` directory (for the submodule,
`wasmtime/target/`, which the submodule ignores).

## License

Apache-2.0; see [LICENSE](LICENSE).

wasmtime itself is licensed under Apache-2.0 **with LLVM exceptions**. It is
downloaded and compiled at build time, and the resulting shared library is
redistributed inside your application, so keep
[wasmtime's license](https://github.com/bytecodealliance/wasmtime/blob/main/LICENSE)
in mind when you ship.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/webassembly.dart` | the unified API: the browser shaped `WebAssembly` |
| `lib/src/api/webassembly.dart` | that API, free of any backend |
| `lib/src/api/backend_io.dart` | its wasmtime backend |
| `lib/src/api/backend_web.dart` | its browser backend (`dart:js_interop`) |
| `lib/src/ffi/` | ownership, marshalling, errors and values over the raw bindings |
| `lib/src/wasmtime/` | the wasmtime engine, store, linker, module and handle API |
| `lib/src/parallel/` | `WasmWorker` and `WasmPool` |
| `lib/src/wasmtime_bindings_generated.dart` | the generated C bindings (do not edit) |
| `hook/build.dart` | the build hook Flutter and Dart run |
| `hook/src/wasmtime_sources.dart` | where the wasmtime sources come from |
| `src/CMakeLists.txt` | selects the cargo features and builds the C API as a shared library |
| `ffigen.yaml` | ffigen configuration |
| `example/` | a Flutter app that builds for Windows and for the web |
| `wasmtime/` | the git submodule, for development only |
