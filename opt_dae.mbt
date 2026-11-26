///|
priv enum ArgConstState {
  Unseen
  ConstVal(Instr)
  Varying
}

///|
fn is_safe_arg_const(ins : Instr) -> Bool {
  match ins {
    I32Const(_) | I64Const(_) | F32Const(_) | F64Const(_) => true
    _ => false
  }
}

///|
fn merge_arg_state(cur : ArgConstState, incoming : Instr?) -> ArgConstState {
  match (cur, incoming) {
    (Varying, _) => Varying
    (_, None) => Varying
    (Unseen, Some(ins)) =>
      if is_safe_arg_const(ins) {
        ConstVal(ins)
      } else {
        Varying
      }
    (ConstVal(prev), Some(ins)) =>
      if prev == ins {
        ConstVal(prev)
      } else {
        Varying
      }
  }
}

///|
fn scan_call_arg_consts(
  instrs : Array[Instr],
  param_counts : Map[UInt32, Int32],
  states : Map[UInt32, Array[ArgConstState]],
) -> Unit {
  for idx, ins in instrs {
    match ins {
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        scan_call_arg_consts(b, param_counts, states)
      If(_, t, e) => {
        scan_call_arg_consts(t, param_counts, states)
        scan_call_arg_consts(e, param_counts, states)
      }
      Call(fidx) =>
        match param_counts.get(fidx) {
          Some(pcnt) if pcnt > 0 => {
            let arr = match states.get(fidx) {
              Some(a) => a
              None => {
                let a : Array[ArgConstState] = []
                for _ in 0..<pcnt {
                  a.push(Unseen)
                }
                states[fidx] = a
                a
              }
            }
            // Walk backwards from idx-1 for contiguous pure single-push constants matching trailing parameters
            let mut k = pcnt - 1
            let mut pos = idx - 1
            let mut chain_ok = true
            while k >= 0 {
              if chain_ok && pos >= 0 {
                let prev = instrs[pos]
                if is_safe_arg_const(prev) {
                  arr[k] = merge_arg_state(arr[k], Some(prev))
                } else {
                  arr[k] = Varying
                  if !is_pure_single_push(prev) {
                    chain_ok = false
                  }
                }
              } else {
                arr[k] = Varying
              }
              k -= 1
              pos -= 1
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
}

///|
fn replace_const_params_in_instrs(
  instrs : Array[Instr],
  repl : Map[UInt32, Instr],
) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      LocalGet(l) =>
        match repl.get(l) {
          Some(c) => c
          None => ins
        }
      Block(bt, b) => Block(bt, replace_const_params_in_instrs(b, repl))
      Loop(bt, b) => Loop(bt, replace_const_params_in_instrs(b, repl))
      If(bt, t, e) =>
        If(
          bt,
          replace_const_params_in_instrs(t, repl),
          replace_const_params_in_instrs(e, repl),
        )
      TryTable(bt, cs, b) =>
        TryTable(bt, cs, replace_const_params_in_instrs(b, repl))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn shift_locals_above(
  instrs : Array[Instr],
  threshold : UInt32,
) -> Array[Instr] {
  fn adj(l : UInt32) -> UInt32 {
    if l >= threshold {
      l - 1U
    } else {
      l
    }
  }
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      LocalGet(l) => LocalGet(adj(l))
      LocalSet(l) => LocalSet(adj(l))
      LocalTee(l) => LocalTee(adj(l))
      Block(bt, b) => Block(bt, shift_locals_above(b, threshold))
      Loop(bt, b) => Loop(bt, shift_locals_above(b, threshold))
      If(bt, t, e) =>
        If(
          bt,
          shift_locals_above(t, threshold),
          shift_locals_above(e, threshold),
        )
      TryTable(bt, cs, b) => TryTable(bt, cs, shift_locals_above(b, threshold))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn insert_drop_before_calls(
  instrs : Array[Instr],
  pruned_funcs : Map[UInt32, Bool],
) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    match ins {
      Call(f) => {
        if pruned_funcs.contains(f) {
          out.push(Drop)
        }
        out.push(ins)
      }
      Block(bt, b) =>
        out.push(Block(bt, insert_drop_before_calls(b, pruned_funcs)))
      Loop(bt, b) =>
        out.push(Loop(bt, insert_drop_before_calls(b, pruned_funcs)))
      If(bt, t, e) =>
        out.push(
          If(
            bt,
            insert_drop_before_calls(t, pruned_funcs),
            insert_drop_before_calls(e, pruned_funcs),
          ),
        )
      TryTable(bt, cs, b) =>
        out.push(TryTable(bt, cs, insert_drop_before_calls(b, pruned_funcs)))
      other => out.push(other)
    }
  }
  out
}

///|
fn find_or_add_func_type(
  type_groups : Array[RecGroup],
  params : Array[ValType],
  results : Array[ValType],
) -> UInt32 {
  let mut tid = 0U
  for g in type_groups {
    if !g.explicit_rec && g.subtypes.length() == 1 {
      let st = g.subtypes[0]
      if st.is_final && !st.explicit_sub && st.supers.is_empty() {
        if st.comp == Func(params, results) {
          return tid
        }
      }
    }
    tid += g.subtypes.length().reinterpret_as_uint()
  }
  type_groups.push({
    explicit_rec: false,
    subtypes: [
      {
        is_final: true,
        explicit_sub: false,
        supers: [],
        comp: Func(params, results),
      },
    ],
  })
  tid
}

///|
/// Pass 14: Conservative internal Dead Argument Elimination (DAE) and uniform constant argument propagation.
/// Operates exclusively on strictly internal functions (never exported, never in tables/RefFunc/ReturnCall/start).
pub fn pass_dae(mod : WasmModule) -> WasmModule {
  if mod.codes.length() < 2 {
    return mod
  }
  let imp_funcs = mod.imported_func_count()
  let flat_types = mod.flat_types()

  // Collect call counts and externally/indirectly retained functions
  let call_counts : Map[UInt32, Int32] = Map([])
  let retained : Map[UInt32, Bool] = Map([])
  for exp in mod.exports {
    if exp.kind == Func {
      retained[exp.idx] = true
    }
  }
  match mod.start_func {
    Some(f) => retained[f] = true
    None => ()
  }
  for tt in mod.tables {
    match tt.init_expr {
      Some(ex) => collect_init_ref_funcs(ex, retained)
      None => ()
    }
  }
  for gd in mod.globals {
    collect_init_ref_funcs(gd.init, retained)
  }
  for el in mod.elements {
    for f in el.func_indices {
      retained[f] = true
    }
    for ex in el.init_exprs {
      collect_init_ref_funcs(ex, retained)
    }
  }
  for fb in mod.codes {
    let edges : Map[UInt32, Bool] = Map([])
    collect_direct_calls_and_refs(fb.body, call_counts, edges, retained)
  }

  let internal_param_counts : Map[UInt32, Int32] = Map([])
  for i in 0..<mod.codes.length() {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    if !retained.contains(fidx) && call_counts.get(fidx).unwrap_or(0) > 0 {
      let tidx = mod.func_types[i].reinterpret_as_int()
      if tidx >= 0 && tidx < flat_types.length() {
        match flat_types[tidx].comp {
          Func(ps, _) if !ps.is_empty() =>
            internal_param_counts[fidx] = ps.length()
          _ => ()
        }
      }
    }
  }
  if internal_param_counts.is_empty() {
    return mod
  }

  // Phase A: Scan uniform constant trailing arguments at all direct call sites
  let arg_states : Map[UInt32, Array[ArgConstState]] = Map([])
  for fb in mod.codes {
    scan_call_arg_consts(fb.body, internal_param_counts, arg_states)
  }

  let working_codes : Array[FuncBody] = []
  let mut changed = false
  for i, fb in mod.codes {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    match arg_states.get(fidx) {
      Some(states) => {
        let repl : Map[UInt32, Instr] = Map([])
        let p_last = states.length() - 1
        for pi, st in states {
          match st {
            ConstVal(c_ins) => {
              let p_u32 = pi.reinterpret_as_uint()
              if !body_sets_local(fb.body, p_u32) {
                let c_sz = instr_encoded_size(c_ins)
                let g_sz = instr_encoded_size(LocalGet(p_u32))
                // Always propagate if size-neutral OR if it unlocks pruning the trailing parameter
                if c_sz <= g_sz || pi == p_last {
                  repl[p_u32] = c_ins
                }
              }
            }
            _ => ()
          }
        }
        if !repl.is_empty() {
          let nb = replace_const_params_in_instrs(fb.body, repl)
          if nb != fb.body {
            changed = true
            working_codes.push({ locals: fb.locals, body: nb, })
            continue
          }
        }
        working_codes.push(fb)
      }
      None => working_codes.push(fb)
    }
  }

  // Phase B: Prune trailing unused parameter on strictly internal non-self-recursive functions
  let new_type_groups : Array[RecGroup] = []
  for g in mod.type_groups {
    new_type_groups.push(g)
  }
  let new_func_types : Array[UInt32] = []
  for t in mod.func_types {
    new_func_types.push(t)
  }
  let pruned_funcs : Map[UInt32, Bool] = Map([])

  for i, fb in working_codes {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    guard internal_param_counts.get(fidx) is Some(pcnt) else { continue }
    let tidx = new_func_types[i].reinterpret_as_int()
    if tidx < 0 || tidx >= flat_types.length() {
      continue
    }
    let (ps, rs) = match flat_types[tidx].comp {
      Func(ps, rs) => (ps, rs)
      _ => continue
    }
    let last_p = (pcnt - 1).reinterpret_as_uint()
    let uses : Map[UInt32, Int32] = Map([])
    count_local_uses(fb.body, uses)
    if uses.get(last_p).unwrap_or(0) == 0 {
      let trimmed_ps : Array[ValType] = []
      for k in 0..<(pcnt - 1) {
        trimmed_ps.push(ps[k])
      }
      let new_tidx = find_or_add_func_type(new_type_groups, trimmed_ps, rs)
      new_func_types[i] = new_tidx
      working_codes[i] = {
        locals: fb.locals,
        body: shift_locals_above(fb.body, pcnt.reinterpret_as_uint()),
      }
      pruned_funcs[fidx] = true
      changed = true
    }
  }

  if !changed {
    return mod
  }

  let final_codes = if pruned_funcs.is_empty() {
    working_codes
  } else {
    working_codes.map(fb => {
      locals: fb.locals,
      body: insert_drop_before_calls(fb.body, pruned_funcs),
    })
  }

  {
    ..mod,
    type_groups: new_type_groups,
    func_types: new_func_types,
    codes: final_codes,
  }
}
