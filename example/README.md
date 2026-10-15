# webassembly_example

Loads `assets/demo.wasm` - a two function module that imports `env.log` - and
runs it through `package:webassembly`:

```dart
final module = await WebAssembly.compile(bytes);
final instance = await WebAssembly.instantiate(module, {
  'env': {'log': (int value) => print(value)},
});
print((instance.exports['add'] as Function)(20, 22));
```

The same `lib/main.dart` runs on both backends, because the package picks one at
compile time: wasmtime on Windows (and the other native platforms), the
browser's own `WebAssembly` on the web.

```sh
flutter run -d windows      # or: flutter build windows
flutter run -d chrome       # or: flutter build web
```

The screen says which backend it is running on. On Windows the build compiles
wasmtime from source and puts `wasmtime.dll` next to the executable; a web build
downloads and compiles nothing, because the browser brings its own WebAssembly.
