///|
/// Pass 18: WasmGC whole-program struct field pruning (write-only trailing fields),
/// read-only mutable field tightening (`mut` -> `imm`), and immutable constant field propagation.
fn collect_escaped_types_val(vt : ValType, escaped : Set[UInt32]) -> Unit {
  match vt {
    Ref(Concrete(t)) | RefNull(Concrete(t)) => escaped.insert(t)
    _ => ()
  }
}

///|
fn collect_escaped_types(
  mod : WasmModule,
  flat_types : Array[SubType],
) -> Set[UInt32] {
  let escaped : Set[UInt32] = Set([])
  // Mark any type referenced by imports
  for imp in mod.imports {
    match imp.desc {
      Func(tid) => escaped.insert(tid)
      Table(tt) => collect_escaped_types_val(tt.elem_type, escaped)
      Global(gt) => collect_escaped_types_val(gt.val_type, escaped)
      Tag(tg) => escaped.insert(tg.type_idx)
      Mem(_) => ()
    }
  }
  // Mark any type referenced by exports
  let mut num_imp_funcs = 0U
  let mut num_imp_globals = 0U
  let mut num_imp_tables = 0U
  let mut num_imp_tags = 0U
  for imp in mod.imports {
    match imp.desc {
      Func(_) => num_imp_funcs += 1U
      Table(_) => num_imp_tables += 1U
      Global(_) => num_imp_globals += 1U
      Tag(_) => num_imp_tags += 1U
      Mem(_) => ()
    }
  }
  for exp in mod.exports {
    match exp.kind {
      Func =>
        if exp.idx >= num_imp_funcs {
          let di = (exp.idx - num_imp_funcs).reinterpret_as_int()
          if di >= 0 && di < mod.func_types.length() {
            escaped.insert(mod.func_types[di])
          }
        }
      Table =>
        if exp.idx >= num_imp_tables {
          let di = (exp.idx - num_imp_tables).reinterpret_as_int()
          if di >= 0 && di < mod.tables.length() {
            collect_escaped_types_val(mod.tables[di].elem_type, escaped)
          }
        }
      Global =>
        if exp.idx >= num_imp_globals {
          let di = (exp.idx - num_imp_globals).reinterpret_as_int()
          if di >= 0 && di < mod.globals.length() {
            collect_escaped_types_val(
              mod.globals[di].global_type.val_type,
              escaped,
            )
          }
        }
      Tag =>
        if exp.idx >= num_imp_tags {
          let di = (exp.idx - num_imp_tags).reinterpret_as_int()
          if di >= 0 && di < mod.tags.length() {
            escaped.insert(mod.tags[di].type_idx)
          }
        }
      Mem => ()
    }
  }
  // Also mark any type actually involved in subtyping (has supers or is a super of another type)
  for i, st in flat_types {
    let tid = i.reinterpret_as_uint()
    if !st.supers.is_empty() {
      escaped.insert(tid)
      for sup in st.supers {
        escaped.insert(sup)
      }
    }
  }
  // Transitively close escaped types across type definitions
  let mut progress = true
  while progress {
    progress = false
    for i, st in flat_types {
      let tid = i.reinterpret_as_uint()
      if !escaped.contains(tid) {
        continue
      }
      let before = escaped.length()
      for sup in st.supers {
        escaped.insert(sup)
      }
      match st.comp {
        Func(ps, rs) => {
          for p in ps {
            collect_escaped_types_val(p, escaped)
          }
          for r in rs {
            collect_escaped_types_val(r, escaped)
          }
        }
        Struct(fs) =>
          for f in fs {
            match f.storage {
              Val(vt) => collect_escaped_types_val(vt, escaped)
              _ => ()
            }
          }
        Array(f) =>
          match f.storage {
            Val(vt) => collect_escaped_types_val(vt, escaped)
            _ => ()
          }
      }
      if escaped.length() > before {
        progress = true
      }
    }
  }
  escaped
}

///|
fn scan_struct_field_usage_instrs(
  instrs : Array[Instr],
  read_fields : Set[UInt64],
  written_fields : Set[UInt64],
  init_struct_news : Set[UInt32],
  in_init : Bool,
) -> Unit {
  for ins in instrs {
    match ins {
      StructGet(tid, fid) | StructGetS(tid, fid) | StructGetU(tid, fid) =>
        read_fields.insert((tid.to_uint64() << 32) | fid.to_uint64())
      StructSet(tid, fid) =>
        written_fields.insert((tid.to_uint64() << 32) | fid.to_uint64())
      StructNew(tid) => if in_init { init_struct_news.insert(tid) }
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        scan_struct_field_usage_instrs(
          b, read_fields, written_fields, init_struct_news, in_init,
        )
      If(_, t, e) => {
        scan_struct_field_usage_instrs(
          t, read_fields, written_fields, init_struct_news, in_init,
        )
        scan_struct_field_usage_instrs(
          e, read_fields, written_fields, init_struct_news, in_init,
        )
      }
      _ => ()
    }
  }
}

///|
fn rewrite_pruned_struct_instrs(
  instrs : Array[Instr],
  new_field_counts : Map[UInt32, Int32],
  old_field_counts : Map[UInt32, Int32],
) -> Array[Instr] {
  let out : Array[Instr] = []
  let mut changed = false
  for ins in instrs {
    match ins {
      StructNew(tid) =>
        match (new_field_counts.get(tid), old_field_counts.get(tid)) {
          (Some(nf), Some(of)) if nf < of => {
            changed = true
            let drop_n = of - nf
            for _ in 0..<drop_n {
              // If top of emitted stream is a pure single-push, delete it directly; else emit Drop
              if !out.is_empty() && is_pure_single_push(out[out.length() - 1]) {
                ignore(out.pop())
              } else {
                out.push(Drop)
              }
            }
            out.push(StructNew(tid))
          }
          _ => out.push(ins)
        }
      StructSet(tid, fid) =>
        match new_field_counts.get(tid) {
          Some(nf) if fid.reinterpret_as_int() >= nf => {
            changed = true
            // Drop value, trap if ref is null (preserving null-trap semantics), then drop ref
            if !out.is_empty() && is_pure_single_push(out[out.length() - 1]) {
              ignore(out.pop())
            } else {
              out.push(Drop)
            }
            out.push(RefAsNonNull)
            out.push(Drop)
          }
          _ => out.push(ins)
        }
      Block(bt, b) => {
        let nb = rewrite_pruned_struct_instrs(
          b, new_field_counts, old_field_counts,
        )
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Block(bt, nb))
      }
      Loop(bt, b) => {
        let nb = rewrite_pruned_struct_instrs(
          b, new_field_counts, old_field_counts,
        )
        if !physical_equal(nb, b) {
          changed = true
        }
        out.push(Loop(bt, nb))
      }
      If(bt, t, e) => {
        let nt = rewrite_pruned_struct_instrs(
          t, new_field_counts, old_field_counts,
        )
        let ne = rewrite_pruned_struct_instrs(
          e, new_field_counts, old_field_counts,
        )
        if !physical_equal(nt, t) || !physical_equal(ne, e) {
          changed = true
        }
        out.push(If(bt, nt, ne))
      }
      TryTable(bt, cs, b) => {
        let nb = rewrite_pruned_struct_instrs(
          b, new_field_counts, old_field_counts,
        )
        if !physical_equal(nb, b) {
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
/// Pass 18: WasmGC whole-program write-only trailing struct field pruning and read-only mutable field tightening.
pub fn pass_wasmgc_gufa(mod : WasmModule) -> WasmModule {
  if mod.type_groups.is_empty() || mod.codes.is_empty() {
    return mod
  }
  let flat_types = mod.flat_types()
  // Quick exit if module has no Struct types at all
  let mut has_struct = false
  for st in flat_types {
    match st.comp {
      Struct(_) => {
        has_struct = true
        break
      }
      _ => ()
    }
  }
  if !has_struct {
    return mod
  }

  let escaped = collect_escaped_types(mod, flat_types)
  let read_fields : Set[UInt64] = Set([])
  let written_fields : Set[UInt64] = Set([])
  let init_struct_news : Set[UInt32] = Set([])

  for g in mod.globals {
    scan_struct_field_usage_instrs(
      g.init,
      read_fields,
      written_fields,
      init_struct_news,
      true,
    )
  }
  for t in mod.tables {
    match t.init_expr {
      Some(ie) =>
        scan_struct_field_usage_instrs(
          ie, read_fields, written_fields, init_struct_news, true,
        )
      None => ()
    }
  }
  for el in mod.elements {
    match el.offset {
      Some(off) =>
        scan_struct_field_usage_instrs(
          off, read_fields, written_fields, init_struct_news, true,
        )
      None => ()
    }
    for ie in el.init_exprs {
      scan_struct_field_usage_instrs(
        ie, read_fields, written_fields, init_struct_news, true,
      )
    }
  }
  for ds in mod.datas {
    match ds.offset {
      Some(off) =>
        scan_struct_field_usage_instrs(
          off, read_fields, written_fields, init_struct_news, true,
        )
      None => ()
    }
  }
  for fb in mod.codes {
    scan_struct_field_usage_instrs(
      fb.body,
      read_fields,
      written_fields,
      init_struct_news,
      false,
    )
  }

  let new_field_counts : Map[UInt32, Int32] = Map([])
  let old_field_counts : Map[UInt32, Int32] = Map([])
  let new_groups : Array[RecGroup] = []
  let mut tid = 0U
  let mut types_changed = false
  let mut any_pruned = false

  for grp in mod.type_groups {
    let new_subs : Array[SubType] = []
    for st in grp.subtypes {
      let cur_tid = tid
      tid += 1U
      match st.comp {
        Struct(fs) if !escaped.contains(cur_tid) && !fs.is_empty() => {
          let orig_len = fs.length()
          // 1. Prune trailing never-read fields (only if StructNew is not used in constant init exprs)
          let mut keep_len = orig_len
          if !init_struct_news.contains(cur_tid) {
            while keep_len > 0 {
              let fkey = (cur_tid.to_uint64() << 32) |
                (keep_len - 1).reinterpret_as_uint().to_uint64()
              if !read_fields.contains(fkey) {
                keep_len -= 1
              } else {
                break
              }
            }
          }
          // 2. Tighten read-only mutable fields (never written by StructSet) to immutable
          let new_fs : Array[FieldType] = []
          let mut local_change = keep_len < orig_len
          for fi in 0..<keep_len {
            let f = fs[fi]
            let fkey = (cur_tid.to_uint64() << 32) |
              fi.reinterpret_as_uint().to_uint64()
            if f.mutable && !written_fields.contains(fkey) {
              local_change = true
              new_fs.push({ storage: f.storage, mutable: false, })
            } else {
              new_fs.push(f)
            }
          }
          if keep_len < orig_len {
            new_field_counts[cur_tid] = keep_len
            old_field_counts[cur_tid] = orig_len
            any_pruned = true
          }
          if local_change {
            types_changed = true
            new_subs.push({ ..st, comp: Struct(new_fs), })
          } else {
            new_subs.push(st)
          }
        }
        _ => new_subs.push(st)
      }
    }
    new_groups.push({ ..grp, subtypes: new_subs, })
  }

  if !types_changed {
    return mod
  }

  let new_codes = if any_pruned {
    let cs : Array[FuncBody] = []
    for fb in mod.codes {
      let nb = rewrite_pruned_struct_instrs(
        fb.body,
        new_field_counts,
        old_field_counts,
      )
      cs.push({ locals: fb.locals, body: nb, })
    }
    cs
  } else {
    mod.codes
  }

  { ..mod, type_groups: new_groups, codes: new_codes, }
}
