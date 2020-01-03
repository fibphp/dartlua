import 'dart:async';
import 'dart:io';

import 'dart:typed_data';
import 'package:lua/src/5_2/table.dart';
import 'package:lua/src/5_2/vm.dart';
import 'package:lua/src/5_2/context.dart';
import 'package:lua/src/5_2/lualib/base.dart' as lualib;
import 'package:lua/src/decode.dart';

class CoroutineResult {
  CoroutineResult(this.success, this.values);
  final bool success;
  final List<dynamic> values;
  
  String toString() {
    return success ? values.map(Context.luaToString).join(", ") : values[0];
  }
}

abstract class LuaFunction {
  List<dynamic> call(List<dynamic> args);
  CoroutineResult pcall(List<dynamic> args);
  LuaState get state;
}

abstract class LuaError {
  dynamic get value;
  StackTrace get dartStackTrace;
  String get source;
  String toStringShort();
  String toString();
}

enum CoroutineStatus {
  RUNNING,
  SUSPENDED,
  NORMAL,
  DEAD,
}

class Coroutine {
  Coroutine(LuaFunction f) {}
  
  CoroutineStatus _status;
  CoroutineStatus get status => _status;
  CoroutineResult resume([List<dynamic> args = const []]) {
    return new CoroutineResult(true, []);
  }
}

class _LuaFunctionImpl extends LuaFunction {
  _LuaFunctionImpl(this.closure);
  Closure closure;
  LuaState get state => closure.context.userdata as LuaState;
  List<dynamic> call(List<dynamic> args) => closure(args);
  CoroutineResult pcall(List<dynamic> args) {
    try {
      return new CoroutineResult(true, closure(args));
    } on LuaError catch(e) {
      return new CoroutineResult(false, [e.toString()]);
    }
  }
  
  bool operator==(dynamic other) => other is _LuaFunctionImpl && other.closure == closure;
  int get hashCode => closure.hashCode;
}

class LuaState {
  Table get _G => _context.env;
  final Context _context;
  
  LuaState({bool loadLibs = true}) : _context = new Context(env: new Table()) {
    _context.userdata = this;
    
    if (loadLibs) {
      loadBase();
      loadMath();
      loadString();
      loadBit();
      loadTable();
    }
  }
  
  void loadBase() => lualib.loadBase(_context);
  void loadMath() => lualib.loadMath(_context);
  void loadString() => lualib.loadString(_context);
  void loadBit() => lualib.loadBit(_context);
  void loadTable() => lualib.loadTable(_context);
  
  Future<LuaFunction> loadFile(String path) async {
    var res = await Process.run("luadist/bin/luac5.2", [path]);
    
    if (res.stderr != "") throw res.stderr;
    
    var f = new File("luac.out");

    if (!await f.exists()) throw "luac.out not found";
    var fh = await f.open(mode: FileMode.read);
    var buffer = new Uint8List(await f.length());
    await fh.readInto(buffer);
    
    await f.delete();

    var decoder = new Decoder(buffer.buffer);
    var dump = decoder.readCodeDump(path);
    
    return new _LuaFunctionImpl(new Closure(
      dump.main,
      context: _context,
      upvalues: [new Upval.store(_context.env)],
    ));
  }
  
  Future<CoroutineResult> doFile(String path, {List<dynamic> args = const []}) async => (await loadFile(path)).pcall(args);
  
  static dynamic _sanitize(dynamic x) {
    if (x is! LuaDartFunc && x is Function) {
      throw "Function does not match LuaDartFunc or LuaDebugFunc";
    } else return x;
  }
  
  static dynamic _convert(dynamic x) {
    if (x is Closure) {
      return new _LuaFunctionImpl(x);
    } else return x;
  }
  
  dynamic getGlobal(dynamic k) => _convert(_G.rawget(_sanitize(k)));
  void setGlobal(dynamic k, dynamic v) => _G.rawset(_sanitize(k), _sanitize(v));
}