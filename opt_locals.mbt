///|
fn count_local_uses(instrs : Array[Instr], counts : Map[UInt32, Int32]) -> Unit {
  for ins in instrs {
    match ins {
      LocalGet(l) | LocalSet(l) | LocalTee(l) =>
        counts[l] = counts.get(l).unwrap_or(0) + 1
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        count_local_uses(b, counts)
      If(_, t, e) => {
        count_local_uses(t, counts)
        count_local_uses(e, counts)
      }
      _ => ()
    }
  }
}

///|
fn remap_locals_in_instrs(
  instrs : Array[Instr],
  remap : Map[UInt32, UInt32],
) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      LocalGet(l) => LocalGet(remap.get(l).unwrap_or(l))
      LocalSet(l) => LocalSet(remap.get(l).unwrap_or(l))
      LocalTee(l) => LocalTee(remap.get(l).unwrap_or(l))
      Block(bt, b) => Block(bt, remap_locals_in_instrs(b, remap))
      Loop(bt, b) => Loop(bt, remap_locals_in_instrs(b, remap))
      If(bt, t, e) =>
        If(
          bt,
          remap_locals_in_instrs(t, remap),
          remap_locals_in_instrs(e, remap),
        )
      TryTable(bt, c, b) => TryTable(bt, c, remap_locals_in_instrs(b, remap))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn val_type_order_key(vt : ValType) -> String {
  format_val_type(vt)
}

///|
fn lex_cmp_str(a : String, b : String) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let ca = a.code_unit_at(i)
    let cb = b.code_unit_at(i)
    if ca != cb {
      return ca.compare(cb)
    }
  }
  a.length().compare(b.length())
}

///|
fn optimize_func_locals(fb : FuncBody, param_count : UInt32) -> FuncBody {
  if fb.locals.is_empty() {
    return fb
  }
  let counts : Map[UInt32, Int32] = Map([])
  count_local_uses(fb.body, counts)

  // Expand non-param locals into (old_idx, val_type, use_count)
  let used : Array[(UInt32, ValType, Int32)] = []
  let mut idx = param_count
  for lg in fb.locals {
    let n = lg.count.reinterpret_as_int()
    for _ in 0..<n {
      let c = counts.get(idx).unwrap_or(0)
      if c > 0 {
        used.push((idx, lg.val_type, c))
      }
      idx += 1U
    }
  }

  if used.is_empty() {
    return { locals: [], body: fb.body, }
  }

  // Partition into hot (<128 index budget for 1-byte LEB128) and cold, then group by ValType
  // to minimize BOTH LEB128 operand bytes AND LocalGroup declaration header entries!
  used.sort_by((a, b) => {
    let cc = b.2.compare(a.2)
    if cc != 0 {
      cc
    } else {
      a.0.compare(b.0)
    }
  })

  let budget = 128 - param_count.reinterpret_as_int()
  let hot_cut = if budget > 0 && used.length() > budget {
    budget
  } else {
    used.length()
  }
  let hot : Array[(UInt32, ValType, Int32)] = []
  let cold : Array[(UInt32, ValType, Int32)] = []
  for i, item in used {
    if i < hot_cut {
      hot.push(item)
    } else {
      cold.push(item)
    }
  }
  // Within hot and cold tiers, group identical ValTypes together for minimal LocalGroup encoding
  hot.sort_by((a, b) => {
    let tc = lex_cmp_str(val_type_order_key(a.1), val_type_order_key(b.1))
    if tc != 0 {
      tc
    } else {
      b.2.compare(a.2)
    }
  })
  cold.sort_by((a, b) => {
    let tc = lex_cmp_str(val_type_order_key(a.1), val_type_order_key(b.1))
    if tc != 0 {
      tc
    } else {
      b.2.compare(a.2)
    }
  })

  let ordered : Array[(UInt32, ValType, Int32)] = []
  for x in hot {
    ordered.push(x)
  }
  for x in cold {
    ordered.push(x)
  }

  let remap : Map[UInt32, UInt32] = Map([])
  let new_groups : Array[LocalGroup] = []
  let mut next_idx = param_count
  let mut changed = false
  for item in ordered {
    let (old_idx, vt, _) = item
    remap[old_idx] = next_idx
    if old_idx != next_idx {
      changed = true
    }
    next_idx += 1U
    if !new_groups.is_empty() &&
      new_groups[new_groups.length() - 1].val_type == vt {
      let last = new_groups[new_groups.length() - 1]
      new_groups[new_groups.length() - 1] = {
        count: last.count + 1U,
        val_type: vt,
      }
    } else {
      new_groups.push({ count: 1U, val_type: vt, })
    }
  }

  let new_body = if changed {
    remap_locals_in_instrs(fb.body, remap)
  } else {
    fb.body
  }
  let candidate : FuncBody = { locals: new_groups, body: new_body, }
  if encode_func_body(candidate).length() < encode_func_body(fb).length() {
    candidate
  } else {
    fb
  }
}

///|
/// Pass 4: Remove unused locals, prioritize hot locals into 1-byte LEB128 slots, and coalesce LocalGroups by type.
pub fn pass_local_opt(mod : WasmModule) -> WasmModule {
  let imp_cnt = mod.imported_func_count()
  let new_codes : Array[FuncBody] = []
  for i, fb in mod.codes {
    let fidx = imp_cnt + i.reinterpret_as_uint()
    let pcnt = mod.func_param_count(fidx)
    new_codes.push(optimize_func_locals(fb, pcnt))
  }
  { ..mod, codes: new_codes, }
}
