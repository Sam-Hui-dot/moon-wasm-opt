///|
/// Compact fixed-word bitset for zero-allocation backward local liveness & dense interference matrices.
priv struct LocalBitSet {
  words : FixedArray[UInt64]
}

///|
fn LocalBitSet::new(num_words : Int32) -> LocalBitSet {
  { words: FixedArray::make(num_words, 0UL), }
}

///|
fn LocalBitSet::clone(self : LocalBitSet) -> LocalBitSet {
  let n = self.words.length()
  { words: FixedArray::makei(n, i => self.words[i]), }
}

///|
fn LocalBitSet::add(self : LocalBitSet, idx : UInt32) -> Unit {
  let k = idx.reinterpret_as_int()
  let w = k >> 6
  if w >= 0 && w < self.words.length() {
    self.words[w] = self.words[w] | (1UL << (k & 63))
  }
}

///|
fn LocalBitSet::remove(self : LocalBitSet, idx : UInt32) -> Unit {
  let k = idx.reinterpret_as_int()
  let w = k >> 6
  if w >= 0 && w < self.words.length() {
    self.words[w] = self.words[w] & (1UL << (k & 63)).lnot()
  }
}

///|
fn LocalBitSet::contains(self : LocalBitSet, idx : UInt32) -> Bool {
  let k = idx.reinterpret_as_int()
  let w = k >> 6
  if w >= 0 && w < self.words.length() {
    (self.words[w] & (1UL << (k & 63))) != 0UL
  } else {
    false
  }
}

///|
fn LocalBitSet::is_zero(self : LocalBitSet) -> Bool {
  for i in 0..<self.words.length() {
    if self.words[i] != 0UL {
      return false
    }
  }
  true
}

///|
fn LocalBitSet::clear_all(self : LocalBitSet) -> Unit {
  for i in 0..<self.words.length() {
    self.words[i] = 0UL
  }
}

///|
fn LocalBitSet::copy_from(self : LocalBitSet, src : LocalBitSet) -> Unit {
  for i in 0..<self.words.length() {
    self.words[i] = src.words[i]
  }
}

///|
fn LocalBitSet::union_into(self : LocalBitSet, src : LocalBitSet) -> Unit {
  for i in 0..<self.words.length() {
    self.words[i] = self.words[i] | src.words[i]
  }
}

///|
fn LocalBitSet::equals(self : LocalBitSet, other : LocalBitSet) -> Bool {
  for i in 0..<self.words.length() {
    if self.words[i] != other.words[i] {
      return false
    }
  }
  true
}

///|
fn LocalBitSet::intersects(self : LocalBitSet, other : LocalBitSet) -> Bool {
  for i in 0..<self.words.length() {
    if (self.words[i] & other.words[i]) != 0UL {
      return true
    }
  }
  false
}

///|
fn label_bitset_at(
  label_stack : Array[LocalBitSet],
  depth : UInt32,
  empty : LocalBitSet,
) -> LocalBitSet {
  let n = label_stack.length()
  let d = depth.reinterpret_as_int()
  if d >= 0 && d < n {
    label_stack[n - 1 - d]
  } else {
    empty
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
fn collect_all_local_reads_bs(
  instrs : Array[Instr],
  reads : LocalBitSet,
) -> Unit {
  for ins in instrs {
    match ins {
      LocalGet(l) => reads.add(l)
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        collect_all_local_reads_bs(b, reads)
      If(_, t, e) => {
        collect_all_local_reads_bs(t, reads)
        collect_all_local_reads_bs(e, reads)
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
    if !aliases.is_empty() {
      aliases.clear()
    }
    if !consts.is_empty() {
      consts.clear()
    }
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
  let mut changed = false
  for raw_ins in instrs {
    match raw_ins {
      Block(bt, b) => {
        clear_state()
        let nb = prop_copies_seq(b, local_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, b) => {
        clear_state()
        let nb = prop_copies_seq(b, local_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Loop(bt, nb))
      }
      If(bt, t, e) => {
        clear_state()
        let nt = prop_copies_seq(t, local_types)
        let ne = prop_copies_seq(e, local_types)
        if !physical_equal(nt, t) || !physical_equal(ne, e) {
          changed = true
        }
        out.push(If(bt, nt, ne))
      }
      TryTable(bt, cs, b) => {
        clear_state()
        let nb = prop_copies_seq(b, local_types)
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(TryTable(bt, cs, nb))
      }
      LocalGet(x) =>
        match consts.get(x) {
          Some(c_ins) =>
            if instr_encoded_size(c_ins) <= instr_encoded_size(LocalGet(x)) {
              changed = true
              out.push(c_ins)
            } else {
              let r = resolve_alias(x)
              if r != x {
                changed = true
              }
              out.push(LocalGet(r))
            }
          None => {
            let r = resolve_alias(x)
            if r != x {
              changed = true
            }
            out.push(LocalGet(r))
          }
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
  if !changed {
    instrs
  } else {
    out
  }
}

///|
/// Backward structured liveness analysis with optional dead-store rewriting (`rewrite=true`).
/// Uses fixed-word `LocalBitSet` for zero-hash inner loops.
fn backward_liveness_dse(
  instrs : Array[Instr],
  live_after_exit : LocalBitSet,
  label_stack : Array[LocalBitSet],
  catch_live : LocalBitSet,
  catch_active : Bool,
  empty_bs : LocalBitSet,
  local_types : Array[ValType],
  all_reads : LocalBitSet,
  rewrite : Bool,
) -> (LocalBitSet, Array[Instr]) {
  let n = instrs.length()
  let num_words = live_after_exit.words.length()
  let rev_out : Array[Instr] = []
  let mut body_changed = false
  let live = live_after_exit.clone()
  if catch_active {
    live.union_into(catch_live)
  }

  let mut idx = n - 1
  while idx >= 0 {
    let ins = instrs[idx]
    match ins {
      Unreachable | Return | Throw(_) | ThrowRef => {
        if catch_active {
          live.copy_from(catch_live)
        } else {
          live.clear_all()
        }
        if rewrite {
          rev_out.push(ins)
        }
      }
      ReturnCall(_) | ReturnCallIndirect(_, _) | ReturnCallRef(_) => {
        if catch_active {
          live.copy_from(catch_live)
        } else {
          live.clear_all()
        }
        if rewrite {
          rev_out.push(ins)
        }
      }
      Br(l) => {
        live.copy_from(label_bitset_at(label_stack, l, empty_bs))
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          rev_out.push(ins)
        }
      }
      BrTable(ts, d) => {
        live.copy_from(label_bitset_at(label_stack, d, empty_bs))
        for t in ts {
          live.union_into(label_bitset_at(label_stack, t, empty_bs))
        }
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          rev_out.push(ins)
        }
      }
      BrIf(l)
      | BrOnNull(l)
      | BrOnNonNull(l)
      | BrOnCast(_, l, _, _)
      | BrOnCastFail(_, l, _, _) => {
        live.union_into(label_bitset_at(label_stack, l, empty_bs))
        if catch_active {
          live.union_into(catch_live)
        }
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
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          let i = x.reinterpret_as_int()
          let non_null_read_elsewhere = i >= 0 &&
            i < local_types.length() &&
            is_non_null_valtype(local_types[i]) &&
            all_reads.contains(x)
          if !is_live && !non_null_read_elsewhere {
            body_changed = true
            rev_out.push(Drop)
          } else {
            rev_out.push(ins)
          }
        }
      }
      LocalTee(x) => {
        let is_live = live.contains(x)
        live.remove(x)
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          let i = x.reinterpret_as_int()
          let non_null_read_elsewhere = i >= 0 &&
            i < local_types.length() &&
            is_non_null_valtype(local_types[i]) &&
            all_reads.contains(x)
          if is_live || non_null_read_elsewhere {
            rev_out.push(ins)
          } else {
            body_changed = true
          }
        }
      }
      Block(bt, body) => {
        let exit_live = live.clone()
        label_stack.push(exit_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, catch_live, catch_active, empty_bs, local_types,
          all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live.copy_from(lb)
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          if !physical_equal(new_body, body) {
            body_changed = true
          }
          rev_out.push(Block(bt, new_body))
        }
      }
      If(bt, then_b, else_b) => {
        let exit_live = live.clone()
        label_stack.push(exit_live)
        let (lt, new_t) = backward_liveness_dse(
          then_b, exit_live, label_stack, catch_live, catch_active, empty_bs, local_types,
          all_reads, rewrite,
        )
        let (le, new_e) = if else_b.is_empty() {
          (exit_live.clone(), else_b)
        } else {
          backward_liveness_dse(
            else_b, exit_live, label_stack, catch_live, catch_active, empty_bs, local_types,
            all_reads, rewrite,
          )
        }
        ignore(label_stack.pop())
        live.copy_from(lt)
        live.union_into(le)
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          if !physical_equal(new_t, then_b) || !physical_equal(new_e, else_b) {
            body_changed = true
          }
          rev_out.push(If(bt, new_t, new_e))
        }
      }
      Loop(bt, body) => {
        let exit_live = live.clone()
        let head_live = LocalBitSet::new(num_words)
        let mut converged = false
        for _ in 0..<64 {
          label_stack.push(head_live)
          let (cand, _) = backward_liveness_dse(
            body, exit_live, label_stack, catch_live, catch_active, empty_bs, local_types,
            all_reads, false,
          )
          ignore(label_stack.pop())
          cand.union_into(head_live)
          if cand.equals(head_live) {
            converged = true
            break
          }
          head_live.copy_from(cand)
        }
        if !converged {
          collect_all_local_reads_bs(body, head_live)
          head_live.union_into(exit_live)
        }
        label_stack.push(head_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, catch_live, catch_active, empty_bs, local_types,
          all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live.copy_from(lb)
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          if !physical_equal(new_body, body) {
            body_changed = true
          }
          rev_out.push(Loop(bt, new_body))
        }
      }
      TryTable(bt, catches, body) => {
        let exit_live = live.clone()
        let inner_catch = catch_live.clone()
        for c in catches {
          let lbl = match c {
            Catch(_, l) | CatchRef(_, l) | CatchAll(l) | CatchAllRef(l) => l
          }
          inner_catch.union_into(label_bitset_at(label_stack, lbl, empty_bs))
        }
        let inner_active = catch_active || !inner_catch.is_zero()
        label_stack.push(exit_live)
        let (lb, new_body) = backward_liveness_dse(
          body, exit_live, label_stack, inner_catch, inner_active, empty_bs, local_types,
          all_reads, rewrite,
        )
        ignore(label_stack.pop())
        live.copy_from(lb)
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          if !physical_equal(new_body, body) {
            body_changed = true
          }
          rev_out.push(TryTable(bt, catches, new_body))
        }
      }
      other => {
        if catch_active {
          live.union_into(catch_live)
        }
        if rewrite {
          rev_out.push(other)
        }
      }
    }
    idx -= 1
  }

  if !rewrite || !body_changed {
    (live, instrs)
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
fn pass_local_dse_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let flat_types = mod.flat_types()
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      match build_func_local_types(mod, i, flat_types) {
        None => new_codes.push(fb)
        Some((_, local_types)) => {
          let total = local_types.length()
          if total == 0 {
            new_codes.push(fb)
            continue
          }
          let num_words = (total + 63) / 64
          let body1 = prop_copies_seq(fb.body, local_types)
          let all_reads = LocalBitSet::new(num_words)
          collect_all_local_reads_bs(body1, all_reads)
          let empty_bs = LocalBitSet::new(num_words)
          let label_stack : Array[LocalBitSet] = [empty_bs]
          let (_, body2) = backward_liveness_dse(
            body1, empty_bs, label_stack, empty_bs, false, empty_bs, local_types,
            all_reads, true,
          )
          if physical_equal(body2, fb.body) {
            new_codes.push(fb)
          } else {
            let cand : FuncBody = { locals: fb.locals, body: body2, }
            if cand != fb &&
              encode_func_body(cand).length() <= encode_func_body(fb).length() {
              changed = true
              out_changed[i] = true
              new_codes.push(cand)
            } else {
              new_codes.push(fb)
            }
          }
        }
      }
    } else {
      new_codes.push(fb)
    }
  }

  if !changed {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 11: Straight-line copy/const propagation + exact backward structured Dead Local Store Elimination (DSE).
pub fn pass_local_dse(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_local_dse_dirty(mod, None)
  next
}

///|
fn add_interf_edge_matrix(
  interf : FixedArray[LocalBitSet],
  a : UInt32,
  b : UInt32,
) -> Unit {
  if a == b {
    return
  }
  let ai = a.reinterpret_as_int()
  let bi = b.reinterpret_as_int()
  if ai >= 0 && ai < interf.length() && bi >= 0 && bi < interf.length() {
    interf[ai].add(b)
    interf[bi].add(a)
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
/// Record interference between `x` (excluding `move_src`) and all bits currently set in `live`.
fn record_interf_against_live(
  interf : FixedArray[LocalBitSet],
  x : Int32,
  move_src : Int32,
  live : LocalBitSet,
  total_locals : Int32,
) -> Unit {
  if x < 0 || x >= total_locals {
    return
  }
  let row = interf[x]
  let nwords = live.words.length()
  for wi in 0..<nwords {
    let mut w = live.words[wi]
    if wi == x >> 6 {
      w = w & (1UL << (x & 63)).lnot()
    }
    if move_src >= 0 && wi == move_src >> 6 {
      w = w & (1UL << (move_src & 63)).lnot()
    }
    if w == 0UL {
      continue
    }
    row.words[wi] = row.words[wi] | w
    let base = wi << 6
    let mut bit_off = 0
    while w != 0UL {
      if (w & 1UL) != 0UL {
        let v = base + bit_off
        if v < total_locals {
          interf[v].words[x >> 6] = interf[v].words[x >> 6] | (1UL << (x & 63))
        }
      }
      w = w >> 1
      bit_off += 1
    }
  }
}

///|
/// Backward structured liveness that records dense bit-matrix interference edges and move affinities.
fn backward_liveness_interf(
  instrs : Array[Instr],
  live_after_exit : LocalBitSet,
  label_stack : Array[LocalBitSet],
  catch_live : LocalBitSet,
  catch_active : Bool,
  empty_bs : LocalBitSet,
  record : Bool,
  total_locals : Int32,
  interf : FixedArray[LocalBitSet],
  aff : Map[UInt32, Map[UInt32, Int32]],
) -> LocalBitSet {
  let n = instrs.length()
  let num_words = live_after_exit.words.length()
  let live = live_after_exit.clone()
  if catch_active {
    live.union_into(catch_live)
  }

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
      | ReturnCallRef(_) =>
        if catch_active {
          live.copy_from(catch_live)
        } else {
          live.clear_all()
        }
      Br(l) => {
        live.copy_from(label_bitset_at(label_stack, l, empty_bs))
        if catch_active {
          live.union_into(catch_live)
        }
      }
      BrTable(ts, d) => {
        live.copy_from(label_bitset_at(label_stack, d, empty_bs))
        for t in ts {
          live.union_into(label_bitset_at(label_stack, t, empty_bs))
        }
        if catch_active {
          live.union_into(catch_live)
        }
      }
      BrIf(l)
      | BrOnNull(l)
      | BrOnNonNull(l)
      | BrOnCast(_, l, _, _)
      | BrOnCastFail(_, l, _, _) => {
        live.union_into(label_bitset_at(label_stack, l, empty_bs))
        if catch_active {
          live.union_into(catch_live)
        }
      }
      LocalGet(x) => live.add(x)
      LocalSet(x) | LocalTee(x) => {
        if record {
          let move_src : Int32 = if idx > 0 {
            match instrs[idx - 1] {
              LocalGet(s) => {
                add_move_affinity(aff, x, s)
                s.reinterpret_as_int()
              }
              _ => -1
            }
          } else {
            -1
          }
          record_interf_against_live(
            interf,
            x.reinterpret_as_int(),
            move_src,
            live,
            total_locals,
          )
        }
        live.remove(x)
        if catch_active {
          live.union_into(catch_live)
        }
      }
      Block(_, body) => {
        let exit_live = live.clone()
        label_stack.push(exit_live)
        live.copy_from(
          backward_liveness_interf(
            body, exit_live, label_stack, catch_live, catch_active, empty_bs, record,
            total_locals, interf, aff,
          ),
        )
        ignore(label_stack.pop())
        if catch_active {
          live.union_into(catch_live)
        }
      }
      If(_, then_b, else_b) => {
        let exit_live = live.clone()
        label_stack.push(exit_live)
        let lt = backward_liveness_interf(
          then_b, exit_live, label_stack, catch_live, catch_active, empty_bs, record,
          total_locals, interf, aff,
        )
        let le = if else_b.is_empty() {
          exit_live
        } else {
          backward_liveness_interf(
            else_b, exit_live, label_stack, catch_live, catch_active, empty_bs, record,
            total_locals, interf, aff,
          )
        }
        ignore(label_stack.pop())
        live.copy_from(lt)
        live.union_into(le)
        if catch_active {
          live.union_into(catch_live)
        }
      }
      Loop(_, body) => {
        let exit_live = live.clone()
        let head_live = LocalBitSet::new(num_words)
        let mut converged = false
        for _ in 0..<64 {
          label_stack.push(head_live)
          let cand = backward_liveness_interf(
            body, exit_live, label_stack, catch_live, catch_active, empty_bs, false,
            total_locals, interf, aff,
          )
          ignore(label_stack.pop())
          cand.union_into(head_live)
          if cand.equals(head_live) {
            converged = true
            break
          }
          head_live.copy_from(cand)
        }
        if !converged {
          collect_all_local_reads_bs(body, head_live)
          head_live.union_into(exit_live)
        }
        label_stack.push(head_live)
        live.copy_from(
          backward_liveness_interf(
            body, exit_live, label_stack, catch_live, catch_active, empty_bs, record,
            total_locals, interf, aff,
          ),
        )
        ignore(label_stack.pop())
        if catch_active {
          live.union_into(catch_live)
        }
      }
      TryTable(_, catches, body) => {
        let exit_live = live.clone()
        let inner_catch = catch_live.clone()
        for c in catches {
          let lbl = match c {
            Catch(_, l) | CatchRef(_, l) | CatchAll(l) | CatchAllRef(l) => l
          }
          inner_catch.union_into(label_bitset_at(label_stack, lbl, empty_bs))
        }
        let inner_active = catch_active || !inner_catch.is_zero()
        label_stack.push(exit_live)
        live.copy_from(
          backward_liveness_interf(
            body, exit_live, label_stack, inner_catch, inner_active, empty_bs, record,
            total_locals, interf, aff,
          ),
        )
        ignore(label_stack.pop())
        if catch_active {
          live.union_into(catch_live)
        }
      }
      _ => if catch_active { live.union_into(catch_live) }
    }
    idx -= 1
  }
  live
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

  let num_words = (total + 63) / 64
  let interf = FixedArray::makei(total, _ => LocalBitSet::new(num_words))
  let aff : Map[UInt32, Map[UInt32, Int32]] = Map([])
  let empty_bs = LocalBitSet::new(num_words)
  let label_stack : Array[LocalBitSet] = [empty_bs]
  let entry_live = backward_liveness_interf(
    fb.body,
    empty_bs,
    label_stack,
    empty_bs,
    false,
    empty_bs,
    true,
    total,
    interf,
    aff,
  )

  // All locals live at function entry (including parameters) mutually interfere
  let entry_list : Array[UInt32] = []
  for p in 0..<p_len {
    entry_list.push(p.reinterpret_as_uint())
  }
  for idx in p_len..<total {
    let v = idx.reinterpret_as_uint()
    if entry_live.contains(v) {
      entry_list.push(v)
    }
  }
  for i in 0..<entry_list.length() {
    for j in (i + 1)..<entry_list.length() {
      add_interf_edge_matrix(interf, entry_list[i], entry_list[j])
    }
  }

  // Color slots: 0..<p_len are fixed parameter slots; colors >= p_len are newly allocated non-param slots
  let color_type : Array[ValType] = []
  let color_members : Array[Array[UInt32]] = []
  let color_bitsets : Array[LocalBitSet] = []
  let assigned : Map[UInt32, Int32] = Map([])

  for p in 0..<p_len {
    let pu = p.reinterpret_as_uint()
    color_type.push(local_types[p])
    color_members.push([pu])
    let cbs = LocalBitSet::new(num_words)
    cbs.add(pu)
    color_bitsets.push(cbs)
    assigned[pu] = p
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
      let cbs = LocalBitSet::new(num_words)
      cbs.add(l)
      color_bitsets.push(cbs)
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
    let li = l.reinterpret_as_int()
    let vt = local_types[li]
    let row = interf[li]
    let mut best_color = -1
    let mut best_score = -1

    let aff_map = aff.get(l)
    for c in 0..<color_type.length() {
      if color_type[c] != vt {
        continue
      }
      if c >= p_len &&
        !color_members[c].is_empty() &&
        entry_live.contains(color_members[c][0]) {
        continue
      }
      if row.intersects(color_bitsets[c]) {
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
      color_bitsets[best_color].add(l)
      assigned[l] = best_color
    } else {
      let c = color_type.length()
      color_type.push(vt)
      color_members.push([l])
      let cbs = LocalBitSet::new(num_words)
      cbs.add(l)
      color_bitsets.push(cbs)
      assigned[l] = c
    }
  }

  let new_non_param_count = color_type.length() - p_len
  let old_non_param_count = total - p_len

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
fn pass_coalesce_locals_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let flat_types = mod.flat_types()
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      match build_func_local_types(mod, i, flat_types) {
        None => new_codes.push(fb)
        Some((pcnt, local_types)) => {
          let opt_fb = coalesce_func_locals(fb, pcnt, local_types)
          if !physical_equal(opt_fb, fb) && opt_fb != fb {
            changed = true
            out_changed[i] = true
            new_codes.push(opt_fb)
          } else {
            new_codes.push(fb)
          }
        }
      }
    } else {
      new_codes.push(fb)
    }
  }

  if !changed {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 12: BitSet interference-graph & copy-affinity greedy graph-coloring local slot coalescing.
/// Safely pins zero-init entry-live locals, preserves parameter ABI indices, and enforces exact ValType & size profitability.
pub fn pass_coalesce_locals(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_coalesce_locals_dirty(mod, None)
  next
}
