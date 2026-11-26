///|
fn default_const_for_valtype(vt : ValType) -> Instr? {
  match vt {
    I32 => Some(I32Const(0))
    I64 => Some(I64Const(0L))
    F32 => Some(F32Const(0U))
    F64 => Some(F64Const(0UL))
    RefNull(ht) => Some(RefNull(ht))
    ShortRef(b) =>
      if b == b'\x70' ||
        b == b'\x6F' ||
        b == b'\x6E' ||
        b == b'\x6D' ||
        b == b'\x6C' ||
        b == b'\x6B' ||
        b == b'\x6A' ||
        b == b'\x71' ||
        b == b'\x72' ||
        b == b'\x73' ||
        b == b'\x69' ||
        b == b'\x74' {
        Some(RefNull(Abstract(b)))
      } else {
        None
      }
    _ => None
  }
}

///|
fn expand_local_types(locals : Array[LocalGroup]) -> Array[ValType] {
  let out : Array[ValType] = []
  for lg in locals {
    let n = lg.count.reinterpret_as_int()
    for _ in 0..<n {
      out.push(lg.val_type)
    }
  }
  out
}

///|
fn compress_local_types(types : Array[ValType]) -> Array[LocalGroup] {
  let out : Array[LocalGroup] = []
  for vt in types {
    if !out.is_empty() && out[out.length() - 1].val_type == vt {
      let last = out[out.length() - 1]
      out[out.length() - 1] = { count: last.count + 1U, val_type: vt, }
    } else {
      out.push({ count: 1U, val_type: vt, })
    }
  }
  out
}

///|
fn body_has_return(instrs : Array[Instr]) -> Bool {
  for ins in instrs {
    match ins {
      Return => return true
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        if body_has_return(b) {
          return true
        }
      If(_, t, e) => if body_has_return(t) || body_has_return(e) { return true }
      _ => ()
    }
  }
  false
}

///|
fn body_has_forbidden_inline_ops(
  instrs : Array[Instr],
  self_fidx : UInt32,
) -> Bool {
  for ins in instrs {
    match ins {
      Call(f) => if f == self_fidx { return true }
      ReturnCall(_)
      | ReturnCallIndirect(_, _)
      | ReturnCallRef(_)
      | TryTable(_, _, _) => return true
      Block(_, b) | Loop(_, b) =>
        if body_has_forbidden_inline_ops(b, self_fidx) {
          return true
        }
      If(_, t, e) =>
        if body_has_forbidden_inline_ops(t, self_fidx) ||
          body_has_forbidden_inline_ops(e, self_fidx) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn collect_direct_calls_and_refs(
  instrs : Array[Instr],
  call_counts : Map[UInt32, Int32],
  direct_edges : Set[UInt32],
  retained : Set[UInt32],
) -> Unit {
  for ins in instrs {
    match ins {
      Call(f) => {
        call_counts[f] = call_counts.get(f).unwrap_or(0) + 1
        direct_edges.add(f)
      }
      ReturnCall(f) => {
        retained.add(f)
        direct_edges.add(f)
      }
      RefFunc(f) => retained.add(f)
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        collect_direct_calls_and_refs(b, call_counts, direct_edges, retained)
      If(_, t, e) => {
        collect_direct_calls_and_refs(t, call_counts, direct_edges, retained)
        collect_direct_calls_and_refs(e, call_counts, direct_edges, retained)
      }
      _ => ()
    }
  }
}

///|
fn collect_init_ref_funcs(
  instrs : Array[Instr],
  retained : Set[UInt32],
) -> Unit {
  for ins in instrs {
    match ins {
      RefFunc(f) => retained.add(f)
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        collect_init_ref_funcs(b, retained)
      If(_, t, e) => {
        collect_init_ref_funcs(t, retained)
        collect_init_ref_funcs(e, retained)
      }
      _ => ()
    }
  }
}

///|
fn can_reach_caller(
  start : UInt32,
  target : UInt32,
  call_graph : Map[UInt32, Set[UInt32]],
) -> Bool {
  let visited : Set[UInt32] = Set([])
  let stack : Array[UInt32] = [start]
  while !stack.is_empty() {
    let cur = stack.pop().unwrap()
    if cur == target {
      return true
    }
    if visited.contains(cur) {
      continue
    }
    visited.add(cur)
    match call_graph.get(cur) {
      Some(nexts) =>
        for nx in nexts {
          if !visited.contains(nx) {
            stack.push(nx)
          }
        }
      None => ()
    }
  }
  false
}

///|
fn rewrite_inlined_body(
  instrs : Array[Instr],
  local_remap : Map[UInt32, UInt32],
  depth : UInt32,
) -> Array[Instr] {
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      Return => Br(depth)
      LocalGet(l) => LocalGet(local_remap.get(l).unwrap_or(l))
      LocalSet(l) => LocalSet(local_remap.get(l).unwrap_or(l))
      LocalTee(l) => LocalTee(local_remap.get(l).unwrap_or(l))
      Block(bt, b) =>
        Block(bt, rewrite_inlined_body(b, local_remap, depth + 1U))
      Loop(bt, b) => Loop(bt, rewrite_inlined_body(b, local_remap, depth + 1U))
      If(bt, t, e) =>
        If(
          bt,
          rewrite_inlined_body(t, local_remap, depth + 1U),
          rewrite_inlined_body(e, local_remap, depth + 1U),
        )
      TryTable(bt, cs, b) =>
        TryTable(bt, cs, rewrite_inlined_body(b, local_remap, depth + 1U))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn body_uses_local_after_first(instrs : Array[Instr], target : UInt32) -> Bool {
  let counts : Map[UInt32, Int32] = Map([])
  count_local_uses(instrs, counts)
  counts.get(target).unwrap_or(0) > 1
}

///|
fn body_sets_local(instrs : Array[Instr], target : UInt32) -> Bool {
  for ins in instrs {
    match ins {
      LocalSet(l) | LocalTee(l) => if l == target { return true }
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        if body_sets_local(b, target) {
          return true
        }
      If(_, t, e) =>
        if body_sets_local(t, target) || body_sets_local(e, target) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn instrs_encoded_size(instrs : Array[Instr]) -> Int32 {
  let w = BinWriter::new()
  for ins in instrs {
    write_instr(w, ins)
  }
  w.to_bytes().length()
}

///|
priv struct InlineCandidate {
  params : Array[ValType]
  result_bt : BlockType
  non_param_locals : Array[ValType]
  body : Array[Instr]
  needs_block_wrap : Bool
  instr_count : Int32
  is_single_internal : Bool
  orig_body_bytes : Int32
}

///|
/// Pass 8: Size-aware function inliner for single-use internal helpers and zero-overhead tiny wrappers.
/// Preserves Wasm 2.0 + WasmGC loop local initialization, exact `return`/`br 0` block unwinding, and mutual-recursion safety.
/// Under size presets (`prefer_speed=false`), every inlined site is gated on exact encoded byte profitability.
pub fn pass_inline(
  mod : WasmModule,
  prefer_speed~ : Bool = false,
  max_multi_instrs~ : Int32 = 6,
  max_single_instrs~ : Int32 = 80,
) -> WasmModule {
  if mod.codes.length() < 2 {
    return mod
  }
  let imp_funcs = mod.imported_func_count()
  let flat_types = mod.flat_types()

  // Collect call-site counts, direct call graph, and externally retained functions
  let call_counts : Map[UInt32, Int32] = Map([])
  let call_graph : Map[UInt32, Set[UInt32]] = Map([])
  let retained : Set[UInt32] = Set([])

  for exp in mod.exports {
    if exp.kind == Func {
      retained.add(exp.idx)
    }
  }
  match mod.start_func {
    Some(f) => retained.add(f)
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
      retained.add(f)
    }
    for ex in el.init_exprs {
      collect_init_ref_funcs(ex, retained)
    }
  }
  for i, fb in mod.codes {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    let edges : Set[UInt32] = Set([])
    collect_direct_calls_and_refs(fb.body, call_counts, edges, retained)
    call_graph[fidx] = edges
  }

  // Build eligible callee table
  let candidates : Map[UInt32, InlineCandidate] = Map([])
  for i, fb in mod.codes {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    let calls = call_counts.get(fidx).unwrap_or(0)
    if calls == 0 {
      continue
    }
    let tidx = mod.func_types[i].reinterpret_as_int()
    if tidx < 0 || tidx >= flat_types.length() {
      continue
    }
    let (params, results) = match flat_types[tidx].comp {
      Func(ps, rs) => (ps, rs)
      _ => continue
    }
    if results.length() > 1 {
      continue
    }
    let result_bt : BlockType = if results.is_empty() {
      Empty
    } else {
      Val(results[0])
    }
    if body_has_forbidden_inline_ops(fb.body, fidx) {
      continue
    }

    let non_param_locals = expand_local_types(fb.locals)
    let mut locals_defaultable = true
    for vt in non_param_locals {
      if default_const_for_valtype(vt) is None {
        locals_defaultable = false
        break
      }
    }
    if !locals_defaultable {
      continue
    }

    let icnt = count_instrs(fb.body)
    let is_single_internal = calls == 1 && !retained.contains(fidx)
    let eligible = if is_single_internal && icnt <= max_single_instrs {
      true
    } else if non_param_locals.is_empty() &&
      params.length() <= 4 &&
      icnt <= max_multi_instrs {
      true
    } else {
      false
    }
    if !eligible {
      continue
    }

    let needs_wrap = body_has_return(fb.body) ||
      instrs_branch_to_depth(fb.body, 0U)
    candidates[fidx] = {
      params,
      result_bt,
      non_param_locals,
      body: fb.body,
      needs_block_wrap: needs_wrap,
      instr_count: icnt,
      is_single_internal,
      orig_body_bytes: encode_func_body(fb).length(),
    }
  }

  if candidates.is_empty() {
    return mod
  }

  let mut any_inlined = false
  let new_codes : Array[FuncBody] = []

  for i, fb in mod.codes {
    let caller_fidx = imp_funcs + i.reinterpret_as_uint()
    let caller_param_count = def_param_count(mod, i, flat_types)
    let caller_locals = expand_local_types(fb.locals)
    let mut added_instrs = 0
    let mut changed_caller = false

    fn inline_seq(seq : Array[Instr], loop_depth : Int32) -> Array[Instr] {
      let out : Array[Instr] = []
      for ins in seq {
        match ins {
          Block(bt, b) => out.push(Block(bt, inline_seq(b, loop_depth)))
          Loop(bt, b) => out.push(Loop(bt, inline_seq(b, loop_depth + 1)))
          If(bt, t, e) =>
            out.push(
              If(bt, inline_seq(t, loop_depth), inline_seq(e, loop_depth)),
            )
          TryTable(bt, cs, b) =>
            out.push(TryTable(bt, cs, inline_seq(b, loop_depth)))
          Call(callee_fidx) =>
            match candidates.get(callee_fidx) {
              Some(cand) =>
                if callee_fidx != caller_fidx &&
                  added_instrs + cand.instr_count <= 2048 &&
                  !can_reach_caller(callee_fidx, caller_fidx, call_graph) {
                  let call_sz = instr_encoded_size(Call(callee_fidx))
                  // Exact reclaimed bytes when a single-use internal callee is deleted by module-dce:
                  // func_types entry (~1-2 B) + code body size prefix (~1-2 B) + orig_body_bytes
                  let reclaimed = if cand.is_single_internal {
                    cand.orig_body_bytes + 3
                  } else {
                    0
                  }

                  // Fast path 1: 0 params, 0 locals, no return/br0 -> direct splice
                  if cand.params.is_empty() &&
                    cand.non_param_locals.is_empty() &&
                    !cand.needs_block_wrap {
                    let splice_sz = instrs_encoded_size(cand.body)
                    if prefer_speed || splice_sz <= call_sz + reclaimed {
                      changed_caller = true
                      any_inlined = true
                      added_instrs += cand.instr_count
                      for ci in cand.body {
                        out.push(ci)
                      }
                      continue
                    } else {
                      out.push(ins)
                      continue
                    }
                  }

                  // Fast path 2: 1 param consumed once as first instruction, 0 locals, no return/br0
                  if cand.params.length() == 1 &&
                    cand.non_param_locals.is_empty() &&
                    !cand.needs_block_wrap &&
                    !cand.body.is_empty() &&
                    cand.body[0] == LocalGet(0U) &&
                    !body_uses_local_after_first(cand.body, 0U) &&
                    !body_sets_local(cand.body, 0U) {
                    let rest : Array[Instr] = []
                    for idx in 1..<cand.body.length() {
                      rest.push(cand.body[idx])
                    }
                    let splice_sz = instrs_encoded_size(rest)
                    if prefer_speed || splice_sz <= call_sz + reclaimed {
                      changed_caller = true
                      any_inlined = true
                      added_instrs += cand.instr_count
                      for ci in rest {
                        out.push(ci)
                      }
                      continue
                    } else {
                      out.push(ins)
                      continue
                    }
                  }

                  // General path: build tentative expansion first so we can verify exact byte profitability
                  let saved_locals_len = caller_locals.length()
                  let base_slot = caller_param_count +
                    saved_locals_len.reinterpret_as_uint()
                  let local_remap : Map[UInt32, UInt32] = Map([])
                  let extra_types : Array[ValType] = []
                  let expansion : Array[Instr] = []

                  let p_len = cand.params.length()
                  for pi in 0..<p_len {
                    let slot = base_slot + pi.reinterpret_as_uint()
                    extra_types.push(cand.params[pi])
                    local_remap[pi.reinterpret_as_uint()] = slot
                  }
                  let mut rev = p_len - 1
                  while rev >= 0 {
                    expansion.push(
                      LocalSet(base_slot + rev.reinterpret_as_uint()),
                    )
                    rev -= 1
                  }

                  // Only need explicit zero-init when inside a loop or multi-use (single-use at loop_depth==0 starts zeroed on frame entry)
                  let need_zero_reset = loop_depth > 0 ||
                    !cand.is_single_internal
                  let used_in_callee : Map[UInt32, Int32] = Map([])
                  count_local_uses(cand.body, used_in_callee)
                  for li, vt in cand.non_param_locals {
                    let old_idx = (p_len + li).reinterpret_as_uint()
                    if used_in_callee.get(old_idx).unwrap_or(0) > 0 {
                      let slot = caller_param_count +
                        (saved_locals_len + extra_types.length()).reinterpret_as_uint()
                      extra_types.push(vt)
                      local_remap[old_idx] = slot
                      if need_zero_reset {
                        match default_const_for_valtype(vt) {
                          Some(z) => {
                            expansion.push(z)
                            expansion.push(LocalSet(slot))
                          }
                          None => ()
                        }
                      }
                    }
                  }

                  let rewritten = rewrite_inlined_body(
                    cand.body,
                    local_remap,
                    0U,
                  )
                  if cand.needs_block_wrap {
                    expansion.push(Block(cand.result_bt, rewritten))
                  } else {
                    for ci in rewritten {
                      expansion.push(ci)
                    }
                  }

                  // Exact byte delta check under size presets (-Os / -Oz)
                  let exp_sz = instrs_encoded_size(expansion)
                  let mut new_type_groups = 0
                  for vt in extra_types {
                    if !caller_locals.contains(vt) {
                      new_type_groups += 1
                    }
                  }
                  let local_header_est = new_type_groups * 2
                  // Single-use internal callees get small slack (+4 B) for immediate post-inline peephole/CFG/local cleanup;
                  // multi-use callees remain strictly zero-bloat (exp_sz + local_header_est <= call_sz).
                  let slack = if cand.is_single_internal { 4 } else { 0 }
                  let profitable = prefer_speed ||
                    exp_sz + local_header_est <= call_sz + reclaimed + slack

                  if profitable {
                    changed_caller = true
                    any_inlined = true
                    added_instrs += cand.instr_count
                    for vt in extra_types {
                      caller_locals.push(vt)
                    }
                    for ci in expansion {
                      out.push(ci)
                    }
                  } else {
                    out.push(ins)
                  }
                } else {
                  out.push(ins)
                }
              None => out.push(ins)
            }
          other => out.push(other)
        }
      }
      out
    }

    let new_body = inline_seq(fb.body, 0)
    if changed_caller {
      new_codes.push({
        locals: compress_local_types(caller_locals),
        body: new_body,
      })
    } else {
      new_codes.push(fb)
    }
  }

  if !any_inlined {
    mod
  } else {
    { ..mod, codes: new_codes, }
  }
}
