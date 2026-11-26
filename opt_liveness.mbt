///|
fn set_clone_u32(src : Set[UInt32]) -> Set[UInt32] {
  let out : Set[UInt32] = Set([])
  for x in src {
    out.add(x)
  }
  out
}

///|
fn set_union_into(dst : Set[UInt32], src : Set[UInt32]) -> Unit {
  for x in src {
    dst.add(x)
  }
}

///|
fn set_equal_u32(a : Set[UInt32], b : Set[UInt32]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for x in a {
    if !b.contains(x) {
      return false
    }
  }
  true
}

///|
fn label_live_at(
  label_stack : Array[Set[UInt32]],
  depth : UInt32,
) -> Set[UInt32] {
  let n = label_stack.length()
  let d = depth.reinterpret_as_int()
  if d >= 0 && d < n {
    label_stack[n - 1 - d]
  } else {
    Set([])
  }
}

///|
fn is_non_null_valtype(vt : ValType) -> Bool {
  match vt {
    Ref(_) => true
    _ => false
  }
}

///|
fn build_func_local_types(
  mod : WasmModule,
  def_i : Int32,
  flat_types : Array[SubType],
) -> (UInt32, Array[ValType])? {
  let tidx = mod.func_types[def_i].reinterpret_as_int()
  if tidx < 0 || tidx >= flat_types.length() {
    return None
  }
  let params = match flat_types[tidx].comp {
    Func(ps, _) => ps
    _ => return None
  }
  let all_types : Array[ValType] = []
  for p in params {
    all_types.push(p)
  }
  let fb = mod.codes[def_i]
  for lg in fb.locals {
    let cnt = lg.count.reinterpret_as_int()
    for _ in 0..<cnt {
      all_types.push(lg.val_type)
    }
  }
  Some((params.length().reinterpret_as_uint(), all_types))
}

///|
fn collect_all_local_reads(instrs : Array[Instr], reads : Set[UInt32]) -> Unit {
  for ins in instrs {
    match ins {
      LocalGet(l) => reads.add(l)
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        collect_all_local_reads(b, reads)
      If(_, t, e) => {
        collect_all_local_reads(t, reads)
        collect_all_local_reads(e, reads)
      }
      _ => ()
    }
  }
}

///|
/// Straight-line local alias copy propagation and size-neutral small-constant propagation.
/// Conservatively resets at structured control-flow boundaries and requires exact `ValType` match.
fn prop_copies_seq(
  instrs : Array[Instr],
  local_types : Array[ValType],
) -> Array[Instr] {
  let aliases : Map[UInt32, UInt32] = Map([])
  let consts : Map[UInt32, Instr] = Map([])

  fn invalidate(x : UInt32) -> Unit {
    aliases.remove(x)
    consts.remove(x)
    let to_drop : Array[UInt32] = []
    for k, v in aliases {
      if v == x {
        to_drop.push(k)
      }
    }
    for k in to_drop {
      aliases.remove(k)
    }
  }

  fn clear_state() -> Unit {
    aliases.clear()
    consts.clear()
  }

  fn resolve_alias(x : UInt32) -> UInt32 {
    let mut cur = x
    for _ in 0..<8 {
      match aliases.get(cur) {
        Some(next) => if next == cur { break } else { cur = next }
        None => break
      }
    }
    cur
  }

  fn type_of(idx : UInt32) -> ValType? {
    let i = idx.reinterpret_as_int()
    if i >= 0 && i < local_types.length() {
      Some(local_types[i])
    } else {
      None
    }
  }

  let out : Array[Instr] = []
  for raw_ins in instrs {
    match raw_ins {
      Block(bt, b) => {
        clear_state()
        out.push(Block(bt, prop_copies_seq(b, local_types)))
      }
      Loop(bt, b) => {
        clear_state()
        out.push(Loop(bt, prop_copies_seq(b, local_types)))
      }
      If(bt, t, e) => {
        clear_state()
        out.push(
          If(
            bt,
            prop_copies_seq(t, local_types),
            prop_copies_seq(e, local_types),
          ),
        )
      }
      TryTable(bt, cs, b) => {
        clear_state()
        out.push(TryTable(bt, cs, prop_copies_seq(b, local_types)))
      }
      LocalGet(x) =>
        match consts.get(x) {
          Some(c_ins) =>
            if instr_encoded_size(c_ins) <= instr_encoded_size(LocalGet(x)) {
              out.push(c_ins)
            } else {
              out.push(LocalGet(resolve_alias(x)))
            }
          None => out.push(LocalGet(resolve_alias(x)))
        }
      LocalSet(dst) | LocalTee(dst) => {
        let prev = if out.is_empty() {
          None
        } else {
          Some(out[out.length() - 1])
        }
        invalidate(dst)
        match prev {
          Some(LocalGet(src)) =>
            if src != dst {
              match (type_of(src), type_of(dst)) {
                (Some(ts), Some(td)) if ts == td =>
                  aliases[dst] = resolve_alias(src)
                _ => ()
              }
            }
          Some(I32Const(v)) =>
            if type_of(dst) == Some(I32) {
              consts[dst] = I32Const(v)
            }
          Some(I64Const(v)) =>
            if type_of(dst) == Some(I64) {
              consts[dst] = I64Const(v)
            }
          _ => ()
        }
        out.push(raw_ins)
      }
      Br(_)
      | BrIf(_)
      | BrTable(_, _)
      | BrOnNull(_)
      | BrOnNonNull(_)
      | BrOnCast(_, _, _, _)
      | BrOnCastFail(_, _, _, _)
      | Return
      | Unreachable
      | Throw(_)
      | ThrowRef => {
        clear_state()
        out.push(raw_ins)
      }
      other => out.push(other)
    }
  }
  out
}

///|
/// Backward structured liveness analysis with optional dead-store rewriting (`rewrite=true`).
/// Returns `(live_before, rewritten_instrs)`.
fn backward_liveness_dse(
  instrs : Array[Instr],
  live_after_exit : Set[UInt32],
  label_stack : Array[Set[UInt32]],
  catch_live : Set[UInt32],
  local_types : Array[ValType],
  all_reads : Set[UInt32],
  rewrite : Bool,
) -> (Set[UInt32], Array[Instr]) {
  let n = instrs.length()
  let rev_out : Array[Instr] = []
  let mut live = set_clone_u32(live_after_exit)
  set_union_into(live, catch_live)

  let mut idx = n - 1
  while idx >= 0 {
    let ins = instrs[idx]
    match ins {
      Unreachable | Return | Throw(_) | ThrowRef => {
        live = set_clone_u32(catch_live)
        if rewrite {
          rev_out.push(ins)
        }
      }
      ReturnCall(_) | ReturnCallIndirect(_, _) | ReturnCallRef(_) => {
        live = set_clone_u32(catch_live)
        if rewrite {
          rev_out.push(ins)
        }
      }
      Br(l) => {
        live = set_clone_u32(label_live_at(label_stack, l))
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(ins)
        }
      }
      BrTable(ts, d) => {
        let next_live = set_clone_u32(label_live_at(label_stack, d))
        for t in ts {
          set_union_into(next_live, label_live_at(label_stack, t))
        }
        set_union_into(next_live, catch_live)
        live = next_live
        if rewrite {
          rev_out.push(ins)
        }
      }
      BrIf(l)
      | BrOnNull(l)
      | BrOnNonNull(l)
      | BrOnCast(_, l, _, _)
      | BrOnCastFail(_, l, _, _) => {
        set_union_into(live, label_live_at(label_stack, l))
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(ins)
        }
      }
      LocalGet(x) => {
        live.add(x)
        if rewrite {
          rev_out.push(ins)
        }
      }
      LocalSet(x) => {
        let is_live = live.contains(x)
        live.remove(x)
        set_union_into(live, catch_live)
        if rewrite {
          let i = x.reinterpret_as_int()
          let non_null_read_elsewhere = i >= 0 &&
            i < local_types.length() &&
            is_non_null_valtype(local_types[i]) &&
            all_reads.contains(x)
          if !is_live && !non_null_read_elsewhere {
            rev_out.push(Drop)
          } else {
            rev_out.push(ins)
          }
        }
      }
      LocalTee(x) => {
        let is_live = live.contains(x)
        live.remove(x)
        set_union_into(live, catch_live)
        if rewrite {
          let i = x.reinterpret_as_int()
          let non_null_read_elsewhere = i >= 0 &&
            i < local_types.length() &&
            is_non_null_valtype(local_types[i]) &&
            all_reads.contains(x)
          if is_live || non_null_read_elsewhere {
            rev_out.push(ins)
          }
          // Else dead LocalTee is simply omitted (stack value passes through unchanged)
        }
      }
      Block(bt, body) => {
        let exit_live = set_clone_u32(live)
        label_stack.push(exit_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, catch_live, local_types, all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live = lb
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(Block(bt, new_body))
        }
      }
      If(bt, then_b, else_b) => {
        let exit_live = set_clone_u32(live)
        label_stack.push(exit_live)
        let (lt, new_t) = backward_liveness_dse(
          then_b, exit_live, label_stack, catch_live, local_types, all_reads, rewrite,
        )
        let (le, new_e) = if else_b.is_empty() {
          (set_clone_u32(exit_live), else_b)
        } else {
          backward_liveness_dse(
            else_b, exit_live, label_stack, catch_live, local_types, all_reads, rewrite,
          )
        }
        ignore(label_stack.pop())
        set_union_into(lt, le)
        set_union_into(lt, catch_live)
        live = lt
        if rewrite {
          rev_out.push(If(bt, new_t, new_e))
        }
      }
      Loop(bt, body) => {
        let exit_live = set_clone_u32(live)
        let mut head_live : Set[UInt32] = Set([])
        let mut converged = false
        for _ in 0..<64 {
          label_stack.push(head_live)
          let (cand, _) = backward_liveness_dse(
            body, exit_live, label_stack, catch_live, local_types, all_reads, false,
          )
          ignore(label_stack.pop())
          set_union_into(cand, head_live)
          if set_equal_u32(cand, head_live) {
            converged = true
            break
          }
          head_live = cand
        }
        if !converged {
          // Conservative fallback if loop fixpoint didn't finish in 64 rounds
          collect_all_local_reads(body, head_live)
          set_union_into(head_live, exit_live)
        }
        label_stack.push(head_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, catch_live, local_types, all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live = lb
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(Loop(bt, new_body))
        }
      }
      TryTable(bt, catches, body) => {
        let exit_live = set_clone_u32(live)
        let inner_catch = set_clone_u32(catch_live)
        for c in catches {
          let lbl = match c {
            Catch(_, l) | CatchRef(_, l) | CatchAll(l) | CatchAllRef(l) => l
          }
          set_union_into(inner_catch, label_live_at(label_stack, lbl))
        }
        label_stack.push(exit_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, inner_catch, local_types, all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live = lb
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(TryTable(bt, catches, new_body))
        }
      }
      other => {
        set_union_into(live, catch_live)
        if rewrite {
          rev_out.push(other)
        }
      }
    }
    idx -= 1
  }

  if !rewrite {
    (live, [])
  } else {
    let out : Array[Instr] = []
    let mut k = rev_out.length() - 1
    while k >= 0 {
      out.push(rev_out[k])
      k -= 1
    }
    (live, out)
  }
}

///|
/// Pass 11: Straight-line copy/const propagation + exact backward structured Dead Local Store Elimination (DSE).
pub fn pass_local_dse(mod : WasmModule) -> WasmModule {
  if mod.codes.is_empty() {
    return mod
  }
  let flat_types = mod.flat_types()
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    match build_func_local_types(mod, i, flat_types) {
      None => new_codes.push(fb)
      Some((_, local_types)) => {
        if local_types.is_empty() {
          new_codes.push(fb)
          continue
        }
        let body1 = prop_copies_seq(fb.body, local_types)
        let all_reads : Set[UInt32] = Set([])
        collect_all_local_reads(body1, all_reads)
        let label_stack : Array[Set[UInt32]] = [Set([])]
        let (_, body2) = backward_liveness_dse(
          body1,
          Set([]),
          label_stack,
          Set([]),
          local_types,
          all_reads,
          true,
        )
        let cand : FuncBody = { locals: fb.locals, body: body2, }
        if cand != fb &&
          encode_func_body(cand).length() <= encode_func_body(fb).length() {
          changed = true
          new_codes.push(cand)
        } else {
          new_codes.push(fb)
        }
      }
    }
  }

  if !changed {
    mod
  } else {
    { ..mod, codes: new_codes, }
  }
}

///|
fn add_interf_edge(
  interf : Map[UInt32, Set[UInt32]],
  a : UInt32,
  b : UInt32,
) -> Unit {
  if a == b {
    return
  }
  match interf.get(a) {
    Some(s) => s.add(b)
    None => interf[a] = Set([b])
  }
  match interf.get(b) {
    Some(s) => s.add(a)
    None => interf[b] = Set([a])
  }
}

///|
fn add_move_affinity(
  aff : Map[UInt32, Map[UInt32, Int32]],
  a : UInt32,
  b : UInt32,
) -> Unit {
  if a == b {
    return
  }
  match aff.get(a) {
    Some(m) => m[b] = m.get(b).unwrap_or(0) + 1
    None => aff[a] = Map([(b, 1)])
  }
  match aff.get(b) {
    Some(m) => m[a] = m.get(a).unwrap_or(0) + 1
    None => aff[b] = Map([(a, 1)])
  }
}

///|
/// Backward structured liveness that records exact def-vs-live_after interference edges and move affinities.
fn backward_liveness_interf(
  instrs : Array[Instr],
  live_after_exit : Set[UInt32],
  label_stack : Array[Set[UInt32]],
  catch_live : Set[UInt32],
  record : Bool,
  interf : Map[UInt32, Set[UInt32]],
  aff : Map[UInt32, Map[UInt32, Int32]],
) -> Set[UInt32] {
  let n = instrs.length()
  let mut live = set_clone_u32(live_after_exit)
  set_union_into(live, catch_live)

  let mut idx = n - 1
  while idx >= 0 {
    let ins = instrs[idx]
    match ins {
      Unreachable
      | Return
      | Throw(_)
      | ThrowRef
      | ReturnCall(_)
      | ReturnCallIndirect(_, _)
      | ReturnCallRef(_) => live = set_clone_u32(catch_live)
      Br(l) => {
        live = set_clone_u32(label_live_at(label_stack, l))
        set_union_into(live, catch_live)
      }
      BrTable(ts, d) => {
        let next_live = set_clone_u32(label_live_at(label_stack, d))
        for t in ts {
          set_union_into(next_live, label_live_at(label_stack, t))
        }
        set_union_into(next_live, catch_live)
        live = next_live
      }
      BrIf(l)
      | BrOnNull(l)
      | BrOnNonNull(l)
      | BrOnCast(_, l, _, _)
      | BrOnCastFail(_, l, _, _) => {
        set_union_into(live, label_live_at(label_stack, l))
        set_union_into(live, catch_live)
      }
      LocalGet(x) => live.add(x)
      LocalSet(x) | LocalTee(x) => {
        if record {
          let move_src : UInt32? = if idx > 0 {
            match instrs[idx - 1] {
              LocalGet(s) => Some(s)
              _ => None
            }
          } else {
            None
          }
          match move_src {
            Some(s) => add_move_affinity(aff, x, s)
            None => ()
          }
          for v in live {
            if v != x && Some(v) != move_src {
              add_interf_edge(interf, x, v)
            }
          }
        }
        live.remove(x)
        set_union_into(live, catch_live)
      }
      Block(_, body) => {
        let exit_live = set_clone_u32(live)
        label_stack.push(exit_live)
        live = backward_liveness_interf(
          body, exit_live, label_stack, catch_live, record, interf, aff,
        )
        ignore(label_stack.pop())
        set_union_into(live, catch_live)
      }
      If(_, then_b, else_b) => {
        let exit_live = set_clone_u32(live)
        label_stack.push(exit_live)
        let lt = backward_liveness_interf(
          then_b, exit_live, label_stack, catch_live, record, interf, aff,
        )
        let le = if else_b.is_empty() {
          set_clone_u32(exit_live)
        } else {
          backward_liveness_interf(
            else_b, exit_live, label_stack, catch_live, record, interf, aff,
          )
        }
        ignore(label_stack.pop())
        set_union_into(lt, le)
        set_union_into(lt, catch_live)
        live = lt
      }
      Loop(_, body) => {
        let exit_live = set_clone_u32(live)
        let mut head_live : Set[UInt32] = Set([])
        let mut converged = false
        for _ in 0..<64 {
          label_stack.push(head_live)
          let cand = backward_liveness_interf(
            body, exit_live, label_stack, catch_live, false, interf, aff,
          )
          ignore(label_stack.pop())
          set_union_into(cand, head_live)
          if set_equal_u32(cand, head_live) {
            converged = true
            break
          }
          head_live = cand
        }
        if !converged {
          collect_all_local_reads(body, head_live)
          set_union_into(head_live, exit_live)
        }
        label_stack.push(head_live)
        live = backward_liveness_interf(
          body, exit_live, label_stack, catch_live, record, interf, aff,
        )
        ignore(label_stack.pop())
        set_union_into(live, catch_live)
      }
      TryTable(_, catches, body) => {
        let exit_live = set_clone_u32(live)
        let inner_catch = set_clone_u32(catch_live)
        for c in catches {
          let lbl = match c {
            Catch(_, l) | CatchRef(_, l) | CatchAll(l) | CatchAllRef(l) => l
          }
          set_union_into(inner_catch, label_live_at(label_stack, lbl))
        }
        label_stack.push(exit_live)
        live = backward_liveness_interf(
          body, exit_live, label_stack, inner_catch, record, interf, aff,
        )
        ignore(label_stack.pop())
        set_union_into(live, catch_live)
      }
      _ => set_union_into(live, catch_live)
    }
    idx -= 1
  }
  live
}

///|
fn interferes_with_any(
  x : UInt32,
  members : Array[UInt32],
  interf : Map[UInt32, Set[UInt32]],
) -> Bool {
  match interf.get(x) {
    None => false
    Some(adj) => {
      for m in members {
        if adj.contains(m) {
          return true
        }
      }
      false
    }
  }
}

///|
fn coalesce_func_locals(
  fb : FuncBody,
  param_count : UInt32,
  local_types : Array[ValType],
) -> FuncBody {
  let total = local_types.length()
  let p_len = param_count.reinterpret_as_int()
  if total <= p_len || total > 512 {
    return fb
  }

  let uses : Map[UInt32, Int32] = Map([])
  count_local_uses(fb.body, uses)

  let interf : Map[UInt32, Set[UInt32]] = Map([])
  let aff : Map[UInt32, Map[UInt32, Int32]] = Map([])
  let label_stack : Array[Set[UInt32]] = [Set([])]
  let entry_live = backward_liveness_interf(
    fb.body,
    Set([]),
    label_stack,
    Set([]),
    true,
    interf,
    aff,
  )

  // All locals live at function entry (including parameters) mutually interfere
  let entry_list : Array[UInt32] = []
  for p in 0..<p_len {
    entry_list.push(p.reinterpret_as_uint())
  }
  for v in entry_live {
    if v >= param_count {
      entry_list.push(v)
    }
  }
  for i in 0..<entry_list.length() {
    for j in (i + 1)..<entry_list.length() {
      add_interf_edge(interf, entry_list[i], entry_list[j])
    }
  }

  // Color slots: 0..<p_len are fixed parameter slots; colors >= p_len are newly allocated non-param slots
  let color_type : Array[ValType] = []
  let color_members : Array[Array[UInt32]] = []
  let assigned : Map[UInt32, Int32] = Map([])

  for p in 0..<p_len {
    color_type.push(local_types[p])
    color_members.push([p.reinterpret_as_uint()])
    assigned[p.reinterpret_as_uint()] = p
  }

  // Pin non-param locals that rely on zero-initialization (`entry_live`) to dedicated non-param colors first
  let candidates : Array[(UInt32, Int32)] = []
  for idx in p_len..<total {
    let l = idx.reinterpret_as_uint()
    let u = uses.get(l).unwrap_or(0)
    if u == 0 {
      continue
    }
    if entry_live.contains(l) {
      let c = color_type.length()
      color_type.push(local_types[idx])
      color_members.push([l])
      assigned[l] = c
    } else {
      candidates.push((l, u))
    }
  }

  if candidates.is_empty() {
    return fb
  }

  // Sort non-pinned used locals by use frequency descending for optimal 1-byte LEB128 slot allocation
  candidates.sort_by((a, b) => {
    let cmp = b.1.compare(a.1)
    if cmp != 0 {
      cmp
    } else {
      a.0.compare(b.0)
    }
  })

  for item in candidates {
    let (l, _) = item
    let vt = local_types[l.reinterpret_as_int()]
    let mut best_color = -1
    let mut best_score = -1

    // Score existing colors of exact same ValType (prefer copy-affinity partner & lowest slot index)
    let aff_map = aff.get(l)
    for c in 0..<color_type.length() {
      if color_type[c] != vt {
        continue
      }
      // Never merge into a pinned zero-init non-param local's color
      if c >= p_len &&
        !color_members[c].is_empty() &&
        entry_live.contains(color_members[c][0]) {
        continue
      }
      if interferes_with_any(l, color_members[c], interf) {
        continue
      }
      let mut score = 0
      match aff_map {
        Some(am) =>
          for m in color_members[c] {
            score += am.get(m).unwrap_or(0) * 100
          }
        None => ()
      }
      // Prefer reusing parameter slots (< p_len) and 1-byte LEB128 slots (< 128)
      if c < p_len {
        score += 10
      } else if c < 128 {
        score += 5
      }
      if best_color < 0 || score > best_score {
        best_color = c
        best_score = score
      }
    }

    if best_color >= 0 {
      color_members[best_color].push(l)
      assigned[l] = best_color
    } else {
      let c = color_type.length()
      color_type.push(vt)
      color_members.push([l])
      assigned[l] = c
    }
  }

  let new_non_param_count = color_type.length() - p_len
  let old_non_param_count = total - p_len

  // Build final local remap & compact LocalGroups
  let remap : Map[UInt32, UInt32] = Map([])
  let mut any_remapped = false
  for l, c in assigned {
    let target = c.reinterpret_as_uint()
    remap[l] = target
    if l != target {
      any_remapped = true
    }
  }
  if !any_remapped && new_non_param_count == old_non_param_count {
    return fb
  }

  let new_non_param_types : Array[ValType] = []
  for c in p_len..<color_type.length() {
    new_non_param_types.push(color_type[c])
  }
  let candidate : FuncBody = {
    locals: compress_local_types(new_non_param_types),
    body: remap_locals_in_instrs(fb.body, remap),
  }
  // Keep candidate whenever encoded size shrinks OR local count strictly decreased without bloating size
  let old_sz = encode_func_body(fb).length()
  let new_sz = encode_func_body(candidate).length()
  if new_sz < old_sz ||
    (new_sz == old_sz && new_non_param_count < old_non_param_count) {
    candidate
  } else {
    fb
  }
}

///|
/// Pass 12: Interference-graph & copy-affinity greedy graph-coloring local slot coalescing.
/// Safely pins zero-init entry-live locals, preserves parameter ABI indices, and enforces exact ValType & size profitability.
pub fn pass_coalesce_locals(mod : WasmModule) -> WasmModule {
  if mod.codes.is_empty() {
    return mod
  }
  let flat_types = mod.flat_types()
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    match build_func_local_types(mod, i, flat_types) {
      None => new_codes.push(fb)
      Some((pcnt, local_types)) => {
        let opt_fb = coalesce_func_locals(fb, pcnt, local_types)
        if opt_fb != fb {
          changed = true
        }
        new_codes.push(opt_fb)
      }
    }
  }

  if !changed {
    mod
  } else {
    { ..mod, codes: new_codes, }
  }
}
