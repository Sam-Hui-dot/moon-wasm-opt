///|
fn instr_encoded_size(ins : Instr) -> Int32 {
  let w = BinWriter::new()
  write_instr(w, ins)
  w.to_bytes().length()
}

///|
fn is_safe_const_global_expr(ins : Instr) -> Bool {
  match ins {
    I32Const(_)
    | I64Const(_)
    | F32Const(_)
    | F64Const(_)
    | RefNull(_)
    | RefFunc(_) => true
    _ => false
  }
}

///|
fn count_global_gets_in_instrs(
  instrs : Array[Instr],
  counts : Map[UInt32, Int32],
) -> Unit {
  for ins in instrs {
    match ins {
      GlobalGet(g) => counts[g] = counts.get(g).unwrap_or(0) + 1
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        count_global_gets_in_instrs(b, counts)
      If(_, t, e) => {
        count_global_gets_in_instrs(t, counts)
        count_global_gets_in_instrs(e, counts)
      }
      _ => ()
    }
  }
}

///|
fn replace_global_gets_in_instrs(
  instrs : Array[Instr],
  repl : Map[UInt32, Instr],
) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      GlobalGet(g) =>
        match repl.get(g) {
          Some(c) => c
          None => ins
        }
      Block(bt, b) => Block(bt, replace_global_gets_in_instrs(b, repl))
      Loop(bt, b) => Loop(bt, replace_global_gets_in_instrs(b, repl))
      If(bt, t, e) =>
        If(
          bt,
          replace_global_gets_in_instrs(t, repl),
          replace_global_gets_in_instrs(e, repl),
        )
      TryTable(bt, cs, b) =>
        TryTable(bt, cs, replace_global_gets_in_instrs(b, repl))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
/// Pass 7: Propagate module-defined immutable scalar/ref constant globals into function bodies.
/// Never propagates heap-allocating WasmGC initializers (`struct.new`/`array.new*`) to preserve reference identity.
pub fn pass_const_globals(
  mod : WasmModule,
  prefer_speed~ : Bool = false,
) -> WasmModule {
  if mod.globals.is_empty() || mod.codes.is_empty() {
    return mod
  }
  let imp_globals = mod.imported_global_count()

  // Resolve immutable module-defined globals to side-effect-free constant instructions (including forward aliases)
  let resolved : Map[UInt32, Instr] = Map([])
  for i, gd in mod.globals {
    let gidx = imp_globals + i.reinterpret_as_uint()
    if !gd.global_type.mutable && gd.init.length() == 1 {
      let expr = gd.init[0]
      if is_safe_const_global_expr(expr) {
        resolved[gidx] = expr
      } else {
        match expr {
          GlobalGet(other_g) =>
            match resolved.get(other_g) {
              Some(c) => resolved[gidx] = c
              None => ()
            }
          _ => ()
        }
      }
    }
  }
  if resolved.is_empty() {
    return mod
  }

  // Track exports and uses inside vs outside function bodies for exact size-aware profitability
  let exported_globals : Set[UInt32] = Set([])
  for exp in mod.exports {
    if exp.kind == Global {
      exported_globals.add(exp.idx)
    }
  }

  let body_uses : Map[UInt32, Int32] = Map([])
  for fb in mod.codes {
    count_global_gets_in_instrs(fb.body, body_uses)
  }

  let non_body_uses : Map[UInt32, Int32] = Map([])
  for tt in mod.tables {
    match tt.init_expr {
      Some(ex) => count_global_gets_in_instrs(ex, non_body_uses)
      None => ()
    }
  }
  for gd in mod.globals {
    count_global_gets_in_instrs(gd.init, non_body_uses)
  }
  for el in mod.elements {
    match el.offset {
      Some(ex) => count_global_gets_in_instrs(ex, non_body_uses)
      None => ()
    }
    for ex in el.init_exprs {
      count_global_gets_in_instrs(ex, non_body_uses)
    }
  }
  for ds in mod.datas {
    match ds.offset {
      Some(ex) => count_global_gets_in_instrs(ex, non_body_uses)
      None => ()
    }
  }

  let repl : Map[UInt32, Instr] = Map([])
  for gidx, const_ins in resolved {
    let uses = body_uses.get(gidx).unwrap_or(0)
    if uses == 0 {
      continue
    }
    let c_len = instr_encoded_size(const_ins)
    let g_len = instr_encoded_size(GlobalGet(gidx))
    let is_exp = exported_globals.contains(gidx)
    let other_uses = non_body_uses.get(gidx).unwrap_or(0)
    let profitable = if c_len <= g_len || prefer_speed {
      true
    } else if !is_exp && other_uses == 0 {
      // Deleting the global definition in module-dce saves ~(3 + c_len) bytes
      uses * (c_len - g_len) <= 3 + c_len
    } else {
      false
    }
    if profitable {
      repl[gidx] = const_ins
    }
  }

  if repl.is_empty() {
    return mod
  }

  let new_codes : Array[FuncBody] = []
  let mut changed = false
  for fb in mod.codes {
    let nb = replace_global_gets_in_instrs(fb.body, repl)
    if nb != fb.body {
      changed = true
      new_codes.push({ locals: fb.locals, body: nb, })
    } else {
      new_codes.push(fb)
    }
  }
  if !changed {
    mod
  } else {
    { ..mod, codes: new_codes, }
  }
}

///|
fn replace_write_only_global_sets(
  instrs : Array[Instr],
  dead_globals : Set[UInt32],
) -> Array[Instr] {
  let out : Array[Instr] = []
  let mut changed = false
  for ins in instrs {
    match ins {
      GlobalSet(g) if dead_globals.contains(g) => {
        changed = true
        out.push(Drop)
      }
      Block(bt, b) => {
        let nb = replace_write_only_global_sets(b, dead_globals)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, b) => {
        let nb = replace_write_only_global_sets(b, dead_globals)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Loop(bt, nb))
      }
      If(bt, t, e) => {
        let nt = replace_write_only_global_sets(t, dead_globals)
        let ne = replace_write_only_global_sets(e, dead_globals)
        if !physical_equal(nt, t) || !physical_equal(ne, e) {
          changed = true
        }
        out.push(If(bt, nt, ne))
      }
      TryTable(bt, cs, b) => {
        let nb = replace_write_only_global_sets(b, dead_globals)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(TryTable(bt, cs, nb))
      }
      other => out.push(other)
    }
  }
  if !changed {
    instrs
  } else {
    out
  }
}

///|
/// Pass 16: Replace `global.set` on unexported internal mutable globals that have zero `global.get` reads
/// anywhere in the module with `drop`, unlocking subsequent peephole and `module-dce` removal.
pub fn pass_write_only_globals(mod : WasmModule) -> WasmModule {
  if mod.globals.is_empty() || mod.codes.is_empty() {
    return mod
  }
  let imp_globals = mod.imported_global_count()
  let exported : Set[UInt32] = Set([])
  for exp in mod.exports {
    if exp.kind == Global {
      exported.add(exp.idx)
    }
  }

  let all_gets : Map[UInt32, Int32] = Map([])
  for fb in mod.codes {
    count_global_gets_in_instrs(fb.body, all_gets)
  }
  for tt in mod.tables {
    match tt.init_expr {
      Some(ex) => count_global_gets_in_instrs(ex, all_gets)
      None => ()
    }
  }
  for gd in mod.globals {
    count_global_gets_in_instrs(gd.init, all_gets)
  }
  for el in mod.elements {
    match el.offset {
      Some(ex) => count_global_gets_in_instrs(ex, all_gets)
      None => ()
    }
    for ex in el.init_exprs {
      count_global_gets_in_instrs(ex, all_gets)
    }
  }
  for ds in mod.datas {
    match ds.offset {
      Some(ex) => count_global_gets_in_instrs(ex, all_gets)
      None => ()
    }
  }

  let write_only : Set[UInt32] = Set([])
  for i, gd in mod.globals {
    let gidx = imp_globals + i.reinterpret_as_uint()
    if gd.global_type.mutable &&
      !exported.contains(gidx) &&
      all_gets.get(gidx).unwrap_or(0) == 0 {
      write_only.add(gidx)
    }
  }
  if write_only.is_empty() {
    return mod
  }

  let new_codes : Array[FuncBody] = []
  let mut changed = false
  for fb in mod.codes {
    let nb = replace_write_only_global_sets(fb.body, write_only)
    if !physical_equal(nb, fb.body) {
      changed = true
      new_codes.push({ locals: fb.locals, body: nb, })
    } else {
      new_codes.push(fb)
    }
  }
  if !changed {
    mod
  } else {
    { ..mod, codes: new_codes, }
  }
}
