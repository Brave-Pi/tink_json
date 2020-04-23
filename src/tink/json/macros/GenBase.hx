package tink.json.macros;

#if macro
import haxe.macro.Type;
import haxe.macro.Expr;
import tink.typecrawler.Generator;

using haxe.macro.Tools;
using tink.MacroApi;
using tink.CoreApi;

class GenBase {
  var customMeta:String;
  function new(customMeta) {
    this.customMeta = customMeta;
  }
  public function rescue(t:Type, pos:Position, gen:GenType)
    return None;

  public function shouldIncludeField(c:ClassField, owner:Option<ClassType>):Bool
    return Helper.shouldIncludeField(c, owner);

  function processRepresentation(pos:Position, actual:Type, representation:Type, value:Expr):Expr
    return throw 'abstract';

  function processDynamic(pos:Position):Expr
    return throw 'abstract';

  function processValue(pos:Position):Expr
    return throw 'abstract';

  function processLazy(type:ComplexType, pos:Position):Expr
    return throw 'abstract';

  function processSerialized(pos:Position):Expr
    return throw 'abstract';

  function processCustom(custom:CustomRule, original:Type, gen:Type->Expr):Expr
    return throw 'abstract';

  public function drive(type:Type, pos:Position, gen:Type->Position->Expr):Expr
    return
      switch Macro.getRepresentation(type, pos) {
        case Some(v):
          processRepresentation(pos, type, v, gen(v, pos));
        case None:
          switch type.getMeta().filter(function (m) return m.has(customMeta)) {
            case []:
              switch type.reduce() {
                case TDynamic(null) | TAbstract(_.get() => {name: 'Any', pack: []}, _):
                  processDynamic(pos);
                case TEnum(_.get().module => 'tink.json.Value', _):
                  processValue(pos);
                case TAbstract(_.get().module => 'tink.core.Lazy', [t]):
                  processLazy(t.toComplex(), pos);
                case TAbstract(_.get().module => 'tink.json.Serialized', _):
                  processSerialized(pos);
                case TMono(_):
                  pos.error('failed to infer type');
                default:
                  gen(type, pos);
              }
            case v:
              switch v[0].extract(customMeta)[0] {
                case { params: [custom] }:
                  var rule:CustomRule =
                    switch custom {
                      case { expr: EFunction(_, _) }: WithFunction(custom);
                      case _.typeof().sure().reduce() => TFun(_, _): WithFunction(custom);
                      default: WithClass(custom);
                    }
                  processCustom(rule, type, drive.bind(_, pos, gen));
                case v: v.pos.error('@$customMeta must have exactly one parameter');
              }
          }
      }

  function isNullable(t:Type)
    return switch t {
      case TAbstract(_.get() => { pack: [], name: 'Null' }, _),
           TType(_.get() => { pack: [], name: 'Null' }, _): true;
      case TType(_) | TLazy(_):
        isNullable(t.reduce());
      default: false;
    }
}
#end