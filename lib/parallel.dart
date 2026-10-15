/// Run WebAssembly without blocking the calling isolate, on one thread or on
/// several.
///
/// A [WasmWorker] owns a wasmtime engine and store inside its own isolate;
/// [WasmPool] keeps one worker per processor so that calls can be spread over
/// several threads.  Every operation is a `Future`, so a long running
/// WebAssembly call never blocks the UI isolate:
///
/// ```dart
/// final worker = await WasmWorker.spawn();
/// final module = await worker.compile(wasmBytes);
/// final instance = await module.instantiate();
/// print(await instance.invoke('add', [20, 22]));
/// await worker.dispose();
/// ```
///
/// ```dart
/// final pool = await WasmPool.spawn(workers: 4);
/// final instance = await (await pool.load(wasmBytes)).instantiate();
/// final results = await instance.callAll('work', [[1], [2], [3], [4]]);
/// await pool.dispose();
/// ```
///
/// Values cross an isolate boundary by copy, and only plain data can be sent:
/// `null`, numbers, strings, lists, maps and `Uint8List`.  Function references
/// and memories stay on the worker; reach them by export name.  Import objects
/// may contain Dart functions (which are copied to the worker) and, for
/// memories, tables and globals, descriptors instead of live objects.
library;

export 'src/api/types.dart'
    show GlobalDescriptor, MemoryDescriptor, TableDescriptor;
export 'src/ffi/errors.dart' show WasmTrapException, WasmtimeException;
export 'src/ffi/marshal.dart' show Limits;
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
export 'src/ffi/values.dart' show WasmValueKind;
export 'src/parallel/pool.dart';
export 'src/parallel/worker.dart';
