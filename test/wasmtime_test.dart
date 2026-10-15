// Tests for layer 1 (ownership/marshalling) and layer 2 (the wasmtime API).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_wasm/wasmtime.dart';
import 'package:test/test.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/$name.wasm').readAsBytesSync();

void main() {
  late WasmEngine engine;
  setUpAll(() => engine = WasmEngine());
  tearDownAll(() => engine.dispose());

  /// Compiles `fixture(name)`, defines the imports with [define], instantiates
  /// it and releases everything when the test ends.
  WasmInstance instantiate(
    String name, {
    void Function(WasmLinker linker, WasmStore store)? define,
  }) {
    final module = WasmModule.compile(engine, fixture(name));
    final store = WasmStore(engine);
    final linker = WasmLinker(engine);
    define?.call(linker, store);
    final instance = linker.instantiate(store, module);
    addTearDown(() {
      linker.dispose();
      store.dispose();
      module.dispose();
    });
    return instance;
  }

  WasmFunc func(WasmInstance instance, String name) =>
      instance.export(name)! as WasmFunc;

  group('modules', () {
    test('lists imports and exports with their types', () {
      final module = WasmModule.compile(engine, fixture('imports'));
      final store = WasmStore(engine);
      final linker = WasmLinker(engine);
      addTearDown(() {
        linker.dispose();
        store.dispose();
        module.dispose();
      });

      expect(module.imports.map((i) => '${i.module}.${i.name}'), [
        'env.log',
        'env.sum',
        'env.mem',
      ]);
      expect(module.imports[0].type, isA<WasmFuncExternType>());
      expect(
        (module.imports[0].type as WasmFuncExternType).type.toString(),
        '(i32) -> ()',
      );
      expect(module.imports[2].type, isA<WasmMemoryExternType>());
      expect(
        module.imports[2].type.kind,
        WasmExternKind.memory,
      );

      expect(module.exports.map((e) => e.name), [
        'call_log',
        'call_sum',
        'read_imported_memory',
        'boom',
      ]);
      expect(module.exports.first.kind, WasmExternKind.func);
    });

    test('serialises and deserialises a compiled module', () {
      final module = WasmModule.compile(engine, fixture('arithmetic'));
      addTearDown(module.dispose);
      final blob = module.serialize();
      expect(blob, isNotEmpty);

      final restored = WasmModule.deserialize(engine, blob);
      addTearDown(restored.dispose);
      final store = WasmStore(engine);
      addTearDown(store.dispose);
      final instance = WasmLinker(engine).instantiate(store, restored);
      expect(func(instance, 'answer').invoke(const []), 42);
    });

    test('rejects a malformed module', () {
      expect(engine.validate(Uint8List.fromList([1, 2, 3])), isFalse);
      expect(
        () => engine.compile(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<WasmtimeException>()),
      );
    });
  });

  group('calling', () {
    test('passes and returns every scalar kind', () {
      final instance = instantiate('arithmetic');
      expect(func(instance, 'add').invoke([20, 22]), 42);
      expect(func(instance, 'answer').invoke(const []), 42);
      expect(func(instance, 'twice').invoke([21]), 42);
      expect(func(instance, 'half').invoke([84.0]), 42.0);
    });

    test('returns several results as a list', () {
      final instance = instantiate('arithmetic');
      expect(func(instance, 'swap').invoke([1, 2]), [2, 1]);
    });

    test('the arity adapter makes exports callable like JavaScript', () {
      final instance = instantiate('arithmetic');
      final add = func(instance, 'add').function;
      expect(add(20, 22), 42);
      expect(Function.apply(add, [1, 2]), 3);
    });

    test('checks argument arity and types', () {
      final instance = instantiate('arithmetic');
      expect(() => func(instance, 'add').call([1]), throwsArgumentError);
      expect(
        () => func(instance, 'add').call(['a', 'b']),
        throwsArgumentError,
      );
      expect(() => func(instance, 'add').call([1 << 40, 0]), throwsRangeError);
    });

    test('traps surface as WasmTrapException', () {
      final instance = instantiate('arithmetic');
      expect(
        () => func(instance, 'boom').call(const []),
        throwsA(
          isA<WasmTrapException>().having(
            (e) => e.message,
            'message',
            contains('unreachable'),
          ),
        ),
      );
      expect(
        () => func(instance, 'div').call([1, 0]),
        throwsA(isA<WasmTrapException>()),
      );
    });
  });

  group('host functions', () {
    test('are called with decoded arguments', () {
      final calls = <int>[];
      final instance = instantiate(
        'imports',
        define: (linker, store) {
          linker.defineFunction(
            'env',
            'log',
            const WasmFuncType(
              parameters: [WasmValueKind.i32],
              results: [],
            ),
            (args) {
              calls.add(args.single! as int);
              return null;
            },
          );
          linker.defineFunction(
            'env',
            'sum',
            const WasmFuncType(
              parameters: [WasmValueKind.i32, WasmValueKind.i32],
              results: [WasmValueKind.i32],
            ),
            (args) => (args[0]! as int) + (args[1]! as int),
          );
          linker.defineMemory(
            'env',
            'mem',
            store,
            WasmMemory.create(store, initial: 1),
          );
        },
      );

      expect(func(instance, 'call_sum').invoke([40, 2]), 42);
      func(instance, 'call_log').call([7]);
      expect(calls, [7]);
    });

    test('a throwing host function propagates to the caller', () {
      final instance = instantiate(
        'imports',
        define: (linker, store) {
          linker.defineFunction(
            'env',
            'log',
            const WasmFuncType(
              parameters: [WasmValueKind.i32],
              results: [],
            ),
            (_) => throw StateError('nope'),
          );
          linker.defineFunction(
            'env',
            'sum',
            const WasmFuncType(
              parameters: [WasmValueKind.i32, WasmValueKind.i32],
              results: [WasmValueKind.i32],
            ),
            (args) => 0,
          );
          linker.defineMemory(
            'env',
            'mem',
            store,
            WasmMemory.create(store, initial: 1),
          );
        },
      );

      expect(
        () => func(instance, 'call_log').call([1]),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'nope'),
        ),
      );
    });

    test('a missing import is a link error', () {
      final module = WasmModule.compile(engine, fixture('imports'));
      final store = WasmStore(engine);
      final linker = WasmLinker(engine);
      addTearDown(() {
        linker.dispose();
        store.dispose();
        module.dispose();
      });
      expect(
        () => linker.instantiate(store, module),
        throwsA(isA<WasmtimeException>()),
      );
    });
  });

  group('memory', () {
    test('reads and writes through the buffer view', () {
      final instance = instantiate('memory');
      final memory = instance.export('mem')! as WasmMemory;

      expect(memory.lengthInPages, 1);
      expect(memory.lengthInBytes, 65536);
      expect(memory.pageSize, 65536);
      expect(String.fromCharCodes(memory.buffer.sublist(8, 13)), 'hello');

      memory.buffer[0] = 0x2A;
      expect(func(instance, 'load').invoke([0]), 0x2A);

      func(instance, 'store').call([4, 1234]);
      expect(memory.buffer.buffer.asByteData().getUint32(4, Endian.little), 1234);

      final previous = memory.grow(1);
      expect(previous, 1);
      expect(memory.lengthInPages, 2);
      expect(func(instance, 'size').invoke(const []), 2);
    });

    test('can be created and imported by name', () {
      final instance = instantiate(
        'imports',
        define: (linker, store) {
          linker.defineFunction(
            'env',
            'log',
            const WasmFuncType(parameters: [WasmValueKind.i32], results: []),
            (_) => null,
          );
          linker.defineFunction(
            'env',
            'sum',
            const WasmFuncType(
              parameters: [WasmValueKind.i32, WasmValueKind.i32],
              results: [WasmValueKind.i32],
            ),
            (args) => 0,
          );
          final memory = WasmMemory.create(store, initial: 1, maximum: 2);
          memory.buffer[0] = 99;
          linker.defineMemory('env', 'mem', store, memory);
        },
      );
      expect(func(instance, 'read_imported_memory').invoke([0]), 99);
    });
  });

  group('globals', () {
    test('read, write and report mutability', () {
      final instance = instantiate('globals');
      final counter = instance.export('counter')! as WasmGlobal;
      final fixed = instance.export('fixed')! as WasmGlobal;
      final ratio = instance.export('ratio')! as WasmGlobal;

      expect(counter.type.mutable, isTrue);
      expect(counter.value, 0);
      counter.value = 41;
      expect(counter.value, 41);
      expect(func(instance, 'bump').invoke(const []), 42);
      expect(counter.value, 42);

      expect(fixed.type.mutable, isFalse);
      expect(fixed.value, 7);
      expect(() => fixed.value = 1, throwsA(isA<WasmtimeException>()));

      expect(ratio.value, 1.5);
      ratio.value = 3.5;
      expect(ratio.value, 3.5);
    });
  });

  group('tables', () {
    test('read, call and write entries', () {
      final instance = instantiate('table');
      final table = instance.export('tbl')! as WasmTable;

      expect(table.length, 2);
      expect(table.type.element, WasmValueKind.funcRef);

      final entry = table.get(0);
      expect(entry, isA<WasmFunc>());
      expect((entry! as WasmFunc).invoke(const []), 1);

      expect(func(instance, 'call_zero').invoke(const []), 1);
      expect(func(instance, 'call_one').invoke(const []), 2);

      // Move the second function into slot 0 and call it through the table.
      table.set(0, table.get(1));
      expect(func(instance, 'call_zero').invoke(const []), 2);

      expect(table.grow(1, null), 2);
      expect(table.length, 3);
      expect(() => table.get(99), throwsRangeError);
    });
  });

  group('stores', () {
    test('run out of fuel', () {
      final fuelled = WasmEngine.configured((config) => config.consumeFuel = true);
      addTearDown(fuelled.dispose);
      final module = WasmModule.compile(fuelled, fixture('arithmetic'));
      final store = WasmStore(fuelled);
      addTearDown(() {
        store.dispose();
        module.dispose();
      });
      final instance = WasmLinker(fuelled).instantiate(store, module);

      store.fuel = 10000;
      expect(store.fuel, 10000);
      expect(func(instance, 'answer').invoke(const []), 42);
      expect(store.fuel, lessThan(10000));
    });

    test('without fuel configured the getter reports null', () {
      final store = WasmStore(engine);
      addTearDown(store.dispose);
      expect(store.fuel, isNull);
    });
  });

  group('ownership', () {
    test('disposed objects refuse to be used', () {
      final store = WasmStore(engine);
      final module = WasmModule.compile(engine, fixture('arithmetic'));
      store.dispose();
      module.dispose();
      expect(store.isDisposed, isTrue);
      expect(() => store.context, throwsStateError);
      expect(() => module.imports, throwsStateError);
    });

    test('an engine keeps working after a store is released', () {
      final store = WasmStore(engine)..dispose();
      expect(store.isDisposed, isTrue);
      final module = WasmModule.compile(engine, fixture('arithmetic'));
      final other = WasmStore(engine);
      addTearDown(() {
        other.dispose();
        module.dispose();
      });
      final instance = WasmLinker(engine).instantiate(other, module);
      expect(func(instance, 'answer').invoke(const []), 42);
    });
  });
}
