///|
fn canon_type_ref_key(
  t : UInt32,
  group_start : UInt32,
  group_end : UInt32,
  type_map : Map[UInt32, UInt32],
) -> String {
  if t >= group_start && t < group_end {
    "R\{t - group_start}"
  } else {
    let ct = type_map.get(t).unwrap_or(t)
    "E\{ct}"
  }
}

///|
fn canon_heap_type_key(
  ht : HeapType,
  group_start : UInt32,
  group_end : UInt32,
  type_map : Map[UInt32, UInt32],
) -> String {
  match ht {
    Abstract(b) => "A\{b.to_int()}"
    Concrete(t) =>
      "C(" + canon_type_ref_key(t, group_start, group_end, type_map) + ")"
  }
}

///|
fn canon_val_type_key(
  vt : ValType,
  group_start : UInt32,
  group_end : UInt32,
  type_map : Map[UInt32, UInt32],
) -> String {
  match vt {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "v128"
    ShortRef(b) => "sr\{b.to_int()}"
    RefNull(ht) =>
      "rn(" + canon_heap_type_key(ht, group_start, group_end, type_map) + ")"
    Ref(ht) =>
      "rf(" + canon_heap_type_key(ht, group_start, group_end, type_map) + ")"
  }
}

///|
fn canon_field_key(
  f : FieldType,
  group_start : UInt32,
  group_end : UInt32,
  type_map : Map[UInt32, UInt32],
) -> String {
  let st = match f.storage {
    I8 => "i8"
    I16 => "i16"
    Val(vt) => canon_val_type_key(vt, group_start, group_end, type_map)
  }
  let m = if f.mutable { "mut" } else { "imm" }
  "\{m}:\{st}"
}

///|
fn canon_rec_group_key(
  g : RecGroup,
  group_start : UInt32,
  type_map : Map[UInt32, UInt32],
) -> String {
  let group_end = group_start + g.subtypes.length().reinterpret_as_uint()
  let out = StringBuilder()
  out.write_string("rec[\{g.subtypes.length()}]{")
  for st in g.subtypes {
    out.write_string(if st.is_final { "F" } else { "O" })
    out.write_string("(")
    for si, sup in st.supers {
      if si > 0 {
        out.write_string(",")
      }
      out.write_string(
        canon_type_ref_key(sup, group_start, group_end, type_map),
      )
    }
    out.write_string("):")
    match st.comp {
      Func(ps, rs) => {
        out.write_string("fn(")
        for pi, p in ps {
          if pi > 0 {
            out.write_string(",")
          }
          out.write_string(
            canon_val_type_key(p, group_start, group_end, type_map),
          )
        }
        out.write_string(")->(")
        for ri, r in rs {
          if ri > 0 {
            out.write_string(",")
          }
          out.write_string(
            canon_val_type_key(r, group_start, group_end, type_map),
          )
        }
        out.write_string(");")
      }
      Struct(fs) => {
        out.write_string("st{")
        for fi, f in fs {
          if fi > 0 {
            out.write_string(",")
          }
          out.write_string(canon_field_key(f, group_start, group_end, type_map))
        }
        out.write_string("};")
      }
      Array(f) => {
        out.write_string("ar{")
        out.write_string(canon_field_key(f, group_start, group_end, type_map))
        out.write_string("};")
      }
    }
  }
  out.write_string("}")
  out.to_string()
}

///|
/// Pass 13a: WasmGC iso-recursive canonical `RecGroup` deduplication (also deduplicates Linear Wasm Func signatures and strips redundant 1-element `rec` wrappers).
pub fn pass_dedup_types(mod : WasmModule) -> WasmModule {
  if mod.type_groups.is_empty() {
    return mod
  }
  let seen_groups : Map[String, UInt32] = Map([])
  let type_map : Map[UInt32, UInt32] = Map([])
  let kept_groups : Array[RecGroup] = []
  let mut old_tid = 0U
  let mut new_tid = 0U
  let mut changed = false

  for g in mod.type_groups {
    let gl = g.subtypes.length().reinterpret_as_uint()
    let key = canon_rec_group_key(g, old_tid, type_map)
    match seen_groups.get(key) {
      Some(canon_start) => {
        changed = true
        for off in 0U..<gl {
          type_map[old_tid + off] = canon_start + off
        }
      }
      None => {
        let new_start = new_tid
        seen_groups[key] = new_start
        for off in 0U..<gl {
          let ot = old_tid + off
          let nt = new_start + off
          type_map[ot] = nt
          if ot != nt {
            changed = true
          }
        }
        // In WasmGC binary spec, a 1-subtype rec group is semantically identical without explicit `0x4E 0x01`
        let simplified_rec = g.subtypes.length() > 1
        if simplified_rec != g.explicit_rec {
          changed = true
        }
        kept_groups.push({
          explicit_rec: simplified_rec,
          subtypes: g.subtypes.map(st => remap_sub_type(st, type_map)),
        })
        new_tid += gl
      }
    }
    old_tid += gl
  }

  if !changed {
    return mod
  }

  let empty_map : Map[UInt32, UInt32] = Map([])

  let new_imports : Array[Import] = []
  for imp in mod.imports {
    let nd : ImportDesc = match imp.desc {
      Func(t) => Func(type_map.get(t).unwrap_or(t))
      Table(tt) =>
        Table({
          elem_type: remap_val_type(tt.elem_type, type_map),
          limits: tt.limits,
          init_expr: match tt.init_expr {
            Some(ex) => Some(remap_instrs(ex, empty_map, empty_map, type_map))
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

  let new_func_types = mod.func_types.map(t => type_map.get(t).unwrap_or(t))
  let new_tables = mod.tables.map(tt => {
    elem_type: remap_val_type(tt.elem_type, type_map),
    limits: tt.limits,
    init_expr: match tt.init_expr {
      Some(ex) => Some(remap_instrs(ex, empty_map, empty_map, type_map))
      None => None
    },
  })
  let new_tags = mod.tags.map(tg => {
    attr: tg.attr,
    type_idx: type_map.get(tg.type_idx).unwrap_or(tg.type_idx),
  })
  let new_globals = mod.globals.map(gd => {
    global_type: {
      val_type: remap_val_type(gd.global_type.val_type, type_map),
      mutable: gd.global_type.mutable,
    },
    init: remap_instrs(gd.init, empty_map, empty_map, type_map),
  })
  let new_elements = mod.elements.map(el => {
    flags: el.flags,
    table_idx: el.table_idx,
    offset: match el.offset {
      Some(ex) => Some(remap_instrs(ex, empty_map, empty_map, type_map))
      None => None
    },
    elem_kind: el.elem_kind,
    ref_type: match el.ref_type {
      Some(rt) => Some(remap_val_type(rt, type_map))
      None => None
    },
    func_indices: el.func_indices,
    init_exprs: el.init_exprs.map(ex => {
      remap_instrs(ex, empty_map, empty_map, type_map)
    }),
  })
  let new_codes = mod.codes.map(fb => {
    locals: fb.locals.map(lg => {
      count: lg.count,
      val_type: remap_val_type(lg.val_type, type_map),
    }),
    body: remap_instrs(fb.body, empty_map, empty_map, type_map),
  })

  {
    ..mod,
    type_groups: kept_groups,
    imports: new_imports,
    func_types: new_func_types,
    tables: new_tables,
    tags: new_tags,
    globals: new_globals,
    elements: new_elements,
    codes: new_codes,
  }
}

///|
fn is_heap_subtype(
  sub : HeapType,
  sup : HeapType,
  flat_types : Array[SubType],
) -> Bool {
  if sub == sup {
    return true
  }
  match (sub, sup) {
    // Bottom types
    (Abstract(b'\x71'), Abstract(s)) =>
      s == b'\x71' ||
      s == b'\x6B' ||
      s == b'\x6A' ||
      s == b'\x6C' ||
      s == b'\x6D' ||
      s == b'\x6E'
    (Abstract(b'\x71'), Concrete(t)) => {
      let i = t.reinterpret_as_int()
      if i >= 0 && i < flat_types.length() {
        match flat_types[i].comp {
          Struct(_) | Array(_) => true
          Func(_, _) => false
        }
      } else {
        false
      }
    }
    (Abstract(b'\x73'), Abstract(b'\x70')) => true
    (Abstract(b'\x73'), Concrete(t)) => {
      let i = t.reinterpret_as_int()
      if i >= 0 && i < flat_types.length() {
        match flat_types[i].comp {
          Func(_, _) => true
          _ => false
        }
      } else {
        false
      }
    }
    (Abstract(b'\x72'), Abstract(b'\x6F')) => true
    (Abstract(b'\x74'), Abstract(b'\x69')) => true
    // Abstract hierarchy: i31/struct/array <: eq <: any
    (Abstract(b'\x6C'), Abstract(s)) => s == b'\x6D' || s == b'\x6E'
    (Abstract(b'\x6B'), Abstract(s)) => s == b'\x6D' || s == b'\x6E'
    (Abstract(b'\x6A'), Abstract(s)) => s == b'\x6D' || s == b'\x6E'
    (Abstract(b'\x6D'), Abstract(b'\x6E')) => true
    // Concrete <: Abstract
    (Concrete(t), Abstract(s)) => {
      let i = t.reinterpret_as_int()
      if i >= 0 && i < flat_types.length() {
        match flat_types[i].comp {
          Struct(_) => s == b'\x6B' || s == b'\x6D' || s == b'\x6E'
          Array(_) => s == b'\x6A' || s == b'\x6D' || s == b'\x6E'
          Func(_, _) => s == b'\x70'
        }
      } else {
        false
      }
    }
    // Concrete <: Concrete via declared `supers` chain
    (Concrete(t), Concrete(target)) => {
      let visited : Set[UInt32] = Set([])
      let stack : Array[UInt32] = [t]
      let mut steps = 0
      while !stack.is_empty() && steps < 64 {
        steps += 1
        let cur = stack.pop().unwrap()
        if cur == target {
          return true
        }
        if visited.contains(cur) {
          continue
        }
        visited.add(cur)
        let ci = cur.reinterpret_as_int()
        if ci >= 0 && ci < flat_types.length() {
          for sup_t in flat_types[ci].supers {
            if !visited.contains(sup_t) {
              stack.push(sup_t)
            }
          }
        }
      }
      false
    }
    _ => false
  }
}

///|
fn valtype_to_ref_info(vt : ValType) -> (Bool, HeapType)? {
  match vt {
    Ref(ht) => Some((true, ht))
    RefNull(ht) => Some((false, ht))
    ShortRef(b) => Some((false, Abstract(b)))
    _ => None
  }
}

///|
fn build_all_global_types(mod : WasmModule) -> Array[ValType] {
  let out : Array[ValType] = []
  for imp in mod.imports {
    match imp.desc {
      Global(gt) => out.push(gt.val_type)
      _ => ()
    }
  }
  for gd in mod.globals {
    out.push(gd.global_type.val_type)
  }
  out
}

///|
/// Return the Wasm-validator-guaranteed static `(non_null, HeapType)` left on top of stack by `ins`, if statically known.
fn static_ref_of_instr(
  ins : Instr,
  local_types : Array[ValType],
  global_types : Array[ValType],
  flat_types : Array[SubType],
  mod : WasmModule,
) -> (Bool, HeapType)? {
  match ins {
    StructNew(t)
    | StructNewDefault(t)
    | ArrayNew(t)
    | ArrayNewDefault(t)
    | ArrayNewFixed(t, _)
    | ArrayNewData(t, _)
    | ArrayNewElem(t, _) => Some((true, Concrete(t)))
    RefI31 => Some((true, Abstract(b'\x6C')))
    RefFunc(fidx) =>
      match mod.func_type_index(fidx) {
        Some(tidx) => Some((true, Concrete(tidx)))
        None => None
      }
    RefNull(ht) => Some((false, ht))
    RefCast(ht) => Some((true, ht))
    RefCastNull(ht) => Some((false, ht))
    LocalGet(x) => {
      let i = x.reinterpret_as_int()
      if i >= 0 && i < local_types.length() {
        valtype_to_ref_info(local_types[i])
      } else {
        None
      }
    }
    GlobalGet(g) => {
      let i = g.reinterpret_as_int()
      if i >= 0 && i < global_types.length() {
        valtype_to_ref_info(global_types[i])
      } else {
        None
      }
    }
    StructGet(t, fi) => {
      let ti = t.reinterpret_as_int()
      let fidx = fi.reinterpret_as_int()
      if ti >= 0 && ti < flat_types.length() {
        match flat_types[ti].comp {
          Struct(fs) if fidx >= 0 && fidx < fs.length() =>
            match fs[fidx].storage {
              Val(vt) => valtype_to_ref_info(vt)
              _ => None
            }
          _ => None
        }
      } else {
        None
      }
    }
    ArrayGet(t) => {
      let ti = t.reinterpret_as_int()
      if ti >= 0 && ti < flat_types.length() {
        match flat_types[ti].comp {
          Array(f) =>
            match f.storage {
              Val(vt) => valtype_to_ref_info(vt)
              _ => None
            }
          _ => None
        }
      } else {
        None
      }
    }
    Call(fidx) =>
      match mod.func_type_index(fidx) {
        Some(tidx) => {
          let ti = tidx.reinterpret_as_int()
          if ti >= 0 && ti < flat_types.length() {
            match flat_types[ti].comp {
              Func(_, rs) if rs.length() == 1 => valtype_to_ref_info(rs[0])
              _ => None
            }
          } else {
            None
          }
        }
        None => None
      }
    _ => None
  }
}

///|
fn wasmgc_opt_seq(
  instrs : Array[Instr],
  local_types : Array[ValType],
  global_types : Array[ValType],
  flat_types : Array[SubType],
  mod : WasmModule,
) -> Array[Instr] {
  // Dynamic non-null heap refinement map for straight-line locals (ONLY used for RefIsNull / RefTest folding, never to delete validator-required RefCast)
  let dyn_nonnull : Map[UInt32, HeapType] = Map([])
  let out : Array[Instr] = []

  for raw_ins in instrs {
    match raw_ins {
      Block(bt, b) => {
        dyn_nonnull.clear()
        out.push(
          Block(
            bt,
            wasmgc_opt_seq(b, local_types, global_types, flat_types, mod),
          ),
        )
        continue
      }
      Loop(bt, b) => {
        dyn_nonnull.clear()
        out.push(
          Loop(
            bt,
            wasmgc_opt_seq(b, local_types, global_types, flat_types, mod),
          ),
        )
        continue
      }
      If(bt, t, e) => {
        dyn_nonnull.clear()
        out.push(
          If(
            bt,
            wasmgc_opt_seq(t, local_types, global_types, flat_types, mod),
            wasmgc_opt_seq(e, local_types, global_types, flat_types, mod),
          ),
        )
        continue
      }
      TryTable(bt, cs, b) => {
        dyn_nonnull.clear()
        out.push(
          TryTable(
            bt,
            cs,
            wasmgc_opt_seq(b, local_types, global_types, flat_types, mod),
          ),
        )
        continue
      }
      LocalSet(x) | LocalTee(x) => {
        let prev_info = if out.is_empty() {
          None
        } else {
          static_ref_of_instr(
            out[out.length() - 1],
            local_types,
            global_types,
            flat_types,
            mod,
          )
        }
        match prev_info {
          Some((true, ht)) => dyn_nonnull[x] = ht
          _ => dyn_nonnull.remove(x)
        }
        out.push(raw_ins)
        continue
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
        dyn_nonnull.clear()
        out.push(raw_ins)
        continue
      }
      _ => ()
    }

    out.push(raw_ins)
    let mut reduced = true
    while reduced && !out.is_empty() {
      reduced = false
      let n = out.length()
      // 3-instruction window: i32.const c; ref.i31; i31.get_s/u -> constant i32
      if n >= 3 {
        match (out[n - 3], out[n - 2], out[n - 1]) {
          (I32Const(c), RefI31, I31GetS) => {
            ignore(out.pop())
            ignore(out.pop())
            ignore(out.pop())
            out.push(I32Const(c << 1 >> 1))
            reduced = true
            continue
          }
          (I32Const(c), RefI31, I31GetU) => {
            ignore(out.pop())
            ignore(out.pop())
            ignore(out.pop())
            out.push(I32Const(c & 0x7FFF_FFFF))
            reduced = true
            continue
          }
          _ => ()
        }
      }

      if n >= 2 {
        match (out[n - 2], out[n - 1]) {
          // Devirtualize direct RefFunc + CallRef / ReturnCallRef
          (RefFunc(fidx), CallRef(_)) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(Call(fidx))
            reduced = true
            continue
          }
          (RefFunc(fidx), ReturnCallRef(_)) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(ReturnCall(fidx))
            reduced = true
            continue
          }
          // Cast chain fusion & idempotent casts
          (RefCast(h1), RefCast(h2)) if is_heap_subtype(h1, h2, flat_types) => {
            ignore(out.pop())
            reduced = true
            continue
          }
          (RefCast(h1), RefCastNull(h2)) if is_heap_subtype(h1, h2, flat_types) => {
            ignore(out.pop())
            reduced = true
            continue
          }
          (RefCast(_), RefAsNonNull) => {
            ignore(out.pop())
            reduced = true
            continue
          }
          (RefCastNull(h1), RefAsNonNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(RefCast(h1))
            reduced = true
            continue
          }
          (RefCastNull(h1), RefCast(h2)) if h1 == h2 => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(RefCast(h1))
            reduced = true
            continue
          }
          // Validator-safe static redundant RefAsNonNull / RefCast / RefCastNull elimination
          (prev, RefAsNonNull) =>
            match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((true, _)) => {
                ignore(out.pop())
                reduced = true
                continue
              }
              _ => ()
            }
          (prev, RefCast(ht)) =>
            match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((true, sub)) if is_heap_subtype(sub, ht, flat_types) => {
                ignore(out.pop())
                reduced = true
                continue
              }
              _ => ()
            }
          (prev, RefCastNull(ht)) =>
            match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((_, sub)) if is_heap_subtype(sub, ht, flat_types) => {
                ignore(out.pop())
                reduced = true
                continue
              }
              _ => ()
            }
          // Pure push + RefIsNull / RefTest / RefTestNull folding (safe with dynamic refinement because result is I32)
          (RefNull(_), RefIsNull) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(I32Const(1))
            reduced = true
            continue
          }
          (prev, RefIsNull) if is_pure_single_push(prev) => {
            let known_nn = match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((true, _)) => true
              _ =>
                match prev {
                  LocalGet(x) => dyn_nonnull.contains(x)
                  _ => false
                }
            }
            if known_nn {
              ignore(out.pop())
              ignore(out.pop())
              out.push(I32Const(0))
              reduced = true
              continue
            }
          }
          (prev, RefTest(ht)) if is_pure_single_push(prev) => {
            let known_sub = match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((true, sub)) => is_heap_subtype(sub, ht, flat_types)
              _ =>
                match prev {
                  LocalGet(x) =>
                    match dyn_nonnull.get(x) {
                      Some(sub) => is_heap_subtype(sub, ht, flat_types)
                      None => false
                    }
                  _ => false
                }
            }
            if known_sub {
              ignore(out.pop())
              ignore(out.pop())
              out.push(I32Const(1))
              reduced = true
              continue
            }
          }
          (prev, RefTestNull(ht)) if is_pure_single_push(prev) => {
            let known_sub = match
              static_ref_of_instr(
                prev, local_types, global_types, flat_types, mod,
              ) {
              Some((_, sub)) => is_heap_subtype(sub, ht, flat_types)
              None =>
                match prev {
                  LocalGet(x) =>
                    match dyn_nonnull.get(x) {
                      Some(sub) => is_heap_subtype(sub, ht, flat_types)
                      None => false
                    }
                  _ => false
                }
            }
            if known_sub {
              ignore(out.pop())
              ignore(out.pop())
              out.push(I32Const(1))
              reduced = true
              continue
            }
          }
          _ => ()
        }
      }
    }
  }
  out
}

///|
fn pass_wasmgc_opt_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let flat_types = mod.flat_types()
  let global_types = build_all_global_types(mod)
  let new_codes : Array[FuncBody] = []
  let mut changed = false

  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      let local_types = match build_func_local_types(mod, i, flat_types) {
        Some((_, lts)) => lts
        None => []
      }
      let nb = wasmgc_opt_seq(
        fb.body,
        local_types,
        global_types,
        flat_types,
        mod,
      )
      if nb != fb.body {
        changed = true
        out_changed[i] = true
        new_codes.push({ locals: fb.locals, body: nb, })
        continue
      }
    }
    new_codes.push(fb)
  }

  if !changed {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 13b: WasmGC static/dynamic reference optimization: redundant `ref.cast`/`ref.as_non_null` elimination, `call_ref` devirtualization, `ref.is_null`/`ref.test` folding, and `i31` constant folding.
pub fn pass_wasmgc_opt(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_wasmgc_opt_dirty(mod, None)
  next
}
