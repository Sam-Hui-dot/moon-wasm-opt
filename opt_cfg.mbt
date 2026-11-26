///|
fn merge_nested_block_depths(
  instrs : Array[Instr],
  depth : UInt32,
) -> Array[Instr] {
  fn adj(l : UInt32) -> UInt32 {
    if l == depth + 1U {
      depth
    } else if l > depth + 1U {
      l - 1U
    } else {
      l
    }
  }
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      Br(l) => Br(adj(l))
      BrIf(l) => BrIf(adj(l))
      BrOnNull(l) => BrOnNull(adj(l))
      BrOnNonNull(l) => BrOnNonNull(adj(l))
      BrOnCast(f, l, h1, h2) => BrOnCast(f, adj(l), h1, h2)
      BrOnCastFail(f, l, h1, h2) => BrOnCastFail(f, adj(l), h1, h2)
      BrTable(ts, d) => BrTable(ts.map(adj), adj(d))
      Block(bt, b) => Block(bt, merge_nested_block_depths(b, depth + 1U))
      Loop(bt, b) => Loop(bt, merge_nested_block_depths(b, depth + 1U))
      If(bt, t, e) =>
        If(
          bt,
          merge_nested_block_depths(t, depth + 1U),
          merge_nested_block_depths(e, depth + 1U),
        )
      TryTable(bt, catches, b) => {
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
        TryTable(bt, nc, merge_nested_block_depths(b, depth + 1U))
      }
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn trim_br_table_targets(
  targets : Array[UInt32],
  def_lbl : UInt32,
) -> Array[UInt32] {
  let mut end = targets.length()
  while end > 0 && targets[end - 1] == def_lbl {
    end -= 1
  }
  if end == targets.length() {
    targets
  } else {
    let out : Array[UInt32] = []
    for i in 0..<end {
      out.push(targets[i])
    }
    out
  }
}

///|
fn simplify_cfg_seq(instrs : Array[Instr]) -> Array[Instr] {
  let out : Array[Instr] = []
  for raw_ins in instrs {
    match raw_ins {
      Block(bt, body) => {
        let nb = simplify_cfg_seq(body)
        // Collapse Block(Empty, [Block(Empty, inner)]) -> Block(Empty, merged_inner)
        if bt == Empty && nb.length() == 1 {
          match nb[0] {
            Block(Empty, inner) => {
              out.push(Block(Empty, merge_nested_block_depths(inner, 0U)))
              continue
            }
            _ => ()
          }
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, body) => out.push(Loop(bt, simplify_cfg_seq(body)))
      TryTable(bt, cs, body) =>
        out.push(TryTable(bt, cs, simplify_cfg_seq(body)))
      BrTable(targets, def_lbl) => {
        let trimmed = trim_br_table_targets(targets, def_lbl)
        if trimmed.is_empty() {
          out.push(Drop)
          out.push(Br(def_lbl))
        } else {
          out.push(BrTable(trimmed, def_lbl))
        }
      }
      If(bt, then_b, else_b) => {
        let mut nt = simplify_cfg_seq(then_b)
        let mut ne = simplify_cfg_seq(else_b)

        // Invert condition when preceded by i32.eqz and else branch is non-empty
        if !ne.is_empty() &&
          !out.is_empty() &&
          out[out.length() - 1] == NumOp(b'\x45') {
          ignore(out.pop())
          let tmp = nt
          nt = ne
          ne = tmp
        }

        if bt == Empty {
          // Case 1: If(Empty, [Br(l)], []) -> BrIf(l-1) or Drop
          if nt.length() == 1 && ne.is_empty() {
            match nt[0] {
              Br(l) => {
                if l == 0U {
                  out.push(Drop)
                } else {
                  out.push(BrIf(l - 1U))
                }
                continue
              }
              _ => ()
            }
          }

          // Case 2: If(Empty, [], [Br(l)]) -> i32.eqz; BrIf(l-1) or Drop
          if nt.is_empty() && ne.length() == 1 {
            match ne[0] {
              Br(l) => {
                if l == 0U {
                  out.push(Drop)
                } else {
                  if !out.is_empty() && out[out.length() - 1] == NumOp(b'\x45') {
                    ignore(out.pop())
                  } else {
                    out.push(NumOp(b'\x45'))
                  }
                  out.push(BrIf(l - 1U))
                }
                continue
              }
              _ => ()
            }
          }

          // Case 3: If(Empty, [Br(l)], else_b) with no br 0 in else_b -> BrIf(l-1); else_b
          if nt.length() == 1 &&
            !ne.is_empty() &&
            !instrs_branch_to_depth(ne, 0U) {
            match nt[0] {
              Br(l) =>
                if l > 0U {
                  out.push(BrIf(l - 1U))
                  for u in dec_branch_depths(ne, 1U) {
                    out.push(u)
                  }
                  continue
                }
              _ => ()
            }
          }

          // Case 4: If(Empty, then_b, [Br(l)]) with no br 0 in then_b -> i32.eqz; BrIf(l-1); then_b
          if !nt.is_empty() &&
            ne.length() == 1 &&
            !instrs_branch_to_depth(nt, 0U) {
            match ne[0] {
              Br(l) =>
                if l > 0U {
                  if !out.is_empty() && out[out.length() - 1] == NumOp(b'\x45') {
                    ignore(out.pop())
                  } else {
                    out.push(NumOp(b'\x45'))
                  }
                  out.push(BrIf(l - 1U))
                  for u in dec_branch_depths(nt, 1U) {
                    out.push(u)
                  }
                  continue
                }
              _ => ()
            }
          }

          // Case 5: If(Empty, then_b, else_b) where then_b ends unconditionally and neither targets depth 0 -> lift else_b
          if !nt.is_empty() &&
            !ne.is_empty() &&
            is_unconditional_terminator(nt[nt.length() - 1]) &&
            !instrs_branch_to_depth(nt, 0U) &&
            !instrs_branch_to_depth(ne, 0U) {
            out.push(If(Empty, nt, []))
            for u in dec_branch_depths(ne, 1U) {
              out.push(u)
            }
            continue
          }
        }

        out.push(If(bt, nt, ne))
      }
      other => out.push(other)
    }
  }
  out
}

///|
/// Pass 9: Structured control-flow simplification (`eqz + if` inversion, `if -> br_if`, early-exit `else` flattening, `br_table` tail compaction, and nested block collapse).
pub fn pass_simplify_cfg(mod : WasmModule) -> WasmModule {
  let new_codes : Array[FuncBody] = []
  for fb in mod.codes {
    new_codes.push({ locals: fb.locals, body: simplify_cfg_seq(fb.body), })
  }
  { ..mod, codes: new_codes, }
}
