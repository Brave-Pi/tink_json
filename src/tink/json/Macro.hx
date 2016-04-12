package tink.json;

import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.ds.Option;
import tink.json.macros.Crawler;

using haxe.macro.Tools;
using tink.MacroApi;

private typedef FieldInfo = {
  name:String,
  pos:Position,
  type:Type,
  optional:Bool
}

class Macro {
  
  static var OPTIONAL:Metadata = [{ name: ':optional', params:[], pos: (macro null).pos }];
  
  static function getType(name) 
    return 
      switch Context.getLocalType() {
        case TInst(_.toString() == name => true, [v]):
          v;
        default:
          throw 'assert';
      }      
  
  static function plainAbstract(t:Type)
    return switch t.reduce() {
      case TAbstract(_.get() => a, params):
        function apply(t)
          return haxe.macro.TypeTools.applyTypeParameters(t, a.params, params);
        
        var ret = apply(a.type);
        
        function get(casts:Array<{t:Type, field:Null<ClassField>}>) {
          for (c in casts)
            if (c.field == null && typesEqual(ret, apply(c.t))) 
              return true;
          return false;
        }        
        
        if (get(a.from) && get(a.to)) Some(ret) else None;
       
      default: None;
    }

  static function typesEquivalent(t1, t2)
    return Context.unify(t1, t2) && Context.unify(t2, t1);

  static function typesEqual(t1, t2)
    return typesEquivalent(t1, t2);//TODO: make this more exact
    
  static public function buildParser():Type
    return parserForType(getType('tink.json.Parser'));
  
  static var parserCounter = 0;
  static function parserForType(t:Type):Type {
    
    var name = 'JsonParser${parserCounter++}',
        ct = t.toComplex(),
        pos = Context.currentPos();
    
    var cl = macro class $name extends tink.json.Parser.BasicParser {
      public function new() {}
    } 
    
    function add(t:TypeDefinition)
      cl.fields = cl.fields.concat(t.fields);
      
    var anons = new Map<String, Type>();
    
    function parse(t:Type, pos:Position):Expr
      return
        if (t.getID(false) == 'Null')
          macro {
            if (this.allow('null')) null;
            else ${parse(t.reduce(), pos)};
          }
        else
          switch t.reduce() {
            
            case _.getID() => 'String': 
              macro (this.parseString().toString() : String);
              
            case _.getID() => 'Float': 
              macro this.parseNumber().toFloat();
              
            case _.getID() => 'Int': 
              macro this.parseNumber().toInt();
              
            case _.getID() => 'Bool': 
              macro this.parseBool();
              
            case _.getID() => 'Date':
              macro Date.fromTime(this.parseNumber().toFloat());
              
            case _.getID() => 'haxe.io.Bytes':
              macro haxe.crypto.Base64.decode(this.parseString().toString());
              
            case TAnonymous(fields):
              
              var method = null;
              
              for (func in anons.keys()) {
                
                var known = anons[func];
                
                if (typesEqual(t, known)) {
                  method = func;
                  break;
                }
                
              }
              
              if (method == null) {
                method = 'parseAnon${Lambda.count(anons)}';
                
                anons[method] = t;
                
                var fields = fields.get().fields,
                    read = macro this.skipValue(),
                    vars:Array<Var> = [],
                    obj:Array<{ field:String, expr:Expr }> = [],
                    checks = [],
                    ct = t.toComplex();
                    
                for (f in fields) {
                  var ct = f.type.reduce().toComplex(),
                      name = f.name,
                      optional = f.meta.has(':optional');
                     
                  read = macro @:pos(f.pos) 
                    if (__name__ == $v{name}) {
                      @:privateAccess (__ret.$name = ${parse(f.type, f.pos)});//in case the field is (default, null) or something
                      ${
                        if (optional) macro $b{[]}
                        else macro $i{name} = true
                      }
                    } 
                    else $read;
                  
                  if (!optional) {
                    var valType = 
                      switch plainAbstract(f.type) {
                        case Some(a): a;
                        default: f.type;
                      }
                      
                    obj.push({
                      field: name,
                      expr: switch valType.getID() {
                        case 'Bool': macro false;
                        case 'Int': macro 0;
                        case 'Float': macro .0;
                        default: macro null;
                      },
                    });
                    vars.push({
                      type: macro : Bool,
                      name: name,
                      expr: macro false,
                    });
                    checks.push(macro if (!$i{name})  __missing__($v{f.name}));
                  }
                  
                };
                
                add(macro class {
                  function $method():$ct {
                    
                    ${EVars(vars).at()};
                    var __ret:$ct = ${EObjectDecl(obj).at(pos)};
                    
                    var __start__ = this.pos;
                    this.expect('{');
                    if (!this.allow('}')) {
                      do {
                        var __name__ = this.parseString();
                        this.expect(':');
                        $read;
                      } while (this.allow(','));
                      this.expect('}');
                    }
                      
                    function __missing__(field:String):Dynamic {
                      //return this.die('missing ' + field + ' in ' + this.source[__start__...this.pos].toString());
                      return this.die('missing ' + field);
                    }
                    
                    $b{checks};
                    return __ret;
                  }
                });
              }
              
              macro this.$method();
            case TInst(_.get() => { name: 'Array', pack: [] }, [t]):
              macro {
                this.expect('[');
                var __ret = [];
                if (!allow(']')) {
                  do {
                    __ret.push(${parse(t, pos)});
                  } while (allow(','));
                  expect(']');
                }    
                __ret;
              }
              
            case TAbstract(_.get() => { name: 'Map', pack: [] }, [k, v]):
              macro {
                this.expect('[');
                var __ret = new Map();
                if (!allow(']')) {
                  do {
                    this.expect('[');
                    __ret[${parse(k, pos)}] = this.expect(',') + ${parse(v, pos)};
                    this.expect(']');
                  } while (allow(','));
                  expect(']');
                }    
                __ret;
              }
            
            case TDynamic(t):
              var ct = t.toComplex();
              macro (${parse((macro : haxe.DynamicAccess<$ct>).toType().sure(), pos)} : Dynamic<$ct>);
              
            case TAbstract(_.get() => { name: 'DynamicAccess', pack: ['haxe'] }, [t]):
              var ct = t.toComplex();
              macro {
                this.expect('{');
                var __ret = new haxe.DynamicAccess();
                if (!allow('}')) {
                  do {
                    __ret[this.parseString().toString()] = expect(':') + ${parse(t, pos)};
                  } while (allow(','));
                  expect('}');
                }    
                __ret;
                
              }
              
            case plainAbstract(_) => Some(a):
              var ct = t.toComplex();
              macro (${parse(a, pos)} : $ct);
              
            case TEnum(_.get() => e, _):
              var ce = t.toComplex();
              
              function captured(f:HasName)
                return macro @:pos(pos) $i{
                  if (f.charAt(0).toUpperCase() == f.charAt(0)) '__'+f.toLowerCase()
                  else f
                };              
                
              function mkComplex(fields:Iterable<FieldInfo>):ComplexType
                return TAnonymous([for (f in fields) {
                  name: f.name,
                  pos: e.pos,
                  meta: if (f.optional) OPTIONAL else [],
                  kind: FVar(f.type.toComplex()),
                }]);
                
              var fields = new Map<String, FieldInfo>(),
                  cases = new Array<Case>();
              
              function mkOpt(f:FieldInfo):FieldInfo
                return
                  if (f.optional) f;
                  else {
                    name: f.name,
                    optional: true,
                    type: f.type,
                    pos: f.pos,
                  }
                  
              function add(f:FieldInfo) 
                switch fields[f.name] {
                  case null: fields[f.name] = f;
                  case same if (typesEqual(same.type, f.type)):
                    fields[f.name] = {
                      pos: f.pos,
                      name: f.name,
                      type: f.type,
                      optional: same.optional || f.optional,
                    }
                  case other: 
                    e.pos.error('conflict for field $name');
                }
                  
              for (name in e.names) {
                
                var c = e.constructs[name],
                    inlined = false;
                    
                var cfields = 
                  switch c.type.reduce() {
                    case TFun([{ name: name, t: TAnonymous(anon) }], ret) if (name.toLowerCase() == c.name.toLowerCase()):
                      inlined = true;
                      [for (f in anon.get().fields) { name: f.name, type: f.type, optional: f.meta.has(':optional'), pos: c.pos }];
                    case TFun(args, ret):
                      [for (a in args) { name: a.name, type: a.t, optional: a.opt, pos: c.pos }];
                    default:
                      c.pos.error('constructor has no arguments');
                  }
                                    
                switch c.meta.extract(':json') {
                  case []:
                    
                    add({
                      name: name,
                      optional: true,
                      type: mkComplex(cfields).toType().sure(),
                      pos: c.pos,
                    });
                    
                    cases.push({
                      values: [macro { $name : o }],
                      guard: macro o != null,
                      expr: {
                        var args = if (inlined) [macro o];
                        else [for (f in cfields) {
                          var name = f.name;
                          macro o.$name;
                        }];
                        macro ($i{name}($a{args}) : $ce);
                      }
                    });
                    
                  case [{ params:[{ expr: EObjectDecl(obj) }] }]:
                    
                    var pat = obj.copy(),
                        guard = macro true;
                      
                    for (f in cfields) {
                      add(mkOpt(f));
                      if (!f.optional)
                        guard = macro $guard && ${captured(f)} != null;
                      
                      pat.push({ field: f.name, expr: macro ${captured(f)}});
                    }
                    
                    var args = 
                      if (inlined) [EObjectDecl([for (f in cfields) { field: f.name, expr: macro ${captured(f)} }]).at(pos)];
                      else [for (f in cfields) macro ${captured(f)}];
                    
                    var call = macro ($i{name}($a{args}) : $ce);
                    
                    cases.push({
                      values: [EObjectDecl(pat).at()],
                      guard: guard,
                      expr: call
                    });
                    
                    for (f in obj)
                      add({
                        pos: f.expr.pos,
                        name: f.field, 
                        type: f.expr.typeof().sure(),
                        optional: true,
                      });
                    
                  case v:
                    c.pos.error('invalid use of @:json');
                }
              }
              
              var ret = macro @:pos(pos) {
                var __ret = ${parse(mkComplex(fields).toType().sure(), pos)};
                ${ESwitch(macro __ret, cases, macro throw new tink.core.Error('Cannot process '+Std.string(__ret))).at(pos)};
              }
              
              ret;
            case v: 
              pos.error('Cannot parse ${t.toString()}');
          }
    
    add(macro class { 
      public function parse(source):$ct {
        this.init(source);
        return ${parse(t, pos)};
      }
      public function tryParse(source)
        return tink.core.Error.catchExceptions(function () return parse(source));
    });
        
    Context.defineType(cl);
    
    return Context.getType(name);    
  }
  
  static public function buildWriter():Type
    return writerForType(getType('tink.json.Writer'));
      
  static var writerCounter = 0;
  static function writerForType(t:Type):Type {
    
    var name = 'JsonWriter${writerCounter++}',
        ct = t.toComplex(),
        pos = Context.currentPos();
    
    var cl = macro class $name extends tink.json.Writer.BasicWriter {
      public function new() {}
    } 
    
    var ret = Crawler.crawl(t, pos, {
      args: function () return ['value'],
      nullable: function (e) return macro if (value == null) this.output('null') else $e,
      string: function () return macro this.writeString(value),
      int: function () return macro this.writeInt(value),
      float: function () return macro this.writeFloat(value),
      bool: function () return macro this.writeBool(value),
      date: function () return macro this.writeFloat(value.getTime()),
      bytes: function () return macro this.writeString(haxe.crypto.Base64.encode(value)),
      map: function (k, v)               
        return macro {
          this.char('['.code);
          var first = true;
          for (k in value.keys()) {
            if (first)
              first = false;
            else
              this.char(','.code);
              
            this.char('['.code);
            {
              var value = k;
              $k;
            }
            
            this.char(','.code);
            {
              var value = value.get(k);
              $v;
            }
            
            this.char(']'.code);
          }
          this.char(']'.code);  
        },
      anon: function (fields, ct) 
        return (macro function (value:$ct) {
          var open = '{';
          $b{[for (f in fields) {
            var name = f.name;
            macro {
              this.output('${if (f == fields[0]) "$open" else ","}"$name":');
              var value = value.$name;
              ${f.expr};
            }
          }]};
          char('}'.code);
        }).getFunction().sure(),
      array: function (e) 
        return macro {
          this.char('['.code);
          var first = true;
          for (value in value) {
            if (first)
              first = false;
            else
              this.char(','.code);
            $e;
          }
          this.char(']'.code);  
        },
      enm: function (constructors, ct) {
        var cases = [];
        for (c in constructors) {
          var cfields = c.fields,
              inlined = c.inlined,
              c = c.ctor,
              name = c.name,
              postfix = '}',
              first = true;          
              
          var prefix = 
            switch c.meta.extract(':json') {
              case []:
                
                postfix = '}}';
                '{"$name":{';
                
              case [{ params:[{ expr: EObjectDecl(obj) }] }]:                
                
                first = false;
                var ret = haxe.format.JsonPrinter.print(ExprTools.getValue(EObjectDecl(obj).at()));
                ret.substr(0, ret.length - 1);
                  
              default:
                c.pos.error('invalid use of @:json');
            } 
            
            var args = 
              if (inlined) [macro value]
              else [for (f in cfields) macro $i{f.name}];
            
            cases.push({
              values: [macro @:pos(c.pos) $i{name}($a{args})],
              expr: macro {
                this.output($v{prefix});
                $b{[for (f in cfields) {
                  var fname = f.name;
                  macro {
                    this.output($v{'${if (first) { first = false; ""; } else ","}"${f.name}"'});
                    this.char(':'.code);
                    {
                      var value = ${
                        if (inlined)
                          macro value.$fname
                        else
                          macro $i{f.name}
                      }
                      ${f.expr};
                    }
                  }
                }]}
                this.output($v{postfix});
              },
                });            
        }
        return ESwitch(macro value, cases, null).at();
      },
      dyn: function (e, ct) 
        return macro {
          var value:haxe.DynamicAccess<$ct> = value;
          $e;
        },
      dynAccess: function (e)
        return macro {
          var first = true;
              
          this.char('{'.code);
          for (k in value.keys()) {
            if (first)
              first = false;
            else
              this.char(','.code);
              
            this.writeString(k);
            this.char(':'.code);
            {
              var value = value.get(k);
              $e;
            }
            
          }
          this.char('}'.code);
        },
      reject: function (t:Type) return 'Cannot stringify ${t.toString()}', 
    });
    
    cl.fields = cl.fields.concat(ret.fields);
    
    function add(t:TypeDefinition)
      cl.fields = cl.fields.concat(t.fields);

    add(macro class { 
      public function write(value:$ct):String {
        this.init();
        ${ret.expr};
        return this.buf.toString();
      }
    });
    
    Context.defineType(cl);
    
    return Context.getType(name);    
  }
  
}

@:forward
private abstract HasName(String) from String to String {
  @:from static function fieldInfo(f:FieldInfo):HasName
    return f.name;
}