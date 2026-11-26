///|
fn is_unconditional_terminator(ins : Instr) -> Bool {
  match ins {
    Unreachable
    | Return
    | Br(_)
    | BrTable(_, _)
    | ReturnCall(_)
    | ReturnCallIndirect(_, _)
    | ReturnCallRef(_)
    | Throw(_)
    | ThrowRef => true
    _ => false
  }
}

///|
fn is_pure_single_push(ins : Instr) -> Bool {
  match ins {
    I32Const(_)
    | I64Const(_)
    | F32Const(_)
    | F64Const(_)
    | LocalGet(_)
    | GlobalGet(_)
    | RefNull(_)
    | RefFunc(_)
    | MemorySize(_)
    | TableSize(_) => true
    _ => false
  }
}

///|
fn instrs_branch_to_depth(instrs : Array[Instr], target : UInt32) -> Bool {
  for ins in instrs {
    match ins {
      Br(l) | BrIf(l) | BrOnNull(l) | BrOnNonNull(l) =>
        if l == target {
          return true
        }
      BrOnCast(_, l, _, _) | BrOnCastFail(_, l, _, _) =>
        if l == target {
          return true
        }
      BrTable(ts, d) => {
        if d == target {
          return true
        }
        for t in ts {
          if t == target {
            return true
          }
        }
      }
      Block(_, body) | Loop(_, body) =>
        if instrs_branch_to_depth(body, target + 1U) {
          return true
        }
      If(_, t, e) =>
        if instrs_branch_to_depth(t, target + 1U) ||
          instrs_branch_to_depth(e, target + 1U) {
          return true
        }
      TryTable(_, catches, body) => {
        for c in catches {
          let lbl = match c {
            Catch(_, l) | CatchRef(_, l) | CatchAll(l) | CatchAllRef(l) => l
          }
          if lbl == target {
            return true
          }
        }
        if instrs_branch_to_depth(body, target + 1U) {
          return true
        }
      }
      _ => ()
    }
  }
  false
}

///|
fn dec_branch_depths(instrs : Array[Instr], min_depth : UInt32) -> Array[Instr] {
  let out : Array[Instr] = []
  fn adj(l : UInt32) -> UInt32 {
    if l >= min_depth {
      l - 1U
    } else {
      l
    }
  }
  for ins in instrs {
    let rewritten : Instr = match ins {
      Br(l) => Br(adj(l))
      BrIf(l) => BrIf(adj(l))
      BrOnNull(l) => BrOnNull(adj(l))
      BrOnNonNull(l) => BrOnNonNull(adj(l))
      BrOnCast(f, l, h1, h2) => BrOnCast(f, adj(l), h1, h2)
      BrOnCastFail(f, l, h1, h2) => BrOnCastFail(f, adj(l), h1, h2)
      BrTable(ts, d) => BrTable(ts.map(adj), adj(d))
      Block(bt, body) => Block(bt, dec_branch_depths(body, min_depth + 1U))
      Loop(bt, body) => Loop(bt, dec_branch_depths(body, min_depth + 1U))
      If(bt, t, e) =>
        If(
          bt,
          dec_branch_depths(t, min_depth + 1U),
          dec_branch_depths(e, min_depth + 1U),
        )
      TryTable(bt, catches, body) => {
        let nc : Array[CatchClause] = []
        for c in catches {
          nc.push(
            match c {
              Catch(tg, l) => Catch(tg, adj(l))
              CatchRef(tg, l) => CatchRef(tg, adj(l))
              CatchAll(l) => CatchAll(adj(l))
              CatchAllRef(l) => CatchAllRef(adj(l))
            },
          )
        }
        TryTable(bt, nc, dec_branch_depths(body, min_depth + 1U))
      }
      other => other
    }
    out.push(rewritten)
  }
  out
}

///|
fn dce_instr_seq(instrs : Array[Instr]) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    match ins {
      Nop => continue
      Block(bt, body) => {
        let nb = dce_instr_seq(body)
        if nb.is_empty() && bt == Empty {
          continue
        }
        // Unwrap any block that has no branch targeting depth 0 (safe for Empty or single Val result).
        if !instrs_branch_to_depth(nb, 0U) {
          let unwrapped = dec_branch_depths(nb, 1U)
          for u in unwrapped {
            out.push(u)
            if is_unconditional_terminator(u) {
              return out
            }
          }
          continue
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, body) => {
        let nb = dce_instr_seq(body)
        if nb.is_empty() && bt == Empty {
          continue
        }
        if !instrs_branch_to_depth(nb, 0U) {
          let unwrapped = dec_branch_depths(nb, 1U)
          for u in unwrapped {
            out.push(u)
            if is_unconditional_terminator(u) {
              return out
            }
          }
          continue
        }
        out.push(Loop(bt, nb))
      }
      If(bt, then_b, else_b) => {
        let nt = dce_instr_seq(then_b)
        let ne = dce_instr_seq(else_b)
        if nt.is_empty() && ne.is_empty() && bt == Empty {
          out.push(Drop)
        } else {
          out.push(If(bt, nt, ne))
        }
      }
      TryTable(bt, catches, body) => {
        let nb = dce_instr_seq(body)
        out.push(TryTable(bt, catches, nb))
      }
      other => {
        out.push(other)
        if is_unconditional_terminator(other) {
          return out
        }
      }
    }
  }
  out
}

///|
/// Pass 2: Eliminate nops, unreachable trailing instructions, and redundant single-entry blocks.
pub fn pass_dce_instr(mod : WasmModule) -> WasmModule {
  let new_codes : Array[FuncBody] = []
  for fb in mod.codes {
    new_codes.push({ locals: fb.locals, body: dce_instr_seq(fb.body), })
  }
  { ..mod, codes: new_codes, }
}

///|
fn fold_i32_unary(a : Int32, op : Byte) -> Instr? {
  match op {
    b'\x45' => Some(I32Const(if a == 0 { 1 } else { 0 }))
    b'\xAC' => Some(I64Const(a.to_int64()))
    b'\xAD' =>
      Some(I64Const(a.reinterpret_as_uint().to_uint64().reinterpret_as_int64()))
    b'\xC0' => Some(I32Const(a << 24 >> 24))
    b'\xC1' => Some(I32Const(a << 16 >> 16))
    _ => None
  }
}

///|
fn fold_i64_unary(a : Int64, op : Byte) -> Instr? {
  match op {
    b'\x50' => Some(I32Const(if a == 0L { 1 } else { 0 }))
    b'\xA7' => Some(I32Const(a.to_int()))
    b'\xC2' => Some(I64Const(a << 56 >> 56))
    b'\xC3' => Some(I64Const(a << 48 >> 48))
    b'\xC4' => Some(I64Const(a << 32 >> 32))
    _ => None
  }
}

///|
fn fold_i32_binary(a : Int32, b : Int32, op : Byte) -> Instr? {
  let ua = a.reinterpret_as_uint()
  let ub = b.reinterpret_as_uint()
  let sh = (ub & 31U).reinterpret_as_int()
  match op {
    b'\x46' => Some(I32Const(if a == b { 1 } else { 0 }))
    b'\x47' => Some(I32Const(if a != b { 1 } else { 0 }))
    b'\x48' => Some(I32Const(if a < b { 1 } else { 0 }))
    b'\x49' => Some(I32Const(if ua < ub { 1 } else { 0 }))
    b'\x4A' => Some(I32Const(if a > b { 1 } else { 0 }))
    b'\x4B' => Some(I32Const(if ua > ub { 1 } else { 0 }))
    b'\x4C' => Some(I32Const(if a <= b { 1 } else { 0 }))
    b'\x4D' => Some(I32Const(if ua <= ub { 1 } else { 0 }))
    b'\x4E' => Some(I32Const(if a >= b { 1 } else { 0 }))
    b'\x4F' => Some(I32Const(if ua >= ub { 1 } else { 0 }))
    b'\x6A' => Some(I32Const((ua + ub).reinterpret_as_int()))
    b'\x6B' => Some(I32Const((ua - ub).reinterpret_as_int()))
    b'\x6C' => Some(I32Const((ua * ub).reinterpret_as_int()))
    b'\x6D' =>
      if b != 0 && !(a == -2147483648 && b == -1) {
        Some(I32Const(a / b))
      } else {
        None
      }
    b'\x6E' =>
      if ub != 0U {
        Some(I32Const((ua / ub).reinterpret_as_int()))
      } else {
        None
      }
    b'\x6F' =>
      if b != 0 && !(a == -2147483648 && b == -1) {
        Some(I32Const(a % b))
      } else {
        None
      }
    b'\x70' =>
      if ub != 0U {
        Some(I32Const((ua % ub).reinterpret_as_int()))
      } else {
        None
      }
    b'\x71' => Some(I32Const(a & b))
    b'\x72' => Some(I32Const(a | b))
    b'\x73' => Some(I32Const(a ^ b))
    b'\x74' => Some(I32Const((ua << sh).reinterpret_as_int()))
    b'\x75' => Some(I32Const(a >> sh))
    b'\x76' => Some(I32Const((ua >> sh).reinterpret_as_int()))
    _ => None
  }
}

///|
fn fold_i64_binary(a : Int64, b : Int64, op : Byte) -> Instr? {
  let ua = a.reinterpret_as_uint64()
  let ub = b.reinterpret_as_uint64()
  let sh = (ub & 63UL).to_int()
  match op {
    b'\x51' => Some(I32Const(if a == b { 1 } else { 0 }))
    b'\x52' => Some(I32Const(if a != b { 1 } else { 0 }))
    b'\x53' => Some(I32Const(if a < b { 1 } else { 0 }))
    b'\x54' => Some(I32Const(if ua < ub { 1 } else { 0 }))
    b'\x55' => Some(I32Const(if a > b { 1 } else { 0 }))
    b'\x56' => Some(I32Const(if ua > ub { 1 } else { 0 }))
    b'\x57' => Some(I32Const(if a <= b { 1 } else { 0 }))
    b'\x58' => Some(I32Const(if ua <= ub { 1 } else { 0 }))
    b'\x59' => Some(I32Const(if a >= b { 1 } else { 0 }))
    b'\x5A' => Some(I32Const(if ua >= ub { 1 } else { 0 }))
    b'\x7C' => Some(I64Const((ua + ub).reinterpret_as_int64()))
    b'\x7D' => Some(I64Const((ua - ub).reinterpret_as_int64()))
    b'\x7E' => Some(I64Const((ua * ub).reinterpret_as_int64()))
    b'\x83' => Some(I64Const(a & b))
    b'\x84' => Some(I64Const(a | b))
    b'\x85' => Some(I64Const(a ^ b))
    b'\x86' => Some(I64Const((ua << sh).reinterpret_as_int64()))
    b'\x87' => Some(I64Const(a >> sh))
    b'\x88' => Some(I64Const((ua >> sh).reinterpret_as_int64()))
    _ => None
  }
}

///|
fn is_i32_zero_identity(op : Byte) -> Bool {
  op == b'\x6A' ||
  op == b'\x6B' ||
  op == b'\x72' ||
  op == b'\x73' ||
  op == b'\x74' ||
  op == b'\x75' ||
  op == b'\x76'
}

///|
fn is_i64_zero_identity(op : Byte) -> Bool {
  op == b'\x7C' ||
  op == b'\x7D' ||
  op == b'\x84' ||
  op == b'\x85' ||
  op == b'\x86' ||
  op == b'\x87' ||
  op == b'\x88'
}

///|
fn peephole_seq(instrs : Array[Instr]) -> Array[Instr] {
  // Recursively optimize nested blocks first
  let staged : Array[Instr] = []
  for ins in instrs {
    match ins {
      Block(bt, b) => staged.push(Block(bt, peephole_seq(b)))
      Loop(bt, b) => staged.push(Loop(bt, peephole_seq(b)))
      If(bt, t, e) => staged.push(If(bt, peephole_seq(t), peephole_seq(e)))
      TryTable(bt, c, b) => staged.push(TryTable(bt, c, peephole_seq(b)))
      other => staged.push(other)
    }
  }

  // Stack-based sliding peephole rewriter (iterates to local fixpoint)
  let out : Array[Instr] = []
  for raw_ins in staged {
    out.push(raw_ins)
    let mut reduced = true
    while reduced && !out.is_empty() {
      reduced = false
      let n = out.length()
      // 4-instruction window: [pure v1, pure v2, i32.const c, select] -> [v1 or v2]
      if n >= 4 {
        match (out[n - 4], out[n - 3], out[n - 2], out[n - 1]) {
          (v1, v2, I32Const(c), Select)
          | (v1, v2, I32Const(c), SelectTyped(_)) =>
            if is_pure_single_push(v1) && is_pure_single_push(v2) {
              ignore(out.pop())
              ignore(out.pop())
              ignore(out.pop())
              ignore(out.pop())
              out.push(if c != 0 { v1 } else { v2 })
              reduced = true
              continue
            }
          _ => ()
        }
      }
      // 3-instruction window: binary constant folding
      if n >= 3 {
        match (out[n - 3], out[n - 2], out[n - 1]) {
          (I32Const(a), I32Const(b), NumOp(op)) =>
            match fold_i32_binary(a, b, op) {
              Some(folded) => {
                ignore(out.pop())
                ignore(out.pop())
                ignore(out.pop())
                out.push(folded)
                reduced = true
                continue
              }
              None => ()
            }
          (I64Const(a), I64Const(b), NumOp(op)) =>
            match fold_i64_binary(a, b, op) {
              Some(folded) => {
                ignore(out.pop())
                ignore(out.pop())
                ignore(out.pop())
                out.push(folded)
                reduced = true
                continue
              }
              None => ()
            }
          _ => ()
        }
      }
      // 2-instruction window: unary folds, algebraic identities, local/branch/WasmGC peepholes
      if n >= 2 {
        match (out[n - 2], out[n - 1]) {
          (I32Const(a), NumOp(op)) =>
            match fold_i32_unary(a, op) {
              Some(folded) => {
                ignore(out.pop())
                ignore(out.pop())
                out.push(folded)
                reduced = true
                continue
              }
              None =>
                if a == 0 && is_i32_zero_identity(op) {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                } else if a == 0 && op == b'\x46' {
                  // i32.const 0; i32.eq -> i32.eqz (saves 2 bytes)
                  ignore(out.pop())
                  ignore(out.pop())
                  out.push(NumOp(b'\x45'))
                  reduced = true
                  continue
                } else if a == 1 &&
                  (op == b'\x6C' || op == b'\x6D' || op == b'\x6E') {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                } else if a == -1 && op == b'\x71' {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                }
            }
          (I64Const(a), NumOp(op)) =>
            match fold_i64_unary(a, op) {
              Some(folded) => {
                ignore(out.pop())
                ignore(out.pop())
                out.push(folded)
                reduced = true
                continue
              }
              None =>
                if a == 0L && is_i64_zero_identity(op) {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                } else if a == 0L && op == b'\x51' {
                  // i64.const 0; i64.eq -> i64.eqz (saves 2 bytes)
                  ignore(out.pop())
                  ignore(out.pop())
                  out.push(NumOp(b'\x50'))
                  reduced = true
                  continue
                } else if a == 1L &&
                  (op == b'\x7E' || op == b'\x7F' || op == b'\x80') {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                } else if a == -1L && op == b'\x83' {
                  ignore(out.pop())
                  ignore(out.pop())
                  reduced = true
                  continue
                }
            }
          // Local peepholes
          (LocalSet(x), LocalGet(y)) if x == y => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(LocalTee(x))
            reduced = true
            continue
          }
          (LocalTee(x), Drop) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(LocalSet(x))
            reduced = true
            continue
          }
          (LocalGet(x), LocalSet(y)) if x == y => {
            ignore(out.pop())
            ignore(out.pop())
            reduced = true
            continue
          }
          (LocalTee(x), LocalSet(y)) if x == y => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(LocalSet(x))
            reduced = true
            continue
          }
          // Pure push followed by drop
          (prev, Drop) if is_pure_single_push(prev) => {
            ignore(out.pop())
            ignore(out.pop())
            reduced = true
            continue
          }
          // Constant condition branches & if-folding
          (I32Const(c), BrIf(lbl)) => {
            ignore(out.pop())
            ignore(out.pop())
            if c != 0 {
              out.push(Br(lbl))
            }
            reduced = true
            continue
          }
          (I32Const(c), If(bt, then_b, else_b)) => {
            ignore(out.pop())
            ignore(out.pop())
            let chosen = if c != 0 { then_b } else { else_b }
            out.push(Block(bt, chosen))
            reduced = true
            continue
          }
          // WasmGC non-null peepholes
          (RefAsNonNull, RefAsNonNull) => {
            ignore(out.pop())
            reduced = true
            continue
          }
          (StructNew(t), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(StructNew(t))
            reduced = true
            continue
          }
          (StructNewDefault(t), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(StructNewDefault(t))
            reduced = true
            continue
          }
          (ArrayNew(t), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(ArrayNew(t))
            reduced = true
            continue
          }
          (ArrayNewDefault(t), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(ArrayNewDefault(t))
            reduced = true
            continue
          }
          (ArrayNewFixed(t, len), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(ArrayNewFixed(t, len))
            reduced = true
            continue
          }
          (RefI31, RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(RefI31)
            reduced = true
            continue
          }
          _ => ()
        }
      }
    }
  }
  out
}

///|
/// Pass 3: Constant folding, algebraic identities, local.tee fusion, constant branch folding, and WasmGC peepholes.
pub fn pass_peephole(mod : WasmModule) -> WasmModule {
  let new_codes : Array[FuncBody] = []
  for fb in mod.codes {
    new_codes.push({ locals: fb.locals, body: peephole_seq(fb.body), })
  }
  { ..mod, codes: new_codes, }
}
