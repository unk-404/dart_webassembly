// The unified API on the web, backed by the browser's own WebAssembly.
//
// Selected automatically by `webassembly.dart` through a conditional import;
// never imported directly.  Every function here has a counterpart in
// `backend_io.dart` with the same signature.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'types.dart';

JSObject get _webAssembly => globalContext['WebAssembly']! as JSObject;

JSFunction _staticFunction(String name) => _webAssembly[name]! as JSFunction;

JSFunction _constructor(String name) => _webAssembly[name]! as JSFunction;

/// `WebAssembly.validate(bytes)`.
bool validate(Uint8List bytes) => _guard(
  () => _staticFunction('validate')
      .callAsFunction(null, bytes.toJS)
      .dartify()! as bool,
);

/// `WebAssembly.compile(bytes)`.
Future<Object> compile(Uint8List bytes) async => _guardAsync(() async {
  final promise = _staticFunction('compile').callAsFunction(null, bytes.toJS);
  return (await (promise! as JSPromise).toDart)!;
});

/// `WebAssembly.instantiate(module, importObject)`.
Future<Object> instantiate(
  Object module,
  Map<String, Map<String, Object?>> imports,
) async {
  final promise = _staticFunction('instantiate').callAsFunction(
    null,
    module as JSObject,
    _importObject(imports),
  );
  // Linking failures are reported as `LinkError`, as a `TypeError` (an import
  // object that does not fit) or, from `new WebAssembly.Instance`, as a plain
  // error; all of them mean the same thing to a caller.
  return _guardAsync(
    () async => (await (promise! as JSPromise).toDart)!,
    link: true,
  );
}

/// `WebAssembly.instantiate(bytes, importObject)`, which resolves to both.
Future<(Object, Object)> instantiateBytes(
  Uint8List bytes,
  Map<String, Map<String, Object?>> imports,
) async {
  final promise = _staticFunction('instantiate').callAsFunction(
    null,
    bytes.toJS,
    _importObject(imports),
  );
  return _guardAsync(() async {
    final result = (await (promise! as JSPromise).toDart)! as JSObject;
    return (result['module']!, result['instance']!);
  }, link: true);
}

/// `WebAssembly.Module.imports(module)`.
List<BackendDescriptor> moduleImports(Object module) => _guard(() {
  final array =
      (_constructor('Module')['imports']! as JSFunction).callAsFunction(
        null,
        module as JSObject,
      ) as JSArray<JSObject>;
  return [
    for (final item in array.toDart)
      BackendDescriptor(
        module: (item['module']! as JSString).toDart,
        name: (item['name']! as JSString).toDart,
        kind: (item['kind']! as JSString).toDart,
      ),
  ];
});

/// `WebAssembly.Module.exports(module)`.
List<BackendDescriptor> moduleExports(Object module) => _guard(() {
  final array =
      (_constructor('Module')['exports']! as JSFunction).callAsFunction(
        null,
        module as JSObject,
      ) as JSArray<JSObject>;
  return [
    for (final item in array.toDart)
      BackendDescriptor(
        name: (item['name']! as JSString).toDart,
        kind: (item['kind']! as JSString).toDart,
      ),
  ];
});

/// Every value `instance.exports` holds.
List<BackendExport> instanceExports(Object instance) => _guard(() {
  final exports = _exportsOf(instance);
  final keys =
      ((globalContext['Object']! as JSObject)['keys']! as JSFunction)
          .callAsFunction(null, exports) as JSArray<JSString>;
  return [
    for (final key in keys.toDart) _describe(key.toDart, exports),
  ];
});

/// One value of `instance.exports`, or null.
BackendExport? instanceExport(Object instance, String name) => _guard(() {
  final exports = _exportsOf(instance);
  if (exports.getProperty(name.toJS) == null) return null;
  return _describe(name, exports);
});

/// `new WebAssembly.Memory({initial, maximum, shared})`.
Object createMemory(MemoryDescriptor descriptor) => _guard(() {
  final jsDescriptor = JSObject();
  jsDescriptor.setProperty('initial'.toJS, descriptor.initial.toJS);
  final maximum = descriptor.maximum;
  if (maximum != null) {
    jsDescriptor.setProperty('maximum'.toJS, maximum.toJS);
  }
  if (descriptor.shared) {
    jsDescriptor.setProperty('shared'.toJS, true.toJS);
  }
  return _constructor('Memory').callAsConstructor<JSObject>(jsDescriptor);
});

int memoryLengthBytes(Object memory) => _guard(
  () => ((_property(memory, 'buffer') as JSObject)['byteLength']! as JSNumber)
      .toDartDouble
      .toInt(),
);

/// The page size of a browser memory is fixed at 64 KiB.
int memoryLengthPages(Object memory) => memoryLengthBytes(memory) ~/ 65536;

Uint8List memoryBuffer(Object memory) => _guard(
  () => (_property(memory, 'buffer') as JSArrayBuffer).toDart.asUint8List(),
);

int memoryGrow(Object memory, int deltaPages) => _guard(
  () => _invokeMethod(memory, 'grow', [deltaPages.toJS]).dartify()! as int,
);

/// `new WebAssembly.Global({value, mutable}, initialValue)`.
Object createGlobal(GlobalDescriptor descriptor, Object? initialValue) =>
    _guard(() {
      final jsDescriptor = JSObject();
      jsDescriptor.setProperty('value'.toJS, descriptor.value.toJS);
      jsDescriptor.setProperty('mutable'.toJS, descriptor.mutable.toJS);
      return _constructor('Global').callAsConstructor<JSObject>(
        jsDescriptor,
        _toJs(initialValue ?? descriptor.initialValue),
      );
    });

Object? globalValue(Object global) => _toDartValue(_property(global, 'value'));

void setGlobalValue(Object global, Object? value) {
  try {
    (global as JSObject).setProperty('value'.toJS, _toJs(value));
  } catch (_) {
    // The browser throws a TypeError for an immutable global or a type
    // mismatch; Dart's own TypeError is the equivalent.
    throw TypeError();
  }
}

/// `new WebAssembly.Table({element, initial, maximum}, initialValue)`.
Object createTable(TableDescriptor descriptor, Object? initialValue) =>
    _guard(() {
      final jsDescriptor = JSObject();
      jsDescriptor.setProperty('element'.toJS, descriptor.element.toJS);
      jsDescriptor.setProperty('initial'.toJS, descriptor.initial.toJS);
      final maximum = descriptor.maximum;
      if (maximum != null) {
        jsDescriptor.setProperty('maximum'.toJS, maximum.toJS);
      }
      return _constructor('Table').callAsConstructor<JSObject>(
        jsDescriptor,
        _toJs(initialValue),
      );
    });

int tableLength(Object table) => _guard(
  () => (_property(table, 'length')! as JSNumber).toDartDouble.toInt(),
);

Object? tableGet(Object table, int index) => _guard(
  () => _toDartValue(_invokeMethod(table, 'get', [index.toJS])),
);

void tableSet(Object table, int index, Object? value) => _guard(
  () => _invokeMethod(table, 'set', [index.toJS, _toJs(value)]),
);

int tableGrow(Object table, int delta, Object? initialValue) => _guard(
  () => _invokeMethod(table, 'grow', [
    delta.toJS,
    _toJs(initialValue),
  ]).dartify()! as int,
);

/// The browser owns one realm for the whole page; there is nothing to release.
void disposeDefaultRealm() {}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

JSObject _exportsOf(Object instance) =>
    (instance as JSObject)['exports']! as JSObject;

JSAny? _property(Object object, String name) => (object as JSObject)[name];

/// Calls `object.name(args...)`, passing [object] as `this`.
JSAny? _invokeMethod(Object object, String name, List<JSAny?> arguments) {
  final target = object as JSObject;
  final function = target[name]! as JSFunction;
  return switch (arguments.length) {
    0 => function.callAsFunction(target),
    1 => function.callAsFunction(target, arguments[0]),
    2 => function.callAsFunction(target, arguments[0], arguments[1]),
    3 => function.callAsFunction(
      target,
      arguments[0],
      arguments[1],
      arguments[2],
    ),
    _ => function.callAsFunction(
      target,
      arguments[0],
      arguments[1],
      arguments[2],
      arguments[3],
    ),
  };
}

String? _stringProperty(JSObject object, String name) {
  final value = object[name];
  return value.isA<JSString>() ? (value as JSString).toDart : null;
}

BackendExport _describe(String name, JSObject exports) {
  final value = exports[name];
  if (value == null) return BackendExport(name, 'unknown');
  if (value.instanceOfString('WebAssembly.Memory')) {
    return BackendExport(name, 'memory', handle: value);
  }
  if (value.instanceOfString('WebAssembly.Table')) {
    return BackendExport(name, 'table', handle: value);
  }
  if (value.instanceOfString('WebAssembly.Global')) {
    return BackendExport(name, 'global', handle: value);
  }
  if (value.isA<JSFunction>()) {
    return BackendExport(
      name,
      'function',
      function: _dartFunction(value as JSFunction),
    );
  }
  return BackendExport(name, 'unknown', handle: value);
}

/// Marks an argument that was not supplied.
const Object _absent = Object();

/// The JavaScript function behind each Dart bridge, and the other way round.
final Expando<JSFunction> _bridged = Expando<JSFunction>();

/// A Dart [Function] that calls [function].
///
/// The browser does not say how many parameters a WebAssembly function takes,
/// so the bridge accepts optional arguments (Dart has no variadic functions)
/// and forwards only the ones that were actually supplied.  That makes all of
/// `f()`, `f(1)` and `f(1, 2)` work, like in JavaScript.
Function _dartFunction(JSFunction function) {
  Object? bridge([
    Object? a0 = _absent,
    Object? a1 = _absent,
    Object? a2 = _absent,
    Object? a3 = _absent,
    Object? a4 = _absent,
    Object? a5 = _absent,
    Object? a6 = _absent,
    Object? a7 = _absent,
  ]) {
    final all = <Object?>[a0, a1, a2, a3, a4, a5, a6, a7];
    var count = all.length;
    while (count > 0 && identical(all[count - 1], _absent)) {
      count--;
    }
    try {
      return _toDartValue(_invokeFunction(function, all.sublist(0, count)));
    } catch (error) {
      // A trap raised by WebAssembly arrives here as a JS error object.
      _mapError(error);
    }
  }

  _bridged[bridge] = function;
  return bridge;
}

JSAny? _invokeFunction(JSFunction function, List<Object?> arguments) {
  // `Function.prototype.apply` is used rather than `callAsFunction` so that a
  // WebAssembly function with any number of parameters can be called.
  final jsArguments =
      <JSAny?>[
        for (final argument in arguments) _toJs(argument),
      ].jsify()!
      as JSArray<JSAny?>;
  final apply = (function as JSObject)['apply']! as JSFunction;
  return apply.callAsFunction(function, null, jsArguments);
}

/// Turns a Dart function into a JavaScript function.
///
/// `Function.toJS` needs a statically known signature, and a value taken out of
/// an import object is only a `Function`, so it is wrapped in a bridge that
/// declares eight optional parameters - which *is* a precise type.  JavaScript
/// is free to pass fewer (the remaining ones are null) or more (they are
/// ignored), and the trailing nulls are dropped again before the Dart function
/// is called.
JSFunction _dartFunctionToJs(Function function) {
  JSAny? bridge([
    JSAny? a0,
    JSAny? a1,
    JSAny? a2,
    JSAny? a3,
    JSAny? a4,
    JSAny? a5,
    JSAny? a6,
    JSAny? a7,
  ]) {
    final all = <Object?>[
      _toDartValue(a0),
      _toDartValue(a1),
      _toDartValue(a2),
      _toDartValue(a3),
      _toDartValue(a4),
      _toDartValue(a5),
      _toDartValue(a6),
      _toDartValue(a7),
    ];
    var count = all.length;
    while (count > 0 && all[count - 1] == null) {
      count--;
    }
    return _toJs(Function.apply(function, all.sublist(0, count)));
  }

  return bridge.toJS;
}

/// Turns a Dart value into what the browser's `WebAssembly` expects.
JSAny? _toJs(Object? value) {
  if (value == null) return null;
  if (value is Function) {
    return _bridged[value] ?? _dartFunctionToJs(value);
  }
  // JavaScript has no 64 bit integers, so the web API represents `i64` as a
  // BigInt; `jsify` does not know how to convert Dart's `BigInt`.
  if (value is BigInt) return _bigIntToJs(value);
  return value.jsify();
}

/// Turns a value coming out of the browser into the Dart equivalent.
Object? _toDartValue(JSAny? value) {
  if (value == null) return null;
  if (value.isA<JSFunction>()) return _dartFunction(value as JSFunction);
  if (value.isA<JSBigInt>()) return _bigIntToDart(value as JSBigInt);
  if (value.isA<JSString>() ||
      value.isA<JSNumber>() ||
      value.isA<JSBoolean>()) {
    return value.dartify();
  }
  // A memory, a table, a global or an externref: keep the JS value as it is.
  return value;
}

JSFunction get _bigIntConstructor => globalContext['BigInt']! as JSFunction;

JSFunction get _bigIntToString =>
    ((globalContext['BigInt']! as JSObject)['prototype']! as JSObject)['toString']!
        as JSFunction;

JSBigInt _bigIntToJs(BigInt value) =>
    _bigIntConstructor.callAsFunction(null, value.toString().toJS)! as JSBigInt;

BigInt _bigIntToDart(JSBigInt value) => BigInt.parse(
  // `BigInt.prototype.toString.call(value)`.
  (_bigIntToString.callAsFunction(value)! as JSString).toDart,
);

JSObject _importObject(Map<String, Map<String, Object?>> imports) {
  final result = JSObject();
  for (final entry in imports.entries) {
    final nested = JSObject();
    for (final inner in entry.value.entries) {
      nested.setProperty(inner.key.toJS, _toJs(inner.value));
    }
    result.setProperty(entry.key.toJS, nested);
  }
  return result;
}

T _guard<T>(T Function() body) {
  try {
    return body();
  } catch (error) {
    _mapError(error);
  }
}

/// Runs [body], translating browser failures.
///
/// [link] is for instantiation, where the browser reports a bad import object
/// as a `TypeError` and `new WebAssembly.Instance` reports it as a plain error;
/// both mean "linking failed", which is what the native backend and the
/// WebAssembly specification call a [LinkError].
Future<T> _guardAsync<T>(
  Future<T> Function() body, {
  bool link = false,
}) async {
  try {
    return await body();
  } catch (error) {
    if (link) _mapLinkError(error);
    _mapError(error);
  }
}

/// The `name` and `message` of a thrown browser error.
///
/// Whether a JS exception reaches Dart as a `JSObject` depends on how the code
/// is compiled and on whether it crossed an async boundary, so the string form
/// (`"Name: message"`) is inspected as well.
(String?, String) _errorDetails(Object error) {
  // Deliberate: depending on the web compilation mode and on whether the throw
  // crossed an async boundary, a JS exception arrives either as a JS interop
  // object or as a plain Dart object.  `isA` is not an option here because the
  // value is a Dart `Object`.
  // ignore: invalid_runtime_check_with_js_interop_types
  if (error is JSObject) {
    final message = _stringProperty(error, 'message');
    if (message != null) return (_stringProperty(error, 'name'), message);
  }
  final text = '$error';
  for (final name in const [
    'CompileError',
    'LinkError',
    'RuntimeError',
    'RangeError',
    'TypeError',
    'Error',
  ]) {
    if (text.startsWith('$name: ')) {
      return (name, text.substring(name.length + 2));
    }
  }
  return (null, text);
}

Object _errorFor(String? name, String message) => switch (name) {
  'CompileError' => CompileError(message),
  'LinkError' => LinkError(message),
  'RuntimeError' => RuntimeError(message),
  'RangeError' => RangeError(message),
  'TypeError' => TypeError(),
  _ => WasmException(message),
};

/// The browser reports failures with `WebAssembly.*Error` objects.
Never _mapError(Object error) {
  final (name, message) = _errorDetails(error);
  throw _errorFor(name, message);
}

/// [Never] mapping for instantiation, where everything except a compile error
/// or a runtime trap is a linking failure.
Never _mapLinkError(Object error) {
  final (name, message) = _errorDetails(error);
  final mapped = _errorFor(name, message);
  if (mapped is CompileError || mapped is RuntimeError) throw mapped;
  throw LinkError(message);
}
