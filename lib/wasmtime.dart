/// The full, wasmtime specific API.
///
/// This is the layer below `package:flutter_wasm/flutter_wasm.dart`: engines,
/// stores, linkers, host functions and the raw value model, without the
/// JavaScript shaped facade.  Use it when you need something the WebAssembly
/// API does not express - configuring fuel, shared memories, module
/// serialisation, `WasmMemory.grow` return values, and so on.
///
/// ```dart
/// final engine = WasmEngine();
/// final module = WasmModule.compile(engine, wasmBytes);
/// final store = WasmStore(engine);
/// final linker = WasmLinker(engine)
///   ..defineFunction('env', 'log', WasmFuncType(parameters: [WasmValueKind.i32], results: []), (args) {
///     print(args.first);
///     return null;
///   });
/// final instance = linker.instantiate(store, module);
/// final add = instance.export('add')! as WasmFunc;
/// print(add.invoke([1, 2]));
/// ```
library;

export 'src/ffi/errors.dart'
    show WasmTrapException, WasmtimeException, trapCodeName;
export 'src/ffi/marshal.dart' show Limits;
export 'src/ffi/values.dart'
    show
        FuncHandle,
        GlobalHandle,
        InstanceHandle,
        MemoryHandle,
        TableHandle,
        WasmValueKind;
export 'src/wasmtime/engine.dart'
    show WasmConfig, WasmEngine, WasmOptLevel, WasmStrategy;
export 'src/wasmtime/handles.dart'
    show
        WasmFunc,
        WasmGlobal,
        WasmMemory,
        WasmTable,
        dartToExtern,
        externToDart,
        toDartValue,
        toNativeValue;
export 'src/wasmtime/host.dart' show WasmHostFunction, WasmHostTrampoline;
export 'src/wasmtime/instance.dart' show WasmInstance;
export 'src/wasmtime/linker.dart' show WasmLinker;
export 'src/wasmtime/module.dart' show WasmEngineCompilation, WasmModule;
export 'src/wasmtime/store.dart' show WasmStore;
export 'src/wasmtime/types.dart'
    show
        WasmExport,
        WasmExternKind,
        WasmExternType,
        WasmFuncExternType,
        WasmFuncType,
        WasmGlobalExternType,
        WasmImport,
        WasmMemoryExternType,
        WasmTableExternType;
