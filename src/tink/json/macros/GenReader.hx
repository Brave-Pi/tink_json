package tink.json.macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.ds.Option;
import tink.typecrawler.Crawler;
import tink.typecrawler.FieldInfo;
import tink.typecrawler.Generator;

using haxe.macro.Tools;
using tink.MacroApi;
using tink.CoreApi;

class GenReader extends GenBase {
  static public var inst = new GenReader();

  function new() {
    super(':jsonParse');
  }

  static var OPTIONAL:Metadata = [{ name: ':optional', params:[], pos: (macro null).pos }];

  public function wrap(placeholder:Expr, ct:ComplexType):Function
    return placeholder.func(ct);

  public function nullable(e)
    return macro
      if (this.allow('null')) null;
      else $e;

  public function string()
    return macro (this.parseString().toString() : String);

  public function int()
    return macro this.parseNumber().toInt();

  public function float()
    return macro this.parseNumber().toFloat();

  public function bool()
    return macro this.parseBool();

  public function date()
    return macro Date.fromTime(this.parseNumber().toFloat());

  public function bytes()
    return macro haxe.crypto.Base64.decode(this.parseString().toString());

  public function map(k, v)
    return macro {
      this.expect('[');
      var __ret = new #if haxe4 haxe.ds.Map #else Map #end();
      if (!allow(']')) {
        do {
          this.expect('[');
          __ret.set($k, this.expect(',') & $v);
          this.expect(']');
        } while (allow(','));
        expect(']');
      }
      __ret;
    }

  public function anon(fields:Array<FieldInfo>, ct) {

    var read = macro this.skipValue(),
        vars:Array<Var> = [],
        obj = [];
    EObjectDecl(obj);//help type inference
    for (f in fields) {
      var ct = f.type.toComplex(),
          name = 'v_' + f.name,
          jsonName = Macro.nativeName(f),
          optional = f.optional;

      var option = switch f.type.reduce() {
        case TEnum(_.get() => {pack:['haxe','ds'], name:'Option'}, [v]): Some(v);
        default: None;
      }

      var defaultValue = switch f.meta.getValues(':default') {
        case []: None;
        case [[v]]:
          if (option == None)
            Some(v)
          else v.reject('Cannot specify default for `Option`');
        case v: f.pos.error('more than one @:default');
      }

      var hasName = 'has$name';

      read = macro @:pos(f.pos)
        if (__name__ == $v{jsonName}) {
          ${
            switch option {
              case Some(t):
                macro $i{name} = Some(${f.as(t)});
              default:
                macro $i{name} = ${f.expr};
            }
          }
          ${
            if (optional) macro $b{[]}
            else macro $i{hasName} = true
          }
        }
        else $read;

      obj.push({
        field: f.name,
        expr:
          switch option {
            case Some(v):
              if (optional)
                macro switch $i{name} {
                  case null: None;
                  case v: v;
                }
              else macro if ($i{hasName}) $i{name} else None;
            case None:
              if (optional || defaultValue != None) macro $i{name}
              else macro if ($i{hasName}) $i{name} else __missing__($v{jsonName});
          },
      });

      if (optional)
        vars.push(switch defaultValue {
          case None: {
            name: name,
            expr: macro null,
            type: macro : Null<$ct>
          }
          case Some(v): {
            name: name,
            expr: v,
            type: ct
          }
        });
      else {

        var valType =
          switch Crawler.plainAbstract(f.type) {
            case Some(a): a;
            default: f.type;
          }

        vars.push({
          name: name,
          expr: switch defaultValue {
            case Some(v): v;
            default: switch valType.getID() {
              case 'Bool': macro false;
              case 'Int' | 'UInt': macro 0;
              case 'Float': macro .0;
              default: macro null;
            }
          },
          type: ct,
        });

        vars.push({
          type: macro : Bool,
          name: hasName,
          expr: macro false,
        });
      }

    };

    return macro {

      ${EVars(vars).at()};

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
        return this.die('missing field "' + field + '"', __start__);
      };

      (${EObjectDecl(obj).at()} : $ct);
    };
  }

  public function array(e)
    return macro {
      this.expect('[');
      var __ret = [];
      if (!allow(']')) {
        do {
          __ret.push($e);
        } while (allow(','));
        expect(']');
      }
      __ret;
    }

  public function enm(constructors:Array<EnumConstructor>, ct:ComplexType, pos:Position, gen:GenType) {
    if(constructors.length == 0) pos.error('Enum ${ct.toString()} has no constructors and tink_json can\'t handle it');
    var fields = new Map<String, LiteInfo>(),
        cases = new Array<Case>();

    function captured(f:String)
      return macro @:pos(pos) $i{
        if (f.charAt(0).toUpperCase() == f.charAt(0)) '__'+f.toLowerCase()
        else f
      };

    function add(f:LiteInfo)
      switch fields[f.name] {
        case null: fields[f.name] = f;
        case same if (Crawler.typesEqual(same.type, f.type)):
          fields[f.name] = {
            pos: f.pos,
            name: f.name,
            access: f.access,
            type: f.type,
            optional: same.optional || f.optional,
          }
        case other:
          fields[f.name] = {
            pos: f.pos,
            name: f.name,
            access: f.access,
            type: (macro:tink.json.Serialized<tink.core.Any>).toType().sure(),
            optional: other.optional || f.optional,
          }
      }

    function mkComplex(fields:Iterable<LiteInfo>):ComplexType
      return TAnonymous([for (f in fields) {
        name: f.name,
        pos: f.pos,
        meta: if (f.optional) OPTIONAL else [],
        kind: FProp(f.access.get, f.access.set, f.type.toComplex()),
      }]);

    var argLess = [];
    for (c in constructors) {

      var inlined = c.inlined,
          cfields = c.fields,
          c = c.ctor,
          name = c.name,
          hasArgs = !c.type.reduce().match(TEnum(_,_));

      switch c.meta.extract(':json') {
        case [] if(!hasArgs):
            argLess.push(new Named(name, name));
        case []:

          add({
            name: name,
            optional: true,
            type: mkComplex(cfields).toType().sure(),
            pos: c.pos,
            access: { get: 'default', set: 'default' },
          });

          cases.push({
            values: [macro { $name : o }],
            guard: macro o != null,
            expr: {
              var args =
                if (inlined) [macro o]; // FIXME: this cast is a workaround for https://github.com/haxetink/tink_json/issues/56
                else [for (f in cfields) {
                  var name = f.name;
                  macro o.$name;
                }];

              switch args {
                case []: macro ($i{name} : $ct);
                case _: macro ($i{name}($a{args}) : $ct);
              }
            }
          });

        case [{ params:[{ expr: EConst(CString(v)) }]}] if(!hasArgs):
          argLess.push(new Named(name, v));

        case [{ params:[{ expr: EObjectDecl(obj) }] }]:
          if(hasArgs) {
            for (f in cfields) {
              add(f.makeOptional());
            }
          }

          for (f in obj)
            add({
              pos: f.expr.pos,
              name: f.field,
              type: f.expr.typeof().sure(),
              optional: true,
              access: { get: 'default', set: 'default' },
            });

        case v:
          c.pos.error('invalid use of @:json');
      }
    }

    // second pass for @:json
    for (c in constructors) {
      switch c.ctor.meta.extract(':json') {
        case [{ params:[{ expr: EObjectDecl(obj) }] }]:

          var pat = obj.copy(),
              guard = macro true;

          for(f in c.fields) {
            if (!(f.optional || isNullable(f.type)))
              guard = macro $guard && ${captured(f.name)} != null;

            pat.push({ field: f.name, expr: macro ${captured(f.name)}});
          }

          function read(f:FieldInfo) {
            var e = captured(f.name);
            return if(fields[f.name].type.getID() == 'tink.json.Serialized') {
              var ct = f.type.toComplex();
              if(f.optional) {
                macro {
                  var s = $e;
                  s == null ? null : (cast s:tink.json.Serialized<$ct>).parse();
                }
              } else {
                macro (cast $e:tink.json.Serialized<$ct>).parse();
              }
            } else {
              e;
            }
          }

          var args =
            if (c.inlined) [EObjectDecl([for (f in c.fields) { field: f.name, expr: read(f) }]).at(pos)];
            else [for (f in c.fields) read(f)];

          var call = switch args {
            case []: macro ($i{c.ctor.name} : $ct);
            case _: macro ($i{c.ctor.name}($a{args}) : $ct);
          }

          cases.push({
            values: [EObjectDecl(pat).at()],
            guard: guard,
            expr: call
          });
        case _:
      }
    }

    var ret = macro {
      var __ret = ${gen(mkComplex(fields).toType().sure(), pos)};
      ${ESwitch(
        macro __ret,
        cases,
        macro throw new tink.core.Error(422, 'Cannot process '+Std.string(__ret))
      ).at(pos)};
    }

    return
      if (argLess.length == 0) ret;
      else {

        var argLessSwitch = ESwitch(macro parseRestOfString().toString(), [for (a in argLess) {
          values: [macro $v{a.value}], expr: macro $i{a.name},
        }].concat([{
          values: [macro invalid], expr: macro throw new tink.core.Error(422, 'Invalid constructor '+invalid),
        }]), null).at(pos);

        macro if (allow('"')) $argLessSwitch else $ret;
      }
  }

  public function enumAbstract(names:Array<Expr>, e:Expr, ct:ComplexType, pos:Position):Expr {
    return macro @:pos(pos) {
      var v:$ct = cast $e;
      ${ESwitch(
        macro v,
        [{expr: macro v, values: names}],
        macro {
          var list = $a{names};
          throw new tink.core.Error(422, 'Unrecognized enum value: ' + v + '. Accepted values are: ' + tink.Json.stringify(list));
        }
      ).at(pos)}
    }
  }

  public function dyn(e, ct)
    return macro ($e : Dynamic<$ct>);

  public function dynAccess(e)
    return macro {
      this.expect('{');
      var __ret = new haxe.DynamicAccess();
      if (!allow('}')) {
        do {
          __ret[this.parseString().toString()] = expect(':') & $e;
        } while (allow(','));
        expect('}');
      }
      __ret;
    }

  override function processDynamic(pos)
    return macro @:pos(pos) this.parseDynamic();

  override function processValue(pos)
    return macro @:pos(pos) this.parseValue();

  override function processSerialized(pos)
    return macro @:pos(pos) this.parseSerialized();

  override function processLazy(t, pos)
    return macro @:pos(pos) {
      var v:tink.json.Serialized<$t> = this.parseSerialized();
      tink.core.Lazy.ofFunc(function () return v.parse());
    }

  override function processCustom(c:CustomRule, original:Type, gen:Type->Expr) {
    var original = original.toComplex();

    return switch c {
      case WithClass(parser):
        var path = parser.toString().asTypePath();

        var rep = (macro @:pos(parser.pos) { var f = null; (new $path(null).parse(f()) : $original); f(); }).typeof().sure();

        macro @:pos(parser.pos) this.plugins.get($parser).parse(${gen(rep)});
      case WithFunction(e):

        var rep = (macro @:pos(e.pos) { var f = null; ($e(f()) : $original); f(); }).typeof().sure();

        macro @:pos(e.pos) $e(${gen(rep)});
    }
  }

  override function processRepresentation(pos:Position, actual:Type, representation:Type, value:Expr):Expr {
    var rt = actual.toComplex();
    var ct = representation.toComplex();

    return macro @:pos(pos) {
      var __start__ = this.pos,
          rep = $value;

      try {
        (new tink.json.Representation<$ct>(rep) : $rt);
      }
      catch (e:Dynamic) {
        this.die(Std.string(e), __start__);
      }
    };
  }

  public function reject(t:Type)
    return 'tink_json cannot parse ${t.toString()}. For parsing custom data, please see https://github.com/haxetink/tink_json#custom-abstracts';

  override public function drive(type:Type, pos:Position, gen:Type->Position->Expr):Expr
    return
      switch type.reduce() {
        case TAbstract(_.get() => {pack: [], name: 'UInt'}, _):
          macro this.parseNumber().toUInt();
        default: super.drive(type, pos, gen);
      }
}

private typedef LiteInfo = {
  var name(default, never):String;
  var pos(default, never):Position;
  var type(default, never):Type;
  var optional(default, never):Bool;
  var access(default, never):FieldAccessInfo;
}
#end