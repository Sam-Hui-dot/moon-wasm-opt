///|
/// Pass 20: Structured Block Merging, Unused Block/Loop Unwrapping,
/// Trailing Redundant `br 0` Removal, and Identical `If/Else` Branch Folding.
fn strip_trailing_br0(body : Array[Instr]) -> Array[Instr] {
  if !body.is_empty() && body[body.length() - 1] == Br(0U) {
    Array::makei(body.length() - 1, i => body[i])
  } else {
    body
  }
}

///|
fn cfg_merge_seq(instrs : Array[Instr]) -> Array[Instr] {
  let out : Array[Instr] = []
  let mut changed = false

  for raw_ins in instrs {
    match raw_ins {
      Block(bt, body) => {
        let mut nb = cfg_merge_seq(body)
        if !physical_equal(nb, body) {
          changed = true
        }
        // 1. Strip redundant trailing `br 0` at the end of a Block
        let stripped = strip_trailing_br0(nb)
        if !physical_equal(stripped, nb) {
          changed = true
          nb = stripped
        }
        // 2. Unwrap Block if nothing inside branches to depth 0 (and block type has no params)
        let is_paramless = match bt {
          Empty | Val(_) => true
          TypeIdx(_) => false
        }
        if is_paramless && !instrs_branch_to_depth(nb, 0U) {
          changed = true
          for u in dec_branch_depths(nb, 1U) {
            out.push(u)
          }
          continue
        }
        // 3. Merge Block(bt, [Block(bt, inner)]) with identical block types (including Val(vt)!)
        if is_paramless && nb.length() == 1 {
          match nb[0] {
            Block(ibt, inner) if ibt == bt => {
              changed = true
              out.push(Block(bt, merge_nested_block_depths(inner, 0U)))
              continue
            }
            _ => ()
          }
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, body) => {
        let nb = cfg_merge_seq(body)
        if !physical_equal(nb, body) {
          changed = true
        }
        // Unwrap Loop that never branches back to depth 0 (not actually a loop!)
        let is_paramless = match bt {
          Empty | Val(_) => true
          TypeIdx(_) => false
        }
        if is_paramless && !instrs_branch_to_depth(nb, 0U) {
          changed = true
          for u in dec_branch_depths(nb, 1U) {
            out.push(u)
          }
          continue
        }
        out.push(Loop(bt, nb))
      }
      If(bt, then_b, else_b) => {
        let mut nt = cfg_merge_seq(then_b)
        let mut ne = cfg_merge_seq(else_b)
        if !physical_equal(nt, then_b) || !physical_equal(ne, else_b) {
          changed = true
        }
        // Strip redundant trailing `br 0` inside then/else branches
        let nt2 = strip_trailing_br0(nt)
        if !physical_equal(nt2, nt) {
          changed = true
          nt = nt2
        }
        let ne2 = strip_trailing_br0(ne)
        if !physical_equal(ne2, ne) {
          changed = true
          ne = ne2
        }
        // Fold identical then/else branches: If(bt, B, B) -> Drop; dec(B)
        let is_paramless = match bt {
          Empty | Val(_) => true
          TypeIdx(_) => false
        }
        if is_paramless && nt == ne && !instrs_branch_to_depth(nt, 0U) {
          changed = true
          out.push(Drop)
          for u in dec_branch_depths(nt, 1U) {
            out.push(u)
          }
          continue
        }
        out.push(If(bt, nt, ne))
      }
      TryTable(bt, cs, body) => {
        let nb = cfg_merge_seq(body)
        if !physical_equal(nb, body) {
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
fn pass_cfg_merge_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  let new_codes : Array[FuncBody] = []
  let mut any = false
  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      let nb = cfg_merge_seq(fb.body)
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
/// Pass 20: Block merging, unused block/loop unwrapping, trailing `br 0` removal, and identical branch folding.
pub fn pass_cfg_merge(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_cfg_merge_dirty(mod, None)
  next
}
