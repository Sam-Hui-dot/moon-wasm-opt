///|
fn is_scalar_select_valtype(vt : ValType) -> Bool {
  match vt {
    I32 | I64 | F32 | F64 => true
    _ => false
  }
}

///|
fn is_select_reorder_safe(ins : Instr) -> Bool {
  match ins {
    I32Const(_)
    | I64Const(_)
    | F32Const(_)
    | F64Const(_)
    | LocalGet(_)
    | GlobalGet(_) => true
    _ => false
  }
}

///|
fn is_guaranteed_bool_producer(ins : Instr) -> Bool {
  match ins {
    NumOp(op) => is_bool_result_op(op)
    RefIsNull | RefEq | RefTest(_) | RefTestNull(_) => true
    _ => false
  }
}

///|
fn is_same_type_unary_op(op : Byte, vt : ValType) -> Bool {
  let b = op.to_int()
  match vt {
    I32 =>
      b == 0x45 || b == 0x67 || b == 0x68 || b == 0x69 || b == 0xC0 || b == 0xC1
    I64 =>
      b == 0x79 || b == 0x7A || b == 0x7B || b == 0xC2 || b == 0xC3 || b == 0xC4
    F32 => b >= 0x8B && b <= 0x91
    F64 => b >= 0x99 && b <= 0x9F
    _ => false
  }
}

///|
fn is_non_trapping_same_type_binop(op : Byte, vt : ValType) -> Bool {
  let b = op.to_int()
  match vt {
    I32 => b == 0x6A || b == 0x6B || b == 0x6C || (b >= 0x71 && b <= 0x78)
    I64 => b == 0x7C || b == 0x7D || b == 0x7E || (b >= 0x83 && b <= 0x8A)
    F32 => b == 0x92 || b == 0x93 || b == 0x94 || b == 0x96 || b == 0x97
    F64 => b == 0xA0 || b == 0xA1 || b == 0xA2 || b == 0xA4 || b == 0xA5
    _ => false
  }
}

///|
fn const_matches_valtype(ins : Instr, vt : ValType) -> Bool {
  match (ins, vt) {
    (I32Const(_), I32)
    | (I64Const(_), I64)
    | (F32Const(_), F32)
    | (F64Const(_), F64) => true
    _ => false
  }
}

///|
fn pop_last_n(arr : Array[Instr], n : Int32) -> Array[Instr] {
  let keep = arr.length() - n
  Array::makei(keep, i => arr[i])
}

///|
fn fold_if_branches(
  bt : BlockType,
  t_in : Array[Instr],
  e_in : Array[Instr],
  local_types : Array[ValType],
  global_types : Array[ValType],
) -> (BlockType, Array[Instr], Array[Instr], Array[Instr])? {
  if t_in.is_empty() || e_in.is_empty() {
    return None
  }
  if instrs_branch_to_depth(t_in, 0U) || instrs_branch_to_depth(e_in, 0U) {
    return None
  }
  let mut cur_bt = bt
  let mut cur_t = t_in
  let mut cur_e = e_in
  let hoisted_rev : Array[Instr] = []

  while !cur_t.is_empty() && !cur_e.is_empty() {
    let tn = cur_t.length()
    let en = cur_e.length()
    let t_last = cur_t[tn - 1]
    let e_last = cur_e[en - 1]

    if cur_bt == Empty {
      match (t_last, e_last) {
        (LocalSet(x), LocalSet(y)) if x == y => {
          let xi = x.reinterpret_as_int()
          if xi >= 0 && xi < local_types.length() {
            cur_bt = Val(local_types[xi])
            cur_t = pop_last_n(cur_t, 1)
            cur_e = pop_last_n(cur_e, 1)
            hoisted_rev.push(LocalSet(x))
            continue
          }
        }
        (GlobalSet(g), GlobalSet(h)) if g == h => {
          let gi = g.reinterpret_as_int()
          if gi >= 0 && gi < global_types.length() {
            cur_bt = Val(global_types[gi])
            cur_t = pop_last_n(cur_t, 1)
            cur_e = pop_last_n(cur_e, 1)
            hoisted_rev.push(GlobalSet(g))
            continue
          }
        }
        _ => ()
      }
      break
    }

    match cur_bt {
      Val(vt) => {
        if t_last == e_last {
          match t_last {
            NumOp(op) if is_same_type_unary_op(op, vt) => {
              cur_t = pop_last_n(cur_t, 1)
              cur_e = pop_last_n(cur_e, 1)
              hoisted_rev.push(NumOp(op))
              continue
            }
            RefAsNonNull => {
              cur_t = pop_last_n(cur_t, 1)
              cur_e = pop_last_n(cur_e, 1)
              hoisted_rev.push(RefAsNonNull)
              continue
            }
            _ => ()
          }
        }
        if tn >= 2 && en >= 2 {
          let t_prev = cur_t[tn - 2]
          let e_prev = cur_e[en - 2]
          if t_last == e_last && t_prev == e_prev {
            match t_last {
              NumOp(op) if is_non_trapping_same_type_binop(op, vt) &&
                const_matches_valtype(t_prev, vt) => {
                cur_t = pop_last_n(cur_t, 2)
                cur_e = pop_last_n(cur_e, 2)
                hoisted_rev.push(t_last)
                hoisted_rev.push(t_prev)
                continue
              }
              _ => ()
            }
          }
        }
        break
      }
      _ => break
    }
  }

  if hoisted_rev.is_empty() {
    None
  } else {
    let hoisted : Array[Instr] = []
    let mut k = hoisted_rev.length() - 1
    while k >= 0 {
      hoisted.push(hoisted_rev[k])
      k -= 1
    }
    Some((cur_bt, cur_t, cur_e, hoisted))
  }
}

///|
fn code_fold_seq(
  instrs : Array[Instr],
  local_types : Array[ValType],
  global_types : Array[ValType],
) -> Array[Instr] {
  let out : Array[Instr] = []
  let mut changed = false

  for raw_ins in instrs {
    match raw_ins {
      Block(bt, b) => {
        let nb = code_fold_seq(b, local_types, global_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, b) => {
        let nb = code_fold_seq(b, local_types, global_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Loop(bt, nb))
      }
      TryTable(bt, cs, b) => {
        let nb = code_fold_seq(b, local_types, global_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(TryTable(bt, cs, nb))
      }
      If(bt, then_b, else_b) => {
        let nt0 = code_fold_seq(then_b, local_types, global_types)
        let ne0 = code_fold_seq(else_b, local_types, global_types)
        if !physical_equal(nt0, then_b) || !physical_equal(ne0, else_b) {
          changed = true
        }
        let (eff_bt, eff_t, eff_e, hoisted) = match
          fold_if_branches(bt, nt0, ne0, local_types, global_types) {
          Some(tuple) => {
            changed = true
            tuple
          }
          None => (bt, nt0, ne0, [])
        }

        // Special boolean fold & pure If -> Select reduction
        let mut emitted = false
        match eff_bt {
          Val(vt) if eff_t.length() == 1 && eff_e.length() == 1 => {
            let v1 = eff_t[0]
            let v2 = eff_e[0]
            if vt == I32 &&
              !out.is_empty() &&
              is_guaranteed_bool_producer(out[out.length() - 1]) {
              match (v1, v2) {
                (I32Const(1), I32Const(0)) => {
                  changed = true
                  emitted = true
                }
                (I32Const(0), I32Const(1)) => {
                  out.push(NumOp(b'\x45'))
                  changed = true
                  emitted = true
                }
                _ => ()
              }
            }
            if !emitted &&
              is_scalar_select_valtype(vt) &&
              is_select_reorder_safe(v1) &&
              is_select_reorder_safe(v2) &&
              !out.is_empty() &&
              is_select_reorder_safe(out[out.length() - 1]) {
              let cond = out.unsafe_pop()
              out.push(v1)
              out.push(v2)
              out.push(cond)
              out.push(Select)
              changed = true
              emitted = true
            }
          }
          _ => ()
        }

        if !emitted {
          if eff_t.is_empty() && eff_e.is_empty() && eff_bt == Empty {
            out.push(Drop)
            changed = true
          } else {
            out.push(If(eff_bt, eff_t, eff_e))
          }
        }
        for h in hoisted {
          out.push(h)
        }
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
fn pass_code_folding_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let flat_types = mod.flat_types()
  let global_types = build_all_global_types(mod)
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      let local_types = match build_func_local_types(mod, i, flat_types) {
        Some((_, lts)) => lts
        None => []
      }
      let nb = code_fold_seq(fb.body, local_types, global_types)
      if !physical_equal(nb, fb.body) && nb != fb.body {
        let cand : FuncBody = { locals: fb.locals, body: nb, }
        if encode_func_body(cand).length() <= encode_func_body(fb).length() {
          changed = true
          out_changed[i] = true
          new_codes.push(cand)
          continue
        }
      }
    }
    new_codes.push(fb)
  }

  if !changed {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 15: Cross-branch `If`/`Else` tail hoisting (`LocalSet`, `GlobalSet`, common unary/binary-const tails)
/// and validator-sound pure `If -> Select` reduction.
pub fn pass_code_folding(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_code_folding_dirty(mod, None)
  next
}
