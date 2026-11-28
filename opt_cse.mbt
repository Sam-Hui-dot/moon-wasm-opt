///|
/// Pass 19: Intra-block expression-level Local CSE / Store-to-Load Forwarding
/// Replaces repeated pure 2- and 3-instruction expressions (such as pointer offset
/// calculations, immutable struct field loads, or repeated memory loads without
/// intervening stores) with a single `local.get` when an existing local already holds
/// the exact value — allocating zero new locals and strictly reducing code size.
priv struct AvailExpr {
  local_idx : UInt32
  dep_local1 : Int32
  dep_local2 : Int32
  reads_mem : Bool
  reads_mut_global : Bool
  reads_mut_heap : Bool
}

///|
fn is_pure_cse_binop(op : Byte) -> Bool {
  let b = op.to_int()
  // Pure non-trapping i32/i64/f32/f64 binops & comparisons
  (b >= 0x46 && b <= 0x66) ||
  b == 0x6A ||
  b == 0x6B ||
  b == 0x6C ||
  (b >= 0x71 && b <= 0x78) ||
  b == 0x7C ||
  b == 0x7D ||
  b == 0x7E ||
  (b >= 0x83 && b <= 0x8A)
}

///|
fn is_pure_cse_unop(op : Byte) -> Bool {
  let b = op.to_int()
  b == 0x45 ||
  b == 0x50 ||
  b == 0x67 ||
  b == 0x68 ||
  b == 0x69 ||
  b == 0x79 ||
  b == 0x7A ||
  b == 0x7B ||
  b == 0xA7 ||
  b == 0xAC ||
  b == 0xAD ||
  b == 0xC0 ||
  b == 0xC1 ||
  b == 0xC2 ||
  b == 0xC3 ||
  b == 0xC4
}

///|
fn is_mem_load_op(op : Byte) -> Bool {
  let b = op.to_int()
  b >= 0x28 && b <= 0x35
}

///|
fn is_mem_store_op(op : Byte) -> Bool {
  let b = op.to_int()
  b >= 0x36 && b <= 0x3E
}

///|
fn cse_atom_key(
  ins : Instr,
  mut_globals : Set[UInt32],
) -> (String, Int32, Bool)? {
  match ins {
    LocalGet(l) => Some(("L\{l}", l.reinterpret_as_int(), false))
    I32Const(v) => Some(("I32:\{v}", -1, false))
    I64Const(v) => Some(("I64:\{v}", -1, false))
    GlobalGet(g) => Some(("G\{g}", -1, mut_globals.contains(g)))
    _ => None
  }
}

///|
fn cse_struct_field_mutable(
  flat_types : Array[SubType],
  tid : UInt32,
  fid : UInt32,
) -> Bool {
  let ti = tid.reinterpret_as_int()
  let fi = fid.reinterpret_as_int()
  if ti >= 0 && ti < flat_types.length() {
    match flat_types[ti].comp {
      Struct(fs) if fi >= 0 && fi < fs.length() => fs[fi].mutable
      _ => true
    }
  } else {
    true
  }
}

///|
fn match_cse_expr2(
  a : Instr,
  b : Instr,
  mut_globals : Set[UInt32],
  flat_types : Array[SubType],
) -> (String, Int32, Bool, Bool, Bool)? {
  match cse_atom_key(a, mut_globals) {
    Some((ak, dl, rmg)) =>
      match b {
        NumOp(op) if is_pure_cse_unop(op) =>
          Some(("U(\{op.to_int()},\{ak})", dl, false, rmg, false))
        MemOp(op, ma) if is_mem_load_op(op) =>
          Some(
            (
              "ML(\{op.to_int()},\{ma.mem_idx},\{ma.offset},\{ak})",
              dl,
              true,
              rmg,
              false,
            ),
          )
        StructGet(tid, fid) =>
          Some(
            (
              "SG(\{tid},\{fid},\{ak})",
              dl,
              false,
              rmg,
              cse_struct_field_mutable(flat_types, tid, fid),
            ),
          )
        StructGetS(tid, fid) =>
          Some(
            (
              "SGS(\{tid},\{fid},\{ak})",
              dl,
              false,
              rmg,
              cse_struct_field_mutable(flat_types, tid, fid),
            ),
          )
        StructGetU(tid, fid) =>
          Some(
            (
              "SGU(\{tid},\{fid},\{ak})",
              dl,
              false,
              rmg,
              cse_struct_field_mutable(flat_types, tid, fid),
            ),
          )
        ArrayLen => Some(("AL(\{ak})", dl, false, rmg, false))
        I31GetS => Some(("I31S(\{ak})", dl, false, rmg, false))
        I31GetU => Some(("I31U(\{ak})", dl, false, rmg, false))
        _ => None
      }
    None => None
  }
}

///|
fn match_cse_expr3(
  a : Instr,
  b : Instr,
  c : Instr,
  mut_globals : Set[UInt32],
) -> (String, Int32, Int32, Bool)? {
  match (cse_atom_key(a, mut_globals), cse_atom_key(b, mut_globals), c) {
    (Some((ak, dl1, rmg1)), Some((bk, dl2, rmg2)), NumOp(op)) if is_pure_cse_binop(
        op,
      ) => Some(("B(\{op.to_int()},\{ak},\{bk})", dl1, dl2, rmg1 || rmg2))
    _ => None
  }
}

///|
fn invalidate_cse_local(avail : Map[String, AvailExpr], loc : UInt32) -> Unit {
  let li = loc.reinterpret_as_int()
  let dead : Array[String] = []
  for k, v in avail {
    if v.local_idx == loc || v.dep_local1 == li || v.dep_local2 == li {
      dead.push(k)
    }
  }
  for k in dead {
    avail.remove(k)
  }
}

///|
fn invalidate_cse_effects(
  avail : Map[String, AvailExpr],
  kill_mem : Bool,
  kill_mut_global : Bool,
  kill_mut_heap : Bool,
) -> Unit {
  if !kill_mem && !kill_mut_global && !kill_mut_heap {
    return
  }
  let dead : Array[String] = []
  for k, v in avail {
    if (kill_mem && v.reads_mem) ||
      (kill_mut_global && v.reads_mut_global) ||
      (kill_mut_heap && v.reads_mut_heap) {
      dead.push(k)
    }
  }
  for k in dead {
    avail.remove(k)
  }
}

///|
fn local_cse_seq(
  instrs : Array[Instr],
  mut_globals : Set[UInt32],
  flat_types : Array[SubType],
) -> Array[Instr] {
  let out : Array[Instr] = []
  let avail : Map[String, AvailExpr] = Map([])
  let mut changed = false

  for raw_ins in instrs {
    match raw_ins {
      Block(bt, b) => {
        let nb = local_cse_seq(b, mut_globals, flat_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Block(bt, nb))
        avail.clear()
      }
      Loop(bt, b) => {
        let nb = local_cse_seq(b, mut_globals, flat_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Loop(bt, nb))
        avail.clear()
      }
      If(bt, t, e) => {
        let nt = local_cse_seq(t, mut_globals, flat_types)
        let ne = local_cse_seq(e, mut_globals, flat_types)
        if !physical_equal(nt, t) || !physical_equal(ne, e) {
          changed = true
        }
        out.push(If(bt, nt, ne))
        avail.clear()
      }
      TryTable(bt, cs, b) => {
        let nb = local_cse_seq(b, mut_globals, flat_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(TryTable(bt, cs, nb))
        avail.clear()
      }
      LocalSet(dst) | LocalTee(dst) => {
        // Before invalidating `dst`, check if the preceding 3 or 2 instructions form a cacheable pure expression
        let n = out.length()
        let mut recorded : (String, AvailExpr)? = None
        if n >= 3 {
          match
            match_cse_expr3(out[n - 3], out[n - 2], out[n - 1], mut_globals) {
            Some((k, dl1, dl2, rmg)) =>
              if dl1 != dst.reinterpret_as_int() &&
                dl2 != dst.reinterpret_as_int() {
                recorded = Some(
                  (
                    k,
                    {
                      local_idx: dst,
                      dep_local1: dl1,
                      dep_local2: dl2,
                      reads_mem: false,
                      reads_mut_global: rmg,
                      reads_mut_heap: false,
                    },
                  ),
                )
              }
            None => ()
          }
        }
        if recorded is None && n >= 2 {
          match
            match_cse_expr2(out[n - 2], out[n - 1], mut_globals, flat_types) {
            Some((k, dl1, rmem, rmg, rmh)) =>
              if dl1 != dst.reinterpret_as_int() {
                recorded = Some(
                  (
                    k,
                    {
                      local_idx: dst,
                      dep_local1: dl1,
                      dep_local2: -1,
                      reads_mem: rmem,
                      reads_mut_global: rmg,
                      reads_mut_heap: rmh,
                    },
                  ),
                )
              }
            None => ()
          }
        }
        out.push(raw_ins)
        invalidate_cse_local(avail, dst)
        match recorded {
          Some((k, ae)) => avail[k] = ae
          None => ()
        }
      }
      _ => {
        out.push(raw_ins)
        // Check if the newly completed 3- or 2-instruction suffix matches an already-available local
        let mut matched = false
        let n = out.length()
        if n >= 3 {
          match
            match_cse_expr3(out[n - 3], out[n - 2], out[n - 1], mut_globals) {
            Some((k, _, _, _)) =>
              match avail.get(k) {
                Some(ae) => {
                  ignore(out.pop())
                  ignore(out.pop())
                  ignore(out.pop())
                  out.push(LocalGet(ae.local_idx))
                  changed = true
                  matched = true
                }
                None => ()
              }
            None => ()
          }
        }
        if !matched && n >= 2 {
          match
            match_cse_expr2(out[n - 2], out[n - 1], mut_globals, flat_types) {
            Some((k, _, _, _, _)) =>
              match avail.get(k) {
                Some(ae) => {
                  ignore(out.pop())
                  ignore(out.pop())
                  out.push(LocalGet(ae.local_idx))
                  changed = true
                  matched = true
                }
                None => ()
              }
            None => ()
          }
        }
        // Invalidate side-effecting instructions
        if !matched {
          match raw_ins {
            Call(_)
            | CallIndirect(_, _)
            | CallRef(_)
            | ReturnCall(_)
            | ReturnCallIndirect(_, _)
            | ReturnCallRef(_) =>
              invalidate_cse_effects(avail, true, true, true)
            GlobalSet(_) => invalidate_cse_effects(avail, false, true, false)
            MemOp(op, _) if is_mem_store_op(op) =>
              invalidate_cse_effects(avail, true, false, false)
            MemoryGrow(_)
            | MemoryCopy(_, _)
            | MemoryFill(_)
            | MemoryInit(_, _) =>
              invalidate_cse_effects(avail, true, false, false)
            StructSet(_, _)
            | ArraySet(_)
            | ArrayFill(_)
            | ArrayCopy(_, _)
            | ArrayInitData(_, _)
            | ArrayInitElem(_, _) =>
              invalidate_cse_effects(avail, false, false, true)
            Br(_)
            | BrIf(_)
            | BrTable(_, _)
            | Return
            | Unreachable
            | Throw(_)
            | ThrowRef => avail.clear()
            _ => ()
          }
        }
      }
    }
  }

  if !changed {
    instrs
  } else {
    out
  }
}

///|
fn build_mutable_global_set(mod : WasmModule) -> Set[UInt32] {
  let s : Set[UInt32] = Set([])
  let mut idx = 0U
  for imp in mod.imports {
    match imp.desc {
      Global(gt) => {
        if gt.mutable {
          s.insert(idx)
        }
        idx += 1U
      }
      _ => ()
    }
  }
  for g in mod.globals {
    if g.global_type.mutable {
      s.insert(idx)
    }
    idx += 1U
  }
  s
}

///|
fn pass_local_cse_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let mut_globals = build_mutable_global_set(mod)
  let flat_types = mod.flat_types()
  let new_codes : Array[FuncBody] = []
  let mut any = false

  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      let nb = local_cse_seq(fb.body, mut_globals, flat_types)
      if !physical_equal(nb, fb.body) && nb != fb.body {
        any = true
        out_changed[i] = true
        new_codes.push({ locals: fb.locals, body: nb, })
        continue
      }
    }
    new_codes.push(fb)
  }
  if !any {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 19: Intra-block expression-level Local CSE & store-to-load forwarding.
pub fn pass_local_cse(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_local_cse_dirty(mod, None)
  next
}
