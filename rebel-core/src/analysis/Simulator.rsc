module analysis::Simulator

import lang::ExtendedSyntax;
import lang::Builder;
import lang::Resolver;

import lang::smtlib25::AST;
import lang::smtlib25::Compiler;
import solver::SolverRunner;

import analysis::SmtResponseTranslator;
import analysis::LocTranslator;
 
import IO;
import Set; 
import String;
import List;
import util::Maybe;

alias RebelLit = lang::ExtendedSyntax::Literal;

anno loc Module@\loc;
anno loc Statement@\loc;
anno loc SyncStatement@\loc;
anno loc Expr@\loc;

data TransitionResult
	= failed(list[str] reasons)
	| successful(State new)
	;
	
data Context(map[str,str] specLookup = (), map[loc, Type] types = ())
  = context(str spec, str event)
  | flattenedEvent(str spec, str event)
  | eventAsFunction()
  | function()
  ;

data Param = param(str name, Type tipe);

data Variable 
  = var(str name, Type tipe, RebelLit val)
  | uninitialized(str name, Type tipe)
  ;
   
data EntityInstance = instance(str entityType, list[RebelLit] id, list[Variable] vals);  
data State = state(int nr, DateTime now, list[EntityInstance] instances);

list[Param] getTransitionParams(loc spec, str transitionToFire) = 
  [param("<p.name>", p.tipe) | p <- evnt.transitionParams]
  when <_, just(Built b)> := load(spec),
       EventDef evnt <- b.normalizedMod.spec.events.events,
       "<evnt.name>" == transitionToFire;

TransitionResult transition(loc spec, str entity, str transitionToFire, list[Variable] transitionParams, State current) {	
  set[Built] builtSpecs = loadAllSpecs(spec, {});
  set[Module] normalizedSpecs = {b.normalizedMod | Built b <- builtSpecs}; 
   
  //1. Find the event definition to fire
  EventDef eventToRaise = findEventDef(transitionToFire, normalizedSpecs);
  
  // Collect all the synced events and their entity types
  // TODO
  set[EventDef] syncedEvents = {};
    
  map[str,str] specLookup = ("<m.modDef.fqn.modName>":"<m.modDef.fqn>" | m <- normalizedSpecs);
  map[loc, Type] types = (() | it + b.resolvedTypes | b <- builtSpecs);
  
  list[Command] smt = declareSmtTypes(normalizedSpecs) +
                      declareSmtVariables(entity, transitionToFire, transitionParams, normalizedSpecs) +
                      declareSmtSpecLookup(normalizedSpecs) +
                      translateState(current) +
                      translateTransitionParams(entity, transitionToFire, transitionParams) +
                      translateFunctions(([] | it + f | s <- builtSpecs, FunctionDef f <- s.normalizedMod.spec.functions.defs), function(types=types)) + 
                      translateEventToSingleAsserts(entity, eventToRaise, flattenedEvent(entity, "<eventToRaise.name>", specLookup = specLookup, types = types));
  
  SolverPID pid = startSolver();
  TransitionResult result;
  
  try { 
//    runSolver(pid, intercalate("\n", compile(smt)));
    
    list[str] rawSmt = compile(smt);
    for (s <- rawSmt) {
      runSolver(pid, s);
    }
    
    if (checkSat(pid)) {
      result = successful(getNextStateModel(pid, current, eventToRaise + syncedEvents, specLookup));
    } else {
      result = failed(getUnsatCoreStatements(pid, eventToRaise));
    }
  } 
  catch ex: throw ex;
  finally {
    stopSolver(pid);
  }
  
  return result; 
}  

list[str] getUnsatCoreStatements(SolverPID pid, EventDef raisedEvent) {
  str smtResponse = runSolver(pid, compile(getUnsatCore()), wait = 20);
  list[loc] unsatCoreLocs = [strToLoc(l) | str l <- parseSmtUnsatCore(smtResponse)];
  
  list[str] unsatCoreStats = ["<s>" | /Statement s := raisedEvent, s@\loc in unsatCoreLocs] +
                             ["<s>" | /SyncStatement s := raisedEvent, s@\loc in unsatCoreLocs];

  return unsatCoreStats;
} 

State getNextStateModel(SolverPID pid, State current, set[EventDef] raisedEvents, map[str,str] specLookup) {
  lrel[str, str] unchangedFields = [<specLookup["<spec>"], "<field>"> | EventDef evnt <- raisedEvents,
    /(Statement)`new <TypeName spec>[<Expr _>].<VarName field> == <TypeName otherSpec>[<Expr _>].<VarName otherField>;` := evnt.post, 
    "<spec>" == "<otherSpec>", "<field>" == "<otherField>"];

  // TODO: filter out all unchanged, uninitialized fields
  
  return state(current.nr + 1, current.now, 
               [instance(ei.entityType, ei.id, 
                 [getNewValue(pid, ei.entityType, ei.id, v) | Variable v <- ei.vals]) 
               | EntityInstance ei <- current.instances]);
    
}

Variable getNewValue(SolverPID pid, str entityType, list[RebelLit] id, Variable current) {
  Command newValCmd = getValue([functionCall(simple("field_<entityType>_<current.name>"), 
                        [functionCall(simple("spec_<entityType>"), [var(simple("next")), *[translateLit(i) | lang::ExtendedSyntax::Literal i <- id]])])
                      ]);
                      
  str smtOutput = runSolver(pid, compile(newValCmd), wait = 10);
  str formattedRebelLit = parseSmtResponse(smtOutput);
  
  RebelLit newVal = [lang::ExtendedSyntax::Literal]"<formattedRebelLit>";
  
  return var(current.name, current.tipe, newVal);
}

set[Built] loadAllSpecs(loc file, set[loc] visited) {
  set[Built] result = {};
  
  if (<_,just(Built b)> := load(file)) {
    if (b.normalizedMod has spec) {
      result += b;    
    }
    
    for (<_, loc imported> <- b.refs.imports, imported.top notin visited) {
      set[Built] loaded = loadAllSpecs(imported.top, visited + file);
      visited += {l.normalizedMod@\loc.top | Built l <- loaded};
      result += loaded;
    } 
  }
  
  return result;
}

EventDef findEventDef(str eventName, set[Module] spcs) = evnt when /EventDef evnt := spcs, "<evnt.name>" == eventName;
EventDef findEventDef(str eventName, set[Module] spcs) { throw "Event with name \'<eventName>\' not found in specs"; }

list[Command] declareSmtSpecLookup(set[Module] mods) {
  list[Command] smt = [];

  for (Module m <- mods, /normalized(_, _, TypeName name, _, Fields fields, _, _, _, _, _, LifeCycle lc) := m) {
    // lookup @key fields
    list[Sort] sortsOfKey = [translateSort(tipe) | /(FieldDecl)`<VarName _>: <Type tipe> @key` := fields];
    
    smt += declareFunction("spec_<m.modDef.fqn>", [custom("State")] + sortsOfKey, custom("<m.modDef.fqn>"));  
    // define the initialized function
    // 1. get all the states nr's which represent initialized states
    set[int] initializedStateNrs = {toInt("<sf.nr>") | /StateFrom sf := lc, /(LifeCycleModifier)`initial` !:= sf};
    smt += defineFunction("spec_<m.modDef.fqn>_initialized", [sortedVar("entity", custom("<m.modDef.fqn>"))], \bool(), \or([eq(functionCall(simple("field_<m.modDef.fqn>__state"), [var(simple("entity"))]), lit(intVal(nr))) | int nr <- initializedStateNrs]));
  }
  
  return smt;
}

list[Command] declareSmtTypes(set[Module] specs) {
  // first declare the build in Rebel types
  list[Command] smt = declareRebelTypesAsSmtSorts();
  
  // Add the state sort as undefined sort
  smt += declareSort("State");
  
  // Add 'specification' types as undefined sorts
  smt += toList({declareSort("<m.modDef.fqn>") | /Module m := specs, m has spec});
  
  return smt; 
}

list[Command] declareSmtVariables(str entity, str transitionToFire, list[Variable] transitionParams, set[Module] spcs) {
  // declare functions for all entity fields
  list[Command] smt = [declareFunction("field_<m.modDef.fqn>_<f.name>", [custom("<m.modDef.fqn>")], translateSort(f.tipe)) | Module m <- spcs, m has spec, /FieldDecl f := m.spec.fields];
  
  smt += [declareFunction("eventParam_<entity>_<transitionToFire>_<v.name>", [custom("State")], translateSort(v.tipe)) | Variable v <- transitionParams];
  
  return smt; 
}

list[Command] translateState(State state) {
  // Declare the current and next state variables
  list[Command] smt = [declareConst("current", custom("State")), declareConst("next", custom("State"))];
  
  // Assert the current value for 'now'
  smt += [declareFunction("now", [custom("State")], custom("DateTime"))] +
         [\assert(eq(functionCall(simple("now"), [var(simple("next"))]), translateLit(state.now)))];
    
  // Assert all the current values of the entities
  smt += [\assert(eq(functionCall(simple("field_<ei.entityType>_<name>"), [functionCall(simple("spec_<ei.entityType>"), [var(simple("current")), *[translateLit(i) | lang::ExtendedSyntax::Literal i <- ei.id]])]), translateLit(val))) | EntityInstance ei <- state.instances, var(str name, Type tipe, RebelLit val) <- ei.vals];
  
  return smt; 
}

list[Command] translateTransitionParams(str entity, str transitionToFire, list[Variable] params) =
  [\assert(eq(functionCall(simple("eventParam_<entity>_<transitionToFire>_<p.name>"), [var(simple("next"))]), translateLit(p.val))) | Variable p <- params]; 

list[Command] translateFunctions(list[FunctionDef] functions, Context ctx) =
  [defineFunction("func_<f.name>", [sortedVar("param_<p.name>", translateSort(p.tipe)) | p <- f.params], translateSort(f.returnType), translateStat(f.statement, ctx)) | f <- functions];

list[Command] translateEventToSingleAsserts(str entity, EventDef evnt, Context ctx) =
  [\assert(attributed(translateStat(s, ctx), [named(locToStr(s@\loc))])) | /Statement s := evnt] +
  [\assert(attributed(translateSyncStat(s, ctx), [named(locToStr(s@\loc))])) | /SyncStatement s := evnt];

//Command translateEventToFunction(str entity, EventDef evnt) =
//  defineFunction("event_<entity>_<evnt.name>", [sortedVar("current", custom("State")), sortedVar("next", custom("State"))], \bool(),
//    \and([translateStat(s, context(entity, "<evnt.name>")) | /Statement s := evnt] + 
//         [translateSyncStat(s, context(entity, "<evnt.name>")) | /SyncStatement s := evnt])
//  );

Formula translateSyncStat(SyncStatement s, Context ctx) = lit(boolVal(true));

Formula translateStat((Statement)`(<Statement s>)`, Context ctx) = translateStat(s, ctx);
Formula translateStat((Statement)`<Annotations _> <Expr e>;`, Context ctx) = translateExpr(e, ctx);

Formula translateExpr((Expr)`new <Expr spc>[<Expr id>]`, Context ctx) = functionCall(simple("spec_<ctx.specLookup["<spc>"]>"), [var(simple("next")), translateExpr(id, ctx)]);
Formula translateExpr((Expr)`new <Expr spc>[<Expr id>].<VarName field>`, Context ctx) = functionCall(simple("field_<ctx.spec>_<field>"), [functionCall(simple("spec_<ctx.specLookup["<spc>"]>"), [var(simple("next")), translateExpr(id, ctx)])]);

Formula translateExpr((Expr)`<Expr spc>[<Expr id>]`, Context ctx) = functionCall(simple("spec_<ctx.specLookup["<spc>"]>"), [var(simple("current")), translateExpr(id, ctx)]);
Formula translateExpr((Expr)`<Expr spc>[<Expr id>].<VarName field>`, Context ctx) = functionCall(simple("field_<ctx.specLookup["<spc>"]>_<field>"), [functionCall(simple("spec_<ctx.specLookup["<spc>"]>"), [var(simple("current")), translateExpr(id, ctx)])]);

Formula translateExpr((Expr)`initialized <Expr spc>[<Expr id>]`, Context ctx) = functionCall(simple("spec_<ctx.specLookup["<spc>"]>_initialized"), [translateExpr((Expr)`<Expr spc>[<Expr id>]`, ctx)]); 

Formula translateExpr((Expr)`<Expr lhs>.<VarName field>`, Context ctx) = functionCall(simple("<field>"), [translateExpr(lhs, ctx)]); 

Formula translateExpr((Expr)`(<Expr e>)`, Context ctx) = translateExpr(e, ctx);

Formula translateExpr((Expr)`<Literal l>`, Context ctx) = translateLit(l);

Formula translateExpr((Expr)`<Ref r>`, Context ctx) 
  = functionCall(simple("eventParam_<spec>_<event>_<r>"), [var(simple("next"))])
  when flattenedEvent(str spec, str event) := ctx;

Formula translateExpr((Expr)`<Ref r>`, Context ctx) 
  = var(simple("param_<r>"))
  when function() := ctx;

Formula translateExpr((Expr)`<VarName function>(<{Expr ","}* params>)`, Context ctx) = functionCall(simple("func_<function>"), [translateExpr(p, ctx) | Expr p <- params]);

Formula translateFormula(Expr lhs, Expr rhs, (Type)`Money`, (Type)`Money`, Context ctx, Formula (Formula, Formula) createComp) 
  = createComp(functionCall(simple("amount"), [translateExpr(lhs, ctx)]), functionCall(simple("amount"), [translateExpr(rhs, ctx)])); 

default Formula translateFormula(Expr lhs, Expr rhs, Type _, Type _, Context ctx, Formula (Formula, Formula) createComp) 
  = createComp(translateExpr(lhs, ctx), translateExpr(rhs, ctx)); 

Formula translateExpr(Expr lhs, Expr rhs, (Type)`Money`, (Type)`Money`, Context ctx, Formula (Formula, Formula) createComp) 
  = functionCall(simple("consMoney"), [functionCall(simple("currency"), [translateExpr(lhs,ctx)]), 
      createComp(functionCall(simple("amount"), [translateExpr(lhs, ctx)]), functionCall(simple("amount"), [translateExpr(rhs, ctx)]))]); 

Formula translateExpr(Expr lhs, Expr rhs, (Type)`Money`, (Type)`Integer`, Context ctx, Formula (Formula, Formula) createComp) 
  = functionCall(simple("consMoney"), [functionCall(simple("currency"), [translateExpr(lhs,ctx)]), 
      createComp(functionCall(simple("amount"), [translateExpr(lhs, ctx)]), translateExpr(rhs, ctx))]); 

Formula translateExpr(Expr lhs, Expr rhs, (Type)`Money`, (Type)`Percentage`, Context ctx, Formula (Formula, Formula) createComp) 
  = functionCall(simple("consMoney"), [functionCall(simple("currency"), [translateExpr(lhs,ctx)]), 
      createComp(functionCall(simple("amount"), [translateExpr(lhs, ctx)]), translateExpr(rhs, ctx))]); 

default Formula translateExpr(Expr lhs, Expr rhs, Type _, Type _, Context ctx, Formula (Formula, Formula) createComp) 
  = createComp(translateExpr(lhs, ctx), translateExpr(rhs, ctx)); 

Formula translateExpr((Expr)`<Expr lhs> + <Expr rhs>`, Context ctx) 
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return add(l, [r]); });

Formula translateExpr((Expr)`<Expr lhs> - <Expr rhs>`, Context ctx)
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return sub(l, [r]); });

Formula translateExpr((Expr)`<Expr lhs> * <Expr rhs>`, Context ctx)
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return mul(l, [r]); })
  when ctx.types[lhs@\loc] == (Type)`Percentage` || ctx.types[rhs@\loc] == (Type)`Percentage`;

Formula translateExpr((Expr)`<Expr lhs> * <Expr rhs>`, Context ctx)
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return mul(l, [r]); })
  when ctx.types[lhs@\loc] != (Type)`Percentage` && ctx.types[rhs@\loc] != (Type)`Percentage`;

Formula translateExpr((Expr)`<Expr lhs> / <Expr rhs>`, Context ctx)
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return div(l, [r]); });

Formula translateExpr((Expr)`<Expr lhs> % <Expr rhs>`, Context ctx)
  = translateExpr(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return \mod(l, r); });

Formula translateExpr((Expr)`-<Expr expr>`, Context ctx) = neg(translateExpr(expr, ctx));

Formula translateExpr((Expr)`not <Expr expr>`, Context ctx) = not(translateExpr(expr, ctx));

Formula translateExpr((Expr)`<Expr lhs> \< <Expr rhs>`, Context ctx) 
  = translateFormula(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return lt(l, r); });

Formula translateExpr((Expr)`<Expr lhs> \<= <Expr rhs>`, Context ctx) 
  = translateFormula(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return lte(l, r); });

Formula translateExpr((Expr)`<Expr lhs> \> <Expr rhs>`, Context ctx) 
  = translateFormula(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return gt(l, r); });

Formula translateExpr((Expr)`<Expr lhs> \>= <Expr rhs>`, Context ctx)
  = translateFormula(lhs, rhs, ctx.types[lhs@\loc], ctx.types[rhs@\loc], ctx, Formula (Formula l, Formula r) { return gte(l, r); });

Formula translateExpr((Expr)`<Expr lhs> == <Expr rhs>`, Context ctx) = eq(translateExpr(lhs, ctx), translateExpr(rhs, ctx));
Formula translateExpr((Expr)`<Expr lhs> != <Expr rhs>`, Context ctx) = \not(eq(translateExpr(lhs, ctx), translateExpr(rhs, ctx)));
Formula translateExpr((Expr)`<Expr lhs> && <Expr rhs>`, Context ctx) = and([translateExpr(lhs, ctx), translateExpr(rhs, ctx)]);
Formula translateExpr((Expr)`<Expr lhs> || <Expr rhs>`, Context ctx) = or([translateExpr(lhs, ctx), translateExpr(rhs, ctx)]);

  //| "{" Expr lower ".." Expr upper"}"   
  //| "(" {MapElement ","}* mapElems ")"
  //| staticSet: "{" {Expr ","}* setElems "}"
  //| "{" Expr elem "|" Expr loopVar "\<-" Expr set "}"
  //| "{" Expr init "|" Statement reducer "|" Expr loopVar "\<-" Expr set "}" 
  //| isMember: Expr lhs "in" Expr rhs
  //> right ( Expr cond "?" Expr whenTrue ":" Expr whenFalse
  //  | Expr cond "-\>" Expr implication
  //| "finalized" Expr
  //| Expr lhs "instate" Expr rhs
  
default Formula translateExpr(Expr exp, Context ctx) { throw "Translation for expr \'<exp>\' not yet implemented"; }
  
Sort translateSort((Type)`Currency`) = custom("Currency");
Sort translateSort((Type)`Date`) = custom("Date");
Sort translateSort((Type)`Time`) = custom("Time");
Sort translateSort((Type)`DateTime`) = custom("DateTime");
Sort translateSort((Type)`IBAN`) = custom("IBAN");
Sort translateSort((Type)`Money`) = custom("Money");
Sort translateSort((Type)`Integer`) = \int();
Sort translateSort((Type)`Frequency`) = custom("Frequency");
Sort translateSort((Type)`Percentage`) = custom("Percentage");

default Sort translateSort(Type t) { throw "Sort conversion for <t> not yet implemented"; }

//Formula translateLit(value v) = translateLit(l) when RebelLit l := v;

Formula translateLit((Literal)`<Int i>`) = translateLit(i);
Formula translateLit((Literal)`<Percentage p>`) = translateLit(p);

Formula translateLit((Literal)`<IBAN i>`) = translateLit(i);

Formula translateLit((Literal)`<Money m>`) = translateLit(m);//functionCall(simple("amount"), [translateLit(m)]);
Formula translateLit((Literal)`<DateTime tm>`) = translateLit(tm);

Formula translateLit(Money m) = lit(adt("consMoney", [lit(strVal("<m.cur>")), translateLit(m.amount)]));
Formula translateLit(MoneyAmount ma) = lit(intVal(toInt("<ma.whole>") * 100 + toInt("<ma.decimals>")));

Formula translateLit((DateTime)`now`) = functionCall(simple("now"), [var(simple("next"))]);
Formula translateLit(DateTime dt) = lit(adt("consDateTime", [translateLit(dt.date), translateLit(dt.time)]));

Formula translateLit(Date d) = lit(adt("consDate", [translateLit(d.day), translateLit(d.month),translateLit(year)])) when d has year, /Int year := d.year;
Formula translateLit(Date d) = lit(adt("consDate", [translateLit(d.day), translateLit(d.month), translateLit(0)])) when !(d has year); 
Formula translateLit(Time t) = lit(adt("consTime", [translateLit(toInt("<t.hour>")), translateLit(toInt("<t.minutes>")), translateLit(toInt("<sec>"))])) when t has seconds, /Int sec := t.seconds; 
Formula translateLit(Time t) = lit(adt("consTime", [translateLit(toInt("<t.hour>")), translateLit(toInt("<t.minutes>")), translateLit(0)])) when !t has seconds; 
Formula translateLit(IBAN i) = lit(adt("consIBAN", [translateLit("<i.countryCode>"), translateLit(toInt("<i.checksum>")), translateLit("<i.accountNumber>")])); 

Formula translateLit((Month)`Jan`) = lit(intVal(1)); 
Formula translateLit((Month)`Feb`) = lit(intVal(2));
Formula translateLit((Month)`Mar`) = lit(intVal(3));
Formula translateLit((Month)`Apr`) = lit(intVal(4));
Formula translateLit((Month)`May`) = lit(intVal(5));
Formula translateLit((Month)`Jun`) = lit(intVal(6)); 
Formula translateLit((Month)`Jul`) = lit(intVal(7));
Formula translateLit((Month)`Aug`) = lit(intVal(8));
Formula translateLit((Month)`Sep`) = lit(intVal(9));
Formula translateLit((Month)`Oct`) = lit(intVal(10));
Formula translateLit((Month)`Nov`) = lit(intVal(11));
Formula translateLit((Month)`Dec`) = lit(intVal(12));

Formula translateLit(Int i) = lit(intVal(toInt("<i>")));
Formula translateLit(int i) = lit(intVal(i));

Formula translateLit(Percentage p) = lit(intVal(toInt("<p.per>")));

Formula translateLit(String s) = lit(strVal("<s>"));
Formula translateLit(str s) = lit(strVal(s));

default Literal translateLit(value l) { throw "translateLit(..) not implemented for <l>"; }

list[Command] declareRebelTypesAsSmtSorts() {   
  set[tuple[str,Sort]] rebelTypes = {<"Currency", \string()>,
                                     <"Frequency", \int()>,
                                     <"Percentage", \int()>,
                                     <"Period", \int()>,
                                     <"Term", \int()>};
                             
  return [defineSort(name, [], sort) | <str name, Sort sort> <- rebelTypes] +
         [declareDataTypes([], [dataTypeDef("IBAN", [combinedCons("consIBAN", [sortedVar("countryCode", string()), sortedVar("checksum",\int()), sortedVar("accountNumber", string())])])]),
          declareDataTypes([], [dataTypeDef("Money", [combinedCons("consMoney", [sortedVar("currency", string()), sortedVar("amount", \int())])])]),
          declareDataTypes([], [dataTypeDef("Date", [
            combinedCons("consDate", [sortedVar("date", \int()), sortedVar("month", \int()), sortedVar("year", \int())]), 
            cons("undefDate")])]),
          declareDataTypes([], [dataTypeDef("Time", [
            combinedCons("consTime", [sortedVar("hour", \int()), sortedVar("minutes", \int()), sortedVar("seconds", \int())]), 
            cons("undefTime")])]),
          declareDataTypes([], [dataTypeDef("DateTime", [combinedCons("consDateTime", [sortedVar("date", custom("Date")), sortedVar("time", custom("Time"))]), cons("undefDateTime")])])                                   
          ];                                  
}

