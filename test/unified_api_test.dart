// Tests for the unified API.
//
// This file is deliberately platform neutral: it embeds its fixtures instead of
// reading files, so the very same Dart code runs
//
//     dart test test/unified_api_test.dart          # wasmtime
//     dart test -p chrome test/unified_api_test.dart # the browser
//
// which is the whole point of `package:webassembly/webassembly.dart`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:webassembly/webassembly.dart';
import 'package:test/test.dart';

/// True when compiled for the web with dart2js, where `0` and `0.0` are the
/// same object.  Only used to allow for the places where the web and native
/// WebAssembly APIs legitimately differ.
final bool _isWeb = identical(0, 0.0);

// The .wasm fixtures, base64 encoded.  `test/fixtures/*.wasm` holds the same
// bytes, assembled from WAT; see .agent/notes.md.
const String _arithmetic =
    'AGFzbQEAAAABHwZgAn9/AX9gAAF/YAF+AX5gAXwBfGACf38Cf39gAAADCAcAAQACAwQFBzMHA2Fk'
    'ZAAABmFuc3dlcgABA2RpdgACBXR3aWNlAAMEaGFsZgAEBHN3YXAABQRib29tAAYKOAcHACAAIAFq'
    'CwQAQSoLBwAgACABbQsHACAAQgJ+Cw4AIABEAAAAAAAAAECjCwYAIAEgAAsDAAAL';

const String _memory =
    'AGFzbQEAAAABDwNgAX8Bf2ACf38AYAABfwMFBAABAAIFBAEBAQQHJAUDbWVtAgAEbG9hZAAABXN0'
    'b3JlAAEEZ3JvdwACBHNpemUAAwofBAcAIAAoAgALCQAgACABNgIACwYAIABAAAsEAD8ACwsLAQBB'
    'CAsFaGVsbG8=';

const String _globals =
    'AGFzbQEAAAABBQFgAAF/AwIBAAYXA38BQQALfwBBBwt8AUQAAAAAAAD4PwsHIgQHY291bnRlcgMA'
    'BWZpeGVkAwEFcmF0aW8DAgRidW1wAAAKDQELACMAQQFqJAAjAAs=';

const String _imports =
    'AGFzbQEAAAABEwRgAX8AYAJ/fwF/YAF/AX9gAAACIAMDZW52A2xvZwAAA2VudgNzdW0AAQNlbnYD'
    'bWVtAgABAwUEAAECAwc1BAhjYWxsX2xvZwACCGNhbGxfc3VtAAMUcmVhZF9pbXBvcnRlZF9tZW1v'
    'cnkABARib29tAAUKHQQGACAAEAALCAAgACABEAELBwAgACgCAAsDAAALABIEbmFtZQELAgADbG9n'
    'AQNzdW0=';

const String _table =
    'AGFzbQEAAAABBQFgAAF/AwUEAAAAAAQFAXABAgQHHgMDdGJsAQAJY2FsbF96ZXJvAAIIY2FsbF9v'
    'bmUAAwkIAQBBAAsCAAEKGwQEAEEBCwQAQQILBwBBABEAAAsHAEEBEQAACwAcBG5hbWUBCwIAA29u'
    'ZQEDdHdvBAgBAAV1bmFyeQ==';

Uint8List _bytes(String base64) => base64Decode(base64);

void main() {
  tearDownAll(WebAssembly.disposeDefaultRealm);

  group('WebAssembly', () {
    test('validate', () {
      expect(WebAssembly.validate(_bytes(_arithmetic)), isTrue);
      expect(WebAssembly.validate(Uint8List.fromList([0, 1, 2, 3])), isFalse);
    });

    test('compile and instantiate', () async {
      final module = await WebAssembly.compile(_bytes(_arithmetic));

      expect(module.exports.map((e) => e.name), contains('add'));
      expect(
        module.exports.firstWhere((e) => e.name == 'add').kind,
        'function',
      );

      final instance = await WebAssembly.instantiate(module);
      expect((instance.exports['add']! as Function)(20, 22), 42);
      expect((instance.exports['answer']! as Function)(), 42);
      expect((instance['answer']! as Function)(), 42);
      expect((instance.exports['swap']! as Function)(1, 2), [2, 1]);
    });

    test('instantiateBytes hands back the module as well', () async {
      final result = await WebAssembly.instantiateBytes(_bytes(_arithmetic));
      expect((result.instance.exports['answer']! as Function)(), 42);
      expect(result.module.exports, isNotEmpty);
    });

    test('a malformed module raises CompileError', () async {
      await expectLater(
        WebAssembly.compile(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<CompileError>()),
      );
    });

    test('a missing import raises LinkError', () async {
      final module = await WebAssembly.compile(_bytes(_imports));
      await expectLater(
        WebAssembly.instantiate(module),
        throwsA(isA<LinkError>()),
      );
    });

    test('a trap raises RuntimeError', () async {
      final instance = await WebAssembly.instantiate(
        await WebAssembly.compile(_bytes(_arithmetic)),
      );
      expect(
        () => (instance.exports['boom']! as Function)(),
        throwsA(isA<RuntimeError>()),
      );
    });

    test('lists imports and exports of a module', () async {
      final module = await WebAssembly.compile(_bytes(_imports));
      expect(module.imports.map((i) => '${i.module}.${i.name}'), [
        'env.log',
        'env.sum',
        'env.mem',
      ]);
      expect(module.imports.last.kind, 'memory');
      expect(module.exports.map((e) => e.name), [
        'call_log',
        'call_sum',
        'read_imported_memory',
        'boom',
      ]);
    });
  });

  group('importObject', () {
    test('host functions are called and can return values', () async {
      final calls = <int>[];
      final module = await WebAssembly.compile(_bytes(_imports));
      final instance = await WebAssembly.instantiate(module, {
        'env': {
          'log': (int value) => calls.add(value),
          'sum': (int a, int b) => a + b,
          'mem': WebAssembly.memory(const MemoryDescriptor(initial: 1)),
        },
      });

      expect((instance.exports['call_sum']! as Function)(40, 2), 42);
      (instance.exports['call_log']! as Function)(7);
      expect(calls, [7]);
    });

    test('a memory of this platform can be imported', () async {
      final module = await WebAssembly.compile(_bytes(_imports));
      final memory = WebAssembly.memory(const MemoryDescriptor(initial: 1));
      memory.buffer[0] = 99;

      final instance = await WebAssembly.instantiate(module, {
        'env': {
          'log': (int value) {},
          'sum': (int a, int b) => 0,
          'mem': memory,
        },
      });

      expect((instance.exports['read_imported_memory']! as Function)(0), 99);
    });

    test('a throwing host function surfaces that exception', () async {
      final module = await WebAssembly.compile(_bytes(_imports));
      final instance = await WebAssembly.instantiate(module, {
        'env': {
          'log': (int value) => throw StateError('host said no'),
          'sum': (int a, int b) => 0,
          'mem': WebAssembly.memory(const MemoryDescriptor(initial: 1)),
        },
      });

      expect(
        () => (instance.exports['call_log']! as Function)(1),
        _isWeb
            ? throwsA(anything)
            : throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'message',
                  'host said no',
                ),
              ),
      );
    });
  });

  group('objects', () {
    test('Memory mirrors memory.buffer and memory.grow', () {
      final memory = WebAssembly.memory(const MemoryDescriptor(initial: 1));
      expect(memory.lengthInPages, 1);
      expect(memory.buffer.length, 65536);

      memory.buffer[0] = 7;
      expect(memory.buffer[0], 7);

      expect(memory.grow(1), 1);
      expect(memory.lengthInPages, 2);
      expect(memory.buffer.length, 131072);
    });

    test('Global mirrors global.value', () {
      final mutable = WebAssembly.global(
        const GlobalDescriptor(value: 'i32', mutable: true),
        5,
      );
      expect(mutable.value, 5);
      mutable.value = 6;
      expect(mutable.valueOf(), 6);
      mutable.value = -1;
      expect(mutable.value, -1);

      final fixed = WebAssembly.global(
        const GlobalDescriptor(value: 'f64'),
        1.5,
      );
      expect(fixed.value, 1.5);
      expect(() => fixed.value = 2.0, throwsA(isA<TypeError>()));
    });

    test('an instance global is writable through the export', () async {
      final instance = await WebAssembly.instantiate(
        await WebAssembly.compile(_bytes(_globals)),
      );
      final counter = instance.exports['counter']! as Global;
      expect(counter.value, 0);
      counter.value = 41;
      expect((instance.exports['bump']! as Function)(), 42);
      expect(counter.value, 42);
    });

    test('Table holds callable functions', () async {
      final instance = await WebAssembly.instantiate(
        await WebAssembly.compile(_bytes(_table)),
      );
      final table = instance.exports['tbl']! as Table;

      expect(table.length, 2);
      expect((table.get(0)! as Function)(), 1);
      expect((table.get(1)! as Function)(), 2);

      // Put the second function into the first slot and call it through wasm.
      table.set(0, table.get(1));
      expect((instance.exports['call_zero']! as Function)(), 2);

      expect(table.grow(1, null), 2);
      expect(table.length, 3);
    });

    test('an exported memory is shared with Dart', () async {
      final instance = await WebAssembly.instantiate(
        await WebAssembly.compile(_bytes(_memory)),
      );
      final memory = instance.exports['mem']! as Memory;

      expect(String.fromCharCodes(memory.buffer.sublist(8, 13)), 'hello');
      (instance.exports['store']! as Function)(0, 1234);
      expect(
        memory.buffer.buffer.asByteData().getUint32(0, Endian.little),
        1234,
      );
      expect((instance.exports['load']! as Function)(0), 1234);
    });

    test('i64 values follow the platform convention', () async {
      final instance = await WebAssembly.instantiate(
        await WebAssembly.compile(_bytes(_arithmetic)),
      );
      final twice = instance.exports['twice']! as Function;
      if (_isWeb) {
        // JavaScript has no 64 bit integers; the web API uses BigInt.
        expect(twice(BigInt.from(21)), BigInt.from(42));
      } else {
        expect(twice(21), 42);
      }
    });
  });
}
