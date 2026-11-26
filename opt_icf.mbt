///|
fn normalize_self_calls(
  instrs : Array[Instr],
  self_idx : UInt32,
) -> Array[Instr] {
  let sentinel = 0xFFFF_FFFFU
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      Call(f) => Call(if f == self_idx { sentinel } else { f })
      ReturnCall(f) => ReturnCall(if f == self_idx { sentinel } else { f })
      RefFunc(f) => RefFunc(if f == self_idx { sentinel } else { f })
      Block(bt, b) => Block(bt, normalize_self_calls(b, self_idx))
      Loop(bt, b) => Loop(bt, normalize_self_calls(b, self_idx))
      If(bt, t, e) =>
        If(
          bt,
          normalize_self_calls(t, self_idx),
          normalize_self_calls(e, self_idx),
        )
      TryTable(bt, c, b) => TryTable(bt, c, normalize_self_calls(b, self_idx))
      other => other
    }
    out.push(rw)
  }
  out
}

///|
fn bytes_hex_fingerprint(type_idx : UInt32, raw : Bytes) -> String {
  let mut h1 = 2166136261U ^ type_idx
  let mut h2 = 0x9E37_79B9U ^ raw.length().reinterpret_as_uint()
  for b in raw {
    let v = b.to_int().reinterpret_as_uint()
    h1 = (h1 ^ v) * 16777619U
    h2 = (h2 * 31U) ^ v
  }
  "\{type_idx}:\{raw.length()}:\{h1}:\{h2}"
}

///|
/// Pass 6: Identical Code Folding (ICF) — merge structurally identical defined functions and redirect all references.
pub fn pass_merge_funcs(mod : WasmModule) -> WasmModule {
  if mod.codes.length() < 2 {
    return mod
  }
  let imp_funcs = mod.imported_func_count()

  // Map fingerprint -> list of (canon_def_idx, canon_type_idx, canon_norm_bytes)
  let buckets : Map[String, Array[(Int32, UInt32, Bytes)]] = Map([])
  let redirect_def : Map[Int32, Int32] = Map([])
  let mut merged_count = 0

  for i, fb in mod.codes {
    let fidx = imp_funcs + i.reinterpret_as_uint()
    let tidx = mod.func_types[i]
    let norm_fb : FuncBody = {
      locals: fb.locals,
      body: normalize_self_calls(fb.body, fidx),
    }
    let norm_bytes = encode_func_body(norm_fb)
    let fp = bytes_hex_fingerprint(tidx, norm_bytes)
    match buckets.get(fp) {
      Some(list) => {
        let mut matched : Int32? = None
        for entry in list {
          if entry.1 == tidx && entry.2 == norm_bytes {
            matched = Some(entry.0)
            break
          }
        }
        match matched {
          Some(canon_def_i) => {
            redirect_def[i] = canon_def_i
            merged_count += 1
          }
          None => list.push((i, tidx, norm_bytes))
        }
      }
      None => buckets[fp] = [(i, tidx, norm_bytes)]
    }
  }

  if merged_count == 0 {
    return mod
  }

  // Assign dense indices to surviving (non-merged) defined functions
  let func_map : Map[UInt32, UInt32] = Map([])
  for i in 0U..<imp_funcs {
    func_map[i] = i
  }
  let surviving_def_to_new : Map[Int32, UInt32] = Map([])
  let kept_defs : Array[Int32] = []
  let mut next_func = imp_funcs
  for i in 0..<mod.codes.length() {
    if !redirect_def.contains(i) {
      surviving_def_to_new[i] = next_func
      func_map[imp_funcs + i.reinterpret_as_uint()] = next_func
      next_func += 1U
      kept_defs.push(i)
    }
  }
  for dup_i, canon_i in redirect_def {
    match surviving_def_to_new.get(canon_i) {
      Some(target_fidx) =>
        func_map[imp_funcs + dup_i.reinterpret_as_uint()] = target_fidx
      None => ()
    }
  }

  let empty_map : Map[UInt32, UInt32] = Map([])
  let new_func_types : Array[UInt32] = []
  let new_codes : Array[FuncBody] = []
  for def_i in kept_defs {
    new_func_types.push(mod.func_types[def_i])
    let fb = mod.codes[def_i]
    new_codes.push({
      locals: fb.locals,
      body: remap_instrs(fb.body, func_map, empty_map, empty_map),
    })
  }

  let new_tables = mod.tables.map(tt => {
    elem_type: tt.elem_type,
    limits: tt.limits,
    init_expr: match tt.init_expr {
      Some(ex) => Some(remap_instrs(ex, func_map, empty_map, empty_map))
      None => None
    },
  })

  let new_globals = mod.globals.map(gd => {
    global_type: gd.global_type,
    init: remap_instrs(gd.init, func_map, empty_map, empty_map),
  })

  let new_exports = mod.exports.map(exp => {
    let nidx = if exp.kind == Func {
      func_map.get(exp.idx).unwrap_or(exp.idx)
    } else {
      exp.idx
    }
    { name: exp.name, kind: exp.kind, idx: nidx, }
  })

  let new_start = match mod.start_func {
    Some(f) => Some(func_map.get(f).unwrap_or(f))
    None => None
  }

  let new_elements = mod.elements.map(el => {
    flags: el.flags,
    table_idx: el.table_idx,
    offset: match el.offset {
      Some(ex) => Some(remap_instrs(ex, func_map, empty_map, empty_map))
      None => None
    },
    elem_kind: el.elem_kind,
    ref_type: el.ref_type,
    func_indices: el.func_indices.map(f => func_map.get(f).unwrap_or(f)),
    init_exprs: el.init_exprs.map(ex => {
      remap_instrs(ex, func_map, empty_map, empty_map)
    }),
  })

  let new_datas = mod.datas.map(ds => {
    flags: ds.flags,
    mem_idx: ds.mem_idx,
    offset: match ds.offset {
      Some(ex) => Some(remap_instrs(ex, func_map, empty_map, empty_map))
      None => None
    },
    data: ds.data,
  })

  let new_names : Map[UInt32, String] = Map([])
  for def_i in kept_defs {
    let old_f = imp_funcs + def_i.reinterpret_as_uint()
    match (mod.func_names.get(old_f), func_map.get(old_f)) {
      (Some(nm), Some(nf)) => new_names[nf] = nm
      _ => ()
    }
  }
  for i in 0U..<imp_funcs {
    match mod.func_names.get(i) {
      Some(nm) => new_names[i] = nm
      None => ()
    }
  }

  let updated : WasmModule = {
    ..mod,
    func_types: new_func_types,
    tables: new_tables,
    globals: new_globals,
    exports: new_exports,
    start_func: new_start,
    elements: new_elements,
    codes: new_codes,
    datas: new_datas,
    func_names: new_names,
  }
  let has_name_sec = mod.custom_sections.iter().any(cs => cs.name == "name")
  if has_name_sec {
    { ..updated, custom_sections: rebuild_name_custom_section(updated), }
  } else {
    updated
  }
}
