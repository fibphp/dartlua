import 'dart:collection';
import 'dart:math';

import 'dart:typed_data';
import 'package:lua/src/5_2/context.dart';
import 'package:lua/src/5_2/table.dart';
import 'package:lua/src/func.dart';
import 'package:lua/src/util.dart';
import 'package:meta/meta.dart';
import 'package:lua/src/5_2/state.dart';

class ThreadResult {
  ThreadResult(this.success, this.values, {this.resumeTo});
  final bool success;
  final List<dynamic> values;
  final Frame resumeTo;
  
  String toString() {
    return success ? values.map(Context.luaToString).join(", ") : values[0];
  }
}

class Upval extends LinkedListEntry<Upval> {
  Upval(this.reg, this.registers) : open = true;
  Upval.store(this.storage) : open = false;
  
  bool open;
  int reg;
  List<dynamic> registers;
  dynamic storage;
  
  void close() {
    open = false;
    storage = registers[reg];
    registers = null;
    unlink();
  }
  
  void set(dynamic v) {
    if (open) {
      registers[reg] = v;
    } else {
      storage = v;
    }
  }
  
  dynamic get() => open ? registers[reg] : storage;
}

class Closure {
  Closure(this.proto, {
    this.parent,
    this.context,
    this.upvalues,
  });

  final Prototype proto;
  final Frame parent;
  final Context context;
  final List<Upval> upvalues;
  
  List<dynamic> call(List<dynamic> args) {
    var f = new Thread(closure: this).frame;
    f.loadArgs(args);
    var x = f.cont();
    if (x.resumeTo != null) throw "cannot yield across dart call boundary";
    if (!x.success) {
      var v = maybeAt(x.values, 0);
      if (v is LuaErrorImpl) throw v;
      throw new LuaErrorImpl(maybeAt(x.values, 0), proto, f._pc);
    }
    return x.values;
  }
}

class Frame {
  Frame(this._proto, {
    this.parent,
    Context context,
    List<Upval> upvalues,
    @required Thread thread,
  }) :
    context = context ?? parent.context,
    _upvalues = upvalues ?? new List.filled(_proto.upvals.length, null),
    _K = _proto.constants,
    _R = new List.filled(_proto.registers, null, growable: true),
    _code = _proto.rawCode,
    _thread = thread {}
    
  final Thread _thread;
  final Frame parent;
  final Context context;
  final Prototype _proto;
  final List<Upval> _upvalues;
  final List<Const> _K;
  final List<dynamic> _R;
  List<dynamic> _varargs;
  final Int32List _code;
  final _openUVs = new LinkedList<Upval>();
  
  int _pc = 0;
  int _top = 0;
  
  int _getExtraArg() => _code[_pc++ * 4 + 1];
  int _getNextJump() => _code[_pc * 4 + 2];

  dynamic _RK(int x) => x >= 256 ? _K[x - 256].value : _GR(x);
  // for debugging:
  dynamic _GR(int x) => _R[x];
  dynamic _SR(int x, dynamic y) => _R[x] = y;

  void _loadReturns(List<dynamic> ret) {
    var pc = _pc - 1;
    var A = _code[pc * 4 + 1];
    var B = _code[pc * 4 + 2];
    var C = _code[pc * 4 + 3];
  
    if (C == 2) {
      _SR(A, maybeAt(ret, 0));
    } else if (C != 1) {
      if (C == 0) _setTop(A + ret.length - 1);
      if (B == 1) {
        if (C == 0) {
          for (int i = A; i < A + ret.length; i++) _SR(i, maybeAt(ret, i - A));
        } else {
          int g = 0;
          for (int i = A; i < A + C; i++) _SR(i, maybeAt(ret, g++));
        }
      } else {
        if (C == 0) {
          for (var i = 0; i < ret.length; i++) _SR(A + i, maybeAt(ret, i));
        } else {
          var g = 0;
          for (int i = A; i < A + C - 1; i++) _SR(i, maybeAt(ret, g++));
        }
      }
    }
  }

  bool convertToString(int reg) {
    var x = _GR(reg);
    if (x is num) _SR(reg, Context.numToString(x)); else if (x is! String) return false;
    return true;
  }

  List<dynamic> _callTM() {
  
  }

  List<dynamic> _concat(int total) {
    do {
      var top = _top;
      var n = 2;
    
      var a = _GR(top - 2);
      if ((a is! String && a is! num) || !convertToString(top - 1)) {
        var b = _GR(top - 1);
      
      }
    } while (total > 1);
  }

  dynamic _getUpval(int idx) => _upvalues[idx].get();
  dynamic _setUpval(int idx, dynamic value) => _upvalues[idx].set(value);

  void _closeUpvals(int from) {
    if (_openUVs.isEmpty) return;
  
    var e = _openUVs.first;
    while (e != null && e.reg >= from) {
      var next = e.next;
      e.close();
      e = next;
    }
  }

  Upval _openUpval(int reg) {
    if (_openUVs.isEmpty) {
      var uv = new Upval(reg, _R);
      _openUVs.addFirst(uv);
      return uv;
    }
  
    var e = _openUVs.first;
    while (e.reg >= reg) {
      if (e.reg == reg) return e;
      if (e.next == null) {
        var uv = new Upval(reg, _R);
        e.insertAfter(uv);
        return uv;
      }
      e = e.next;
    }
  
    var uv = new Upval(reg, _R);
    e.insertBefore(uv);
    return uv;
  }

  void _setTop(int x) {
    if (x >= _R.length) { // expand registers when 1full
      _R.length = x + 1;
    }
    _top = x;
  }
  
  void loadArgs(List<dynamic> args) {
    for (int i = 0; i < min(args.length, _proto.params); i++) {
      _SR(i, maybeAt(args, i));
    }
    
    if (_proto.varag > 0) _varargs = args;
  }
  
  bool get finished => _pc >= _proto.code.length;
  
  ThreadResult cont() {
    try {
      while (true) {
        var pc = _pc++;
        var OP = _code[pc * 4];
        var A = _code[pc * 4 + 1];
        var B = _code[pc * 4 + 2];
        var C = _code[pc * 4 + 3];
      
        if (OP == 0) { // MOVE(AB)
          _SR(A, _GR(B));
        } else if (OP == 1) { // LOADK(ABx)
          _SR(A, _K[B].value);
        } else if (OP == 2) { // LOADKX(A)
          _SR(A, _K[_getExtraArg()].value);
        } else if (OP == 3) { // LOADBOOL(ABC)
          _SR(A, B != 0);
          if (C != 0) _pc++;
        } else if (OP == 4) { // LOADNIL(AB)
          var a = A;
          _R.fillRange(a, a + B + 1);
        } else if (OP == 5) { // GETUPVAL(AB)
          _SR(A, _getUpval(B));
        } else if (OP == 6) { // GETTABUP(ABC)
          var v = context.tableIndex(_getUpval(B), _RK(C));
          _SR(A, v);
        } else if (OP == 7) { // GETTABLE(ABC)
          _SR(A, context.tableIndex(_RK(B), _RK(C)));
        } else if (OP == 8) { // SETTABUP(ABC)
          Context.tableSet(_getUpval(A), _RK(B), _RK(C));
        } else if (OP == 9) { // SETUPVAL(A)
          _setUpval(B, _GR(A));
        } else if (OP == 10) { // SETTABLE(ABC)
          Context.tableSet(_GR(A), _RK(B), _RK(C));
        } else if (OP == 11) { // NEWTABLE(ABC)
          _SR(A, new Table());
        } else if (OP == 12) { // SELF(ABC)
          _SR(A + 1, _GR(B));
          _SR(A, context.tableIndex(_GR(B), _RK(C)));
        } else if (OP == 13) { // ADD(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__add", Context.add));
        } else if (OP == 14) { // SUB(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__sub", Context.sub));
        } else if (OP == 15) { // MUL(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__mul", Context.mul));
        } else if (OP == 16) { // DIV(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__div", Context.div));
        } else if (OP == 17) { // MOD(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__mod", Context.mod));
        } else if (OP == 18) { // POW(ABC)
          _SR(A, Context.attemptArithmetic(_RK(B), _RK(C), "__pow", pow));
        } else if (OP == 19) { // UNM(AB)
          _SR(A, Context.attemptUnary(_GR(A), "__unm", Context.unm));
        } else if (OP == 20) { // NOT(AB)
          _SR(A, !Context.truthy(_GR(B)));
        } else if (OP == 21) { // LEN(AB)
          _SR(A, Context.getLength(_GR(B)));
        } else if (OP == 22) { // CONCAT
          var o = _GR(B);
          for (int i = B + 1; i <= C; i++) {
            o = Context.luaConcat(o, _GR(i));
          }
          _SR(A, o);
        } else if (OP == 23) { // JMP(AsBx)
          _pc += B;
          if (A > 0) _closeUpvals(A - 1);
        } else if (OP == 24) { // EQ
          if (Context.checkEQ(_RK(B), _RK(C)) == (A != 0)) {
            _pc += _getNextJump() + 1;
          } else {
            _pc++;
          }
        } else if (OP == 25) { // LT
          if (Context.checkLT(_RK(B), _RK(C)) == (A != 0)) {
            _pc += _getNextJump() + 1;
          } else {
            _pc++;
          }
        } else if (OP == 26) { // LE
          if (Context.checkLE(_RK(B), _RK(C)) == (A != 0)) {
            _pc += _getNextJump() + 1;
          } else {
            _pc++;
          }
        } else if (OP == 27) { // TEST
          if (!Context.truthy(_GR(A)) == (C != 0)) {
            _pc++;
          } else {
            _pc += _getNextJump() + 1;
          }
        } else if (OP == 28) { // TESTSET
          if (!Context.truthy(_GR(B)) == (C != 0)) {
            _pc++;
          } else {
            _SR(A, _GR(B));
            _pc += _getNextJump() + 1;
          }
        } else if (OP == 29) { // CALL
          if (B != 0) _setTop(A + B);
          var x = _GR(A);
          var args = new List(B == 0 ? _top - A : B - 1);
          if (B != 1) for (int i = 0; i < args.length; i++) args[i] = _GR(i + A + 1);
        
          if (x is Closure) {
            var f = _thread.newFrame(x);
            f.loadArgs(args);
            var res = f.cont();
            if (res.resumeTo != null) return res;
            _loadReturns(res.values);
          } else {
            var ret = _thread.attemptCall(x, args);
            _loadReturns(ret);
          }
        } else if (OP == 30) { // TAILCALL(ABC)
          var args = new List(B == 0 ? _top - A : B - 1);
          if (B != 1) for (int i = 0; i < args.length; i++) args[i] = _GR(i + A + 1);
          var x = _GR(A);
          _closeUpvals(0);
        
          if (x is Closure) {
            var f = _thread.newFrame(x);
            f.loadArgs(args);
            return f.cont();
          } else {
            var ret = _thread.attemptCall(_GR(A), args);
            return new ThreadResult(true, ret);
          }
        } else if (OP == 31) { // RETURN(ABC)
          _closeUpvals(0);
          var ret = new List(B == 0 ? 1 + _top - A : B - 1);
          for (int i = A; i < (B == 0 ? _top : A + B - 1); i++) ret[i - A] = _GR(i);
          return new ThreadResult(true, ret);
        } else if (OP == 32) { // FORLOOP(AsBx)
          var step = _GR(A + 2);
          var idx = _SR(A, _GR(A) + step);
          var limit = _GR(A + 1);
        
          if ((step > 0 && idx <= limit) || (step < 0 && limit <= idx)) {
            _pc += B;
            _SR(A + 3, _GR(A));
          }
        } else if (OP == 33) { // FORPREP(AsBx)
          var init = _GR(A);
          var limit = _GR(A + 1);
          var step = _GR(A + 2);
        
          if (init is! num) throw "'for' initial value must be a number";
          if (limit is! num) throw "'for' limit value must be a number";
          if (step is! num) throw "'for' step value must be a number";
        
          _SR(A, _GR(A) - step);
          _pc += B;
        } else if (OP == 34) { // TFORCALL(ABC)
          var ret = _thread.attemptCall(_GR(A), [_GR(A + 1), _GR(A + 2)]);
          var i = 0;
          for (int n = A + 3; n < A + C + 3; n++) _SR(n, maybeAt(ret, i++));
        
          var b = _code[_pc * 4 + 2];
          var a = _getExtraArg();
        
          if (_GR(a + 1) != null) {
            _SR(a, _GR(a + 1));
            _pc += b;
          }
        } else if (OP == 35) { // TFORLOOP(AsBx)
          if (_GR(A + 1) != null) {
            _SR(A, _GR(A + 1));
            _pc += B;
          }
        } else if (OP == 36) { // SETLIST(ABC)
          if (B > 0) {
            for (int i = 1; i <= B; i++) Context.tableSet(_GR(A), ((C - 1) * 50) + i, _GR(A + i));
          } else {
            for (int i = 1; i <= _top - A; i++) Context.tableSet(_GR(A), ((C - 1) * 50) + i, _GR(A + i));
          }
        } else if (OP == 37) { // CLOSURE(ABC)
          var proto = _proto.prototypes[B];
        
          _SR(A, new Closure(
            proto,
            context: context,
            parent: this,
            upvalues: new List.generate(proto.upvals.length, (i) {
              var def = proto.upvals[i];
              return def.stack ? _openUpval(def.reg) : _upvalues[def.reg];
            }),
          ));
        } else if (OP == 38) { // VARARG
          if (B > 0) {
            var i = 0;
            for (int n = A; n <= A + B - 2; n++) _SR(n, _varargs[i++]);
          } else {
            _setTop(A + _varargs.length - (_proto.params + 1));
            var i = A;
            for (int n = _proto.params; n < _varargs.length; n++) _SR(i++, _varargs[n]);
          }
        } else {
          throw "invalid instruction";
        }
      }
    } catch(e, bt) {
      if (e is LuaError) rethrow;
      throw new LuaErrorImpl(e, _proto, _pc - 1, dartStackTrace: bt);
    }
  }
}

class Thread {
  Thread({@required Closure closure}) {
    frame = newFrame(closure);
  }
  
  Frame newFrame(Closure closure) => new Frame(closure.proto, context: closure.context, upvalues: closure.upvalues, thread: this);
  
  Frame frame;
  Frame _resumeTo;
  
  CoroutineStatus status = CoroutineStatus.SUSPENDED;
  bool started = false;

  List<dynamic> attemptCall(dynamic x, [List<dynamic> args = const []]) {
    if (x is Table) {
      return Context.invokeMetamethod(x, "__call", args);
    } else if (x is LuaDartFunc) {
      return x(args);
    } else if (x is LuaDartDebugFunc) {
      return x(this, args);
    } else if (x is Closure) {
      return x(args);
    } else {
      throw "attempt to call a ${Context.getTypename(x)} value";
    }
  }

  CoroutineResult resume([List<dynamic> params = const []]) {
    assert(status != CoroutineStatus.DEAD, "Coroutine dead, check status before calling resume");
    
    if (!started) {
      started = true;
      _resumeTo = frame;
    }

    status = CoroutineStatus.RUNNING;
    
    try {
      _resumeTo.loadArgs(params);
      var res = _resumeTo.cont();
      _resumeTo = res.resumeTo;
      status = _resumeTo != null ? CoroutineStatus.DEAD : CoroutineStatus.SUSPENDED;
      return new CoroutineResult(true, res.values);
    } catch(e) {
      status = CoroutineStatus.DEAD;
      return new CoroutineResult(false, [e]);
    }
    
    /*if (!started) {
      _updateFrame();
      // load main body arguments
      
      started = true;
    } else if (status == CoroutineStatus.SUSPENDED) { // resume from yield
      status = CoroutineStatus.RUNNING;
      var pc = _pc - 1;
      var OP = _code[pc * 4];
      var A = _code[pc * 4 + 1];
      var B = _code[pc * 4 + 2];
      var C = _code[pc * 4 + 3];
      
      // ADD SUB MUL DIV MOD POW UNM LEN GETTABUP GETTABLE SELF
      if ((OP >= 13 && OP <= 19) || OP == 21 || OP == 6 || OP == 7 || OP == 12) {
        _SR(A, params[0]);
      } else if (OP == 22) { // CONCAT
      
      }
    }*/

    
  }

  toString() => "thread: 0x${(hashCode % 0x100000000).toRadixString(16).padLeft(8, "0")}";
}