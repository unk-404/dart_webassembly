// The same Dart code, WebAssembly on every platform.
//
// `package:webassembly/webassembly.dart` picks the implementation for you:
// the browser's own WebAssembly on the web, wasmtime everywhere else.  Nothing
// in this file knows which one it is running on, which is exactly the point.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webassembly/webassembly.dart';

void main() {
  runApp(const MyApp());
}

/// True when this build targets the web.
const bool _isWeb = identical(0, 0.0);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'loading assets/demo.wasm…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final data = await rootBundle.load('assets/demo.wasm');
      final bytes = Uint8List.view(
        data.buffer,
        data.offsetInBytes,
        data.lengthInBytes,
      );

      // The greeting the wasm module asks us to print through `env.log`.
      final greetings = <int>[];

      final module = await WebAssembly.compile(bytes);
      final instance = await WebAssembly.instantiate(module, {
        'env': {
          'log': (int value) {
            greetings.add(value);
            return null;
          },
        },
      });

      final add = instance.exports['add']! as Function;
      (instance.exports['greet']! as Function)(21);

      if (!mounted) return;
      setState(() {
        _status =
            'add(20, 22) = ${add(20, 22)}\n'
            'greet(21) called the host function with $greetings\n'
            'exports: ${instance.exports.keys.join(', ')}\n'
            'module imports: '
            '${module.imports.map((i) => '${i.module}.${i.name}').join(', ')}';
      });
    } on WasmException catch (error) {
      if (mounted) setState(() => _status = 'WebAssembly failed: $error');
    } catch (error) {
      if (mounted) setState(() => _status = 'failed to load: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('webassembly')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _isWeb ? 'running on the browser' : 'running on wasmtime',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
