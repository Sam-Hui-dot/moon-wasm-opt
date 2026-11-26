///|
fn collect_heap_type_ref(ht : HeapType, live_types : Map[UInt32, Bool]) -> Unit {
  match ht {
    Concrete(t) => live_types[t] = true
    Abstract(_) => ()
  }
}

///|
fn collect_val_type_ref(vt : ValType, live_types : Map[UInt32, Bool]) -> Unit {
  match vt {
    RefNull(ht) | Ref(ht) => collect_heap_type_ref(ht, live_types)
    _ => ()
  }
}

///|
fn collect_block_type_ref(
  bt : BlockType,
  live_types : Map[UInt32, Bool],
) -> Unit {
  match bt {
    Empty => ()
    Val(vt) => collect_val_type_ref(vt, live_types)
    TypeIdx(t) => live_types[t] = true
  }
}

///|
fn collect_instr_refs(
  instrs : Array[Instr],
  live_funcs : Map[UInt32, Bool],
  live_globals : Map[UInt32, Bool],
  live_types : Map[UInt32, Bool],
) -> Unit {
  for ins in instrs {
    match ins {
      Block(bt, b) | Loop(bt, b) => {
        collect_block_type_ref(bt, live_types)
        collect_instr_refs(b, live_funcs, live_globals, live_types)
      }
      If(bt, t, e) => {
        collect_block_type_ref(bt, live_types)
        collect_instr_refs(t, live_funcs, live_globals, live_types)
        collect_instr_refs(e, live_funcs, live_globals, live_types)
      }
      TryTable(bt, _, b) => {
        collect_block_type_ref(bt, live_types)
        collect_instr_refs(b, live_funcs, live_globals, live_types)
      }
      Call(f) | ReturnCall(f) | RefFunc(f) => live_funcs[f] = true
      CallIndirect(t, _)
      | ReturnCallIndirect(t, _)
      | CallRef(t)
      | ReturnCallRef(t) => live_types[t] = true
      SelectTyped(ts) =>
        for vt in ts {
          collect_val_type_ref(vt, live_types)
        }
      GlobalGet(g) | GlobalSet(g) => live_globals[g] = true
      RefNull(ht)
      | RefTest(ht)
      | RefTestNull(ht)
      | RefCast(ht)
      | RefCastNull(ht) => collect_heap_type_ref(ht, live_types)
      BrOnCast(_, _, h1, h2) | BrOnCastFail(_, _, h1, h2) => {
        collect_heap_type_ref(h1, live_types)
        collect_heap_type_ref(h2, live_types)
      }
      StructNew(t)
      | StructNewDefault(t)
      | StructGet(t, _)
      | StructGetS(t, _)
      | StructGetU(t, _)
      | StructSet(t, _)
      | ArrayNew(t)
      | ArrayNewDefault(t)
      | ArrayNewFixed(t, _)
      | ArrayNewData(t, _)
      | ArrayNewElem(t, _)
      | ArrayGet(t)
      | ArrayGetS(t)
      | ArrayGetU(t)
      | ArraySet(t)
      | ArrayFill(t)
      | ArrayInitData(t, _)
      | ArrayInitElem(t, _) => live_types[t] = true
      ArrayCopy(t1, t2) => {
        live_types[t1] = true
        live_types[t2] = true
      }
      _ => ()
    }
  }
}

///|
fn remap_heap_type(ht : HeapType, type_map : Map[UInt32, UInt32]) -> HeapType {
  match ht {
    Concrete(t) => Concrete(type_map.get(t).unwrap_or(t))
    Abstract(b) => Abstract(b)
  }
}

///|
fn remap_val_type(vt : ValType, type_map : Map[UInt32, UInt32]) -> ValType {
  match vt {
    RefNull(ht) => RefNull(remap_heap_type(ht, type_map))
    Ref(ht) => Ref(remap_heap_type(ht, type_map))
    other => other
  }
}

///|
fn remap_block_type(
  bt : BlockType,
  type_map : Map[UInt32, UInt32],
) -> BlockType {
  match bt {
    Empty => Empty
    Val(vt) => Val(remap_val_type(vt, type_map))
    TypeIdx(t) => TypeIdx(type_map.get(t).unwrap_or(t))
  }
}

///|
fn remap_field_type(
  ft : FieldType,
  type_map : Map[UInt32, UInt32],
) -> FieldType {
  let ns : StorageType = match ft.storage {
    Val(vt) => Val(remap_val_type(vt, type_map))
    I8 => I8
    I16 => I16
  }
  { storage: ns, mutable: ft.mutable, }
}

///|
fn remap_sub_type(st : SubType, type_map : Map[UInt32, UInt32]) -> SubType {
  let n_supers = st.supers.map(s => type_map.get(s).unwrap_or(s))
  let n_comp : CompType = match st.comp {
    Func(ps, rs) =>
      Func(
        ps.map(v => remap_val_type(v, type_map)),
        rs.map(v => remap_val_type(v, type_map)),
      )
    Struct(fs) => Struct(fs.map(f => remap_field_type(f, type_map)))
    Array(f) => Array(remap_field_type(f, type_map))
  }
  {
    is_final: st.is_final,
    explicit_sub: st.explicit_sub,
    supers: n_supers,
    comp: n_comp,
  }
}

///|
fn remap_instrs(
  instrs : Array[Instr],
  func_map : Map[UInt32, UInt32],
  global_map : Map[UInt32, UInt32],
  type_map : Map[UInt32, UInt32],
) -> Array[Instr] {
  fn rf(f : UInt32) -> UInt32 {
    func_map.get(f).unwrap_or(f)
  }
  fn rg(g : UInt32) -> UInt32 {
    global_map.get(g).unwrap_or(g)
  }
  fn rt(t : UInt32) -> UInt32 {
    type_map.get(t).unwrap_or(t)
  }
  let out : Array[Instr] = []
  for ins in instrs {
    let rw : Instr = match ins {
      Block(bt, b) =>
        Block(
          remap_block_type(bt, type_map),
          remap_instrs(b, func_map, global_map, type_map),
        )
      Loop(bt, b) =>
        Loop(
          remap_block_type(bt, type_map),
          remap_instrs(b, func_map, global_map, type_map),
        )
      If(bt, t, e) =>
        If(
          remap_block_type(bt, type_map),
          remap_instrs(t, func_map, global_map, type_map),
          remap_instrs(e, func_map, global_map, type_map),
        )
      TryTable(bt, cs, b) =>
        TryTable(
          remap_block_type(bt, type_map),
          cs,
          remap_instrs(b, func_map, global_map, type_map),
        )
      Call(f) => Call(rf(f))
      ReturnCall(f) => ReturnCall(rf(f))
      RefFunc(f) => RefFunc(rf(f))
      CallIndirect(t, tbl) => CallIndirect(rt(t), tbl)
      ReturnCallIndirect(t, tbl) => ReturnCallIndirect(rt(t), tbl)
      CallRef(t) => CallRef(rt(t))
      ReturnCallRef(t) => ReturnCallRef(rt(t))
      SelectTyped(ts) => SelectTyped(ts.map(v => remap_val_type(v, type_map)))
      GlobalGet(g) => GlobalGet(rg(g))
      GlobalSet(g) => GlobalSet(rg(g))
      RefNull(ht) => RefNull(remap_heap_type(ht, type_map))
      RefTest(ht) => RefTest(remap_heap_type(ht, type_map))
      RefTestNull(ht) => RefTestNull(remap_heap_type(ht, type_map))
      RefCast(ht) => RefCast(remap_heap_type(ht, type_map))
      RefCastNull(ht) => RefCastNull(remap_heap_type(ht, type_map))
      BrOnCast(fl, l, h1, h2) =>
        BrOnCast(
          fl,
          l,
          remap_heap_type(h1, type_map),
          remap_heap_type(h2, type_map),
        )
      BrOnCastFail(fl, l, h1, h2) =>
        BrOnCastFail(
          fl,
          l,
          remap_heap_type(h1, type_map),
          remap_heap_type(h2, type_map),
        )
      StructNew(t) => StructNew(rt(t))
      StructNewDefault(t) => StructNewDefault(rt(t))
      StructGet(t, f) => StructGet(rt(t), f)
      StructGetS(t, f) => StructGetS(rt(t), f)
      StructGetU(t, f) => StructGetU(rt(t), f)
      StructSet(t, f) => StructSet(rt(t), f)
      ArrayNew(t) => ArrayNew(rt(t))
      ArrayNewDefault(t) => ArrayNewDefault(rt(t))
      ArrayNewFixed(t, n) => ArrayNewFixed(rt(t), n)
      ArrayNewData(t, d) => ArrayNewData(rt(t), d)
      ArrayNewElem(t, e) => ArrayNewElem(rt(t), e)
      ArrayGet(t) => ArrayGet(rt(t))
      ArrayGetS(t) => ArrayGetS(rt(t))
      ArrayGetU(t) => ArrayGetU(rt(t))
      ArraySet(t) => ArraySet(rt(t))
      ArrayFill(t) => ArrayFill(rt(t))
      ArrayCopy(t1, t2) => ArrayCopy(rt(t1), rt(t2))
      ArrayInitData(t, d) => ArrayInitData(rt(t), d)
      ArrayInitElem(t, e) => ArrayInitElem(rt(t), e)
      other => other
    }
    out.push(rw)
  }
  out
}

///|
/// Pass 1: Strip custom sections (optionally retaining the `"name"` section for readable disassembly).
pub fn pass_strip_custom(
  mod : WasmModule,
  keep_names~ : Bool = false,
) -> WasmModule {
  let kept : Array[CustomSection] = []
  if keep_names {
    for cs in mod.custom_sections {
      if cs.name == "name" {
        kept.push(cs)
      }
    }
  }
  { ..mod, custom_sections: kept, }
}

///|
/// Pass 5: Whole-module call-graph reachability GC eliminating dead functions, dead globals, and unused type groups.
pub fn pass_module_dce(mod : WasmModule) -> WasmModule {
  let imp_funcs = mod.imported_func_count()
  let imp_globals = mod.imported_global_count()

  let live_funcs : Map[UInt32, Bool] = Map([])
  let live_globals : Map[UInt32, Bool] = Map([])
  let live_types : Map[UInt32, Bool] = Map([])

  // Preserve all imported functions and imported globals (host ABI boundary)
  for i in 0U..<imp_funcs {
    live_funcs[i] = true
  }
  for i in 0U..<imp_globals {
    live_globals[i] = true
  }

  // Root set: exports, start, imports, tables, tags, elements, data offsets
  for imp in mod.imports {
    match imp.desc {
      Func(t) => live_types[t] = true
      Table(tt) => {
        collect_val_type_ref(tt.elem_type, live_types)
        match tt.init_expr {
          Some(expr) =>
            collect_instr_refs(expr, live_funcs, live_globals, live_types)
          None => ()
        }
      }
      Global(gt) => collect_val_type_ref(gt.val_type, live_types)
      Tag(tt) => live_types[tt.type_idx] = true
      Mem(_) => ()
    }
  }
  for tt in mod.tables {
    collect_val_type_ref(tt.elem_type, live_types)
    match tt.init_expr {
      Some(expr) =>
        collect_instr_refs(expr, live_funcs, live_globals, live_types)
      None => ()
    }
  }
  for tg in mod.tags {
    live_types[tg.type_idx] = true
  }
  for exp in mod.exports {
    match exp.kind {
      Func => live_funcs[exp.idx] = true
      Global => live_globals[exp.idx] = true
      _ => ()
    }
  }
  match mod.start_func {
    Some(f) => live_funcs[f] = true
    None => ()
  }
  for el in mod.elements {
    match el.offset {
      Some(expr) =>
        collect_instr_refs(expr, live_funcs, live_globals, live_types)
      None => ()
    }
    match el.ref_type {
      Some(rt) => collect_val_type_ref(rt, live_types)
      None => ()
    }
    for f in el.func_indices {
      live_funcs[f] = true
    }
    for expr in el.init_exprs {
      collect_instr_refs(expr, live_funcs, live_globals, live_types)
    }
  }
  for ds in mod.datas {
    match ds.offset {
      Some(expr) =>
        collect_instr_refs(expr, live_funcs, live_globals, live_types)
      None => ()
    }
  }

  // Fixpoint reachability over defined functions and defined globals
  let visited_funcs : Map[UInt32, Bool] = Map([])
  let visited_globals : Map[UInt32, Bool] = Map([])
  let mut progress = true
  while progress {
    progress = false
    for i, fb in mod.codes {
      let fidx = imp_funcs + i.reinterpret_as_uint()
      if live_funcs.contains(fidx) && !visited_funcs.contains(fidx) {
        visited_funcs[fidx] = true
        progress = true
        live_types[mod.func_types[i]] = true
        for lg in fb.locals {
          collect_val_type_ref(lg.val_type, live_types)
        }
        collect_instr_refs(fb.body, live_funcs, live_globals, live_types)
      }
    }
    for i, gd in mod.globals {
      let gidx = imp_globals + i.reinterpret_as_uint()
      if live_globals.contains(gidx) && !visited_globals.contains(gidx) {
        visited_globals[gidx] = true
        progress = true
        collect_val_type_ref(gd.global_type.val_type, live_types)
        collect_instr_refs(gd.init, live_funcs, live_globals, live_types)
      }
    }
  }

  // Transitive closure over WasmGC RecGroups (keep or drop each RecGroup atomically)
  let group_ranges : Array[(UInt32, UInt32)] = []
  let mut cur_tid = 0U
  for g in mod.type_groups {
    let start_t = cur_tid
    cur_tid += g.subtypes.length().reinterpret_as_uint()
    group_ranges.push((start_t, cur_tid))
  }
  let live_groups : Map[Int32, Bool] = Map([])
  let mut t_progress = true
  while t_progress {
    t_progress = false
    for gi, g in mod.type_groups {
      if live_groups.contains(gi) {
        continue
      }
      let (s_tid, e_tid) = group_ranges[gi]
      let mut needed = false
      for t in s_tid..<e_tid {
        if live_types.contains(t) {
          needed = true
          break
        }
      }
      if needed {
        live_groups[gi] = true
        t_progress = true
        for st in g.subtypes {
          for sup in st.supers {
            live_types[sup] = true
          }
          match st.comp {
            Func(ps, rs) => {
              for v in ps {
                collect_val_type_ref(v, live_types)
              }
              for v in rs {
                collect_val_type_ref(v, live_types)
              }
            }
            Struct(fs) =>
              for f in fs {
                match f.storage {
                  Val(vt) => collect_val_type_ref(vt, live_types)
                  _ => ()
                }
              }
            Array(f) =>
              match f.storage {
                Val(vt) => collect_val_type_ref(vt, live_types)
                _ => ()
              }
          }
        }
      }
    }
  }

  // Early exit if nothing can be removed
  if visited_funcs.length() == mod.codes.length() &&
    visited_globals.length() == mod.globals.length() &&
    live_groups.length() == mod.type_groups.length() {
    return mod
  }

  // Build dense remapping tables
  let func_map : Map[UInt32, UInt32] = Map([])
  for i in 0U..<imp_funcs {
    func_map[i] = i
  }
  let mut next_func = imp_funcs
  let kept_func_indices : Array[Int32] = []
  for i in 0..<mod.codes.length() {
    let old_f = imp_funcs + i.reinterpret_as_uint()
    if live_funcs.contains(old_f) {
      func_map[old_f] = next_func
      next_func += 1U
      kept_func_indices.push(i)
    }
  }

  let global_map : Map[UInt32, UInt32] = Map([])
  for i in 0U..<imp_globals {
    global_map[i] = i
  }
  let mut next_glob = imp_globals
  let kept_global_indices : Array[Int32] = []
  for i in 0..<mod.globals.length() {
    let old_g = imp_globals + i.reinterpret_as_uint()
    if live_globals.contains(old_g) {
      global_map[old_g] = next_glob
      next_glob += 1U
      kept_global_indices.push(i)
    }
  }

  let type_map : Map[UInt32, UInt32] = Map([])
  let mut next_type = 0U
  for gi, g in mod.type_groups {
    let (s_tid, _) = group_ranges[gi]
    if live_groups.contains(gi) {
      for off in 0..<g.subtypes.length() {
        type_map[s_tid + off.reinterpret_as_uint()] = next_type
        next_type += 1U
      }
    }
  }

  // Rebuild all module sections with remapped indices
  let new_type_groups : Array[RecGroup] = []
  for gi, g in mod.type_groups {
    if live_groups.contains(gi) {
      new_type_groups.push({
        explicit_rec: g.explicit_rec,
        subtypes: g.subtypes.map(st => remap_sub_type(st, type_map)),
      })
    }
  }

  let new_imports : Array[Import] = []
  for imp in mod.imports {
    let nd : ImportDesc = match imp.desc {
      Func(t) => Func(type_map.get(t).unwrap_or(t))
      Table(tt) =>
        Table({
          elem_type: remap_val_type(tt.elem_type, type_map),
          limits: tt.limits,
          init_expr: match tt.init_expr {
            Some(ex) => Some(remap_instrs(ex, func_map, global_map, type_map))
            None => None
          },
        })
      Global(gt) =>
        Global({
          val_type: remap_val_type(gt.val_type, type_map),
          mutable: gt.mutable,
        })
      Tag(tt) =>
        Tag({
          attr: tt.attr,
          type_idx: type_map.get(tt.type_idx).unwrap_or(tt.type_idx),
        })
      Mem(lim) => Mem(lim)
    }
    new_imports.push({
      mod_name: imp.mod_name,
      field_name: imp.field_name,
      desc: nd,
    })
  }

  let new_func_types : Array[UInt32] = []
  let new_codes : Array[FuncBody] = []
  for def_i in kept_func_indices {
    let old_t = mod.func_types[def_i]
    new_func_types.push(type_map.get(old_t).unwrap_or(old_t))
    let fb = mod.codes[def_i]
    let new_locals = fb.locals.map(lg => {
      count: lg.count,
      val_type: remap_val_type(lg.val_type, type_map),
    })
    new_codes.push({
      locals: new_locals,
      body: remap_instrs(fb.body, func_map, global_map, type_map),
    })
  }

  let new_tables = mod.tables.map(tt => {
    elem_type: remap_val_type(tt.elem_type, type_map),
    limits: tt.limits,
    init_expr: match tt.init_expr {
      Some(ex) => Some(remap_instrs(ex, func_map, global_map, type_map))
      None => None
    },
  })

  let new_tags = mod.tags.map(tg => {
    attr: tg.attr,
    type_idx: type_map.get(tg.type_idx).unwrap_or(tg.type_idx),
  })

  let new_globals : Array[GlobalDef] = []
  for gi in kept_global_indices {
    let gd = mod.globals[gi]
    new_globals.push({
      global_type: {
        val_type: remap_val_type(gd.global_type.val_type, type_map),
        mutable: gd.global_type.mutable,
      },
      init: remap_instrs(gd.init, func_map, global_map, type_map),
    })
  }

  let new_exports : Array[Export] = []
  for exp in mod.exports {
    let nidx = match exp.kind {
      Func => func_map.get(exp.idx).unwrap_or(exp.idx)
      Global => global_map.get(exp.idx).unwrap_or(exp.idx)
      _ => exp.idx
    }
    new_exports.push({ name: exp.name, kind: exp.kind, idx: nidx, })
  }

  let new_start = match mod.start_func {
    Some(f) => Some(func_map.get(f).unwrap_or(f))
    None => None
  }

  let new_elements : Array[ElemSegment] = []
  for el in mod.elements {
    new_elements.push({
      flags: el.flags,
      table_idx: el.table_idx,
      offset: match el.offset {
        Some(ex) => Some(remap_instrs(ex, func_map, global_map, type_map))
        None => None
      },
      elem_kind: el.elem_kind,
      ref_type: match el.ref_type {
        Some(rt) => Some(remap_val_type(rt, type_map))
        None => None
      },
      func_indices: el.func_indices.map(f => func_map.get(f).unwrap_or(f)),
      init_exprs: el.init_exprs.map(ex => {
        remap_instrs(ex, func_map, global_map, type_map)
      }),
    })
  }

  let new_datas : Array[DataSegment] = []
  for ds in mod.datas {
    new_datas.push({
      flags: ds.flags,
      mem_idx: ds.mem_idx,
      offset: match ds.offset {
        Some(ex) => Some(remap_instrs(ex, func_map, global_map, type_map))
        None => None
      },
      data: ds.data,
    })
  }

  let new_names : Map[UInt32, String] = Map([])
  for old_f, nm in mod.func_names {
    match func_map.get(old_f) {
      Some(nf) => new_names[nf] = nm
      None => ()
    }
  }

  let updated : WasmModule = {
    type_groups: new_type_groups,
    imports: new_imports,
    func_types: new_func_types,
    tables: new_tables,
    memories: mod.memories,
    tags: new_tags,
    globals: new_globals,
    exports: new_exports,
    start_func: new_start,
    elements: new_elements,
    has_data_count: mod.has_data_count,
    codes: new_codes,
    datas: new_datas,
    custom_sections: mod.custom_sections,
    module_name: mod.module_name,
    func_names: new_names,
  }
  let has_name_sec = mod.custom_sections.iter().any(cs => cs.name == "name")
  if has_name_sec {
    { ..updated, custom_sections: rebuild_name_custom_section(updated), }
  } else {
    updated
  }
}
