///|
fn write_heap_type(w : BinWriter, ht : HeapType) -> Unit {
  match ht {
    Abstract(b) => w.write_byte(b)
    Concrete(idx) => w.write_i64(idx.to_int64())
  }
}

///|
fn write_val_type(w : BinWriter, vt : ValType) -> Unit {
  match vt {
    I32 => w.write_byte(b'\x7F')
    I64 => w.write_byte(b'\x7E')
    F32 => w.write_byte(b'\x7D')
    F64 => w.write_byte(b'\x7C')
    V128 => w.write_byte(b'\x7B')
    ShortRef(b) => w.write_byte(b)
    RefNull(ht) => {
      w.write_byte(b'\x63')
      write_heap_type(w, ht)
    }
    Ref(ht) => {
      w.write_byte(b'\x64')
      write_heap_type(w, ht)
    }
  }
}

///|
fn write_storage_type(w : BinWriter, st : StorageType) -> Unit {
  match st {
    Val(vt) => write_val_type(w, vt)
    I8 => w.write_byte(b'\x78')
    I16 => w.write_byte(b'\x77')
  }
}

///|
fn write_field_type(w : BinWriter, ft : FieldType) -> Unit {
  write_storage_type(w, ft.storage)
  w.write_byte(if ft.mutable { b'\x01' } else { b'\x00' })
}

///|
fn write_comp_type(w : BinWriter, ct : CompType) -> Unit {
  match ct {
    Func(params, results) => {
      w.write_byte(b'\x60')
      w.write_u32(params.length().reinterpret_as_uint())
      for p in params {
        write_val_type(w, p)
      }
      w.write_u32(results.length().reinterpret_as_uint())
      for r in results {
        write_val_type(w, r)
      }
    }
    Struct(fields) => {
      w.write_byte(b'\x5F')
      w.write_u32(fields.length().reinterpret_as_uint())
      for f in fields {
        write_field_type(w, f)
      }
    }
    Array(field) => {
      w.write_byte(b'\x5E')
      write_field_type(w, field)
    }
  }
}

///|
fn write_sub_type(w : BinWriter, st : SubType) -> Unit {
  if st.explicit_sub || !st.is_final || !st.supers.is_empty() {
    w.write_byte(if st.is_final { b'\x4F' } else { b'\x50' })
    w.write_u32(st.supers.length().reinterpret_as_uint())
    for s in st.supers {
      w.write_u32(s)
    }
  }
  write_comp_type(w, st.comp)
}

///|
fn write_limits(w : BinWriter, lim : Limits) -> Unit {
  w.write_byte(lim.flags)
  let is_mem64 = (lim.flags.to_int() & 0x04) != 0
  if is_mem64 {
    w.write_u64(lim.min)
  } else {
    w.write_u32(lim.min.to_uint())
  }
  match lim.max {
    Some(mx) =>
      if is_mem64 {
        w.write_u64(mx)
      } else {
        w.write_u32(mx.to_uint())
      }
    None => ()
  }
}

///|
fn write_table_type(w : BinWriter, tt : TableType) -> Unit {
  match tt.init_expr {
    Some(expr) => {
      w.write_byte(b'\x40')
      w.write_byte(b'\x00')
      write_val_type(w, tt.elem_type)
      write_limits(w, tt.limits)
      write_expr(w, expr)
    }
    None => {
      write_val_type(w, tt.elem_type)
      write_limits(w, tt.limits)
    }
  }
}

///|
fn write_global_type(w : BinWriter, gt : GlobalType) -> Unit {
  write_val_type(w, gt.val_type)
  w.write_byte(if gt.mutable { b'\x01' } else { b'\x00' })
}

///|
fn write_tag_type(w : BinWriter, tt : TagType) -> Unit {
  w.write_byte(tt.attr)
  w.write_u32(tt.type_idx)
}

///|
fn write_block_type(w : BinWriter, bt : BlockType) -> Unit {
  match bt {
    Empty => w.write_byte(b'\x40')
    Val(vt) => write_val_type(w, vt)
    TypeIdx(idx) => w.write_i64(idx.to_int64())
  }
}

///|
fn write_mem_arg(w : BinWriter, ma : MemArg) -> Unit {
  if ma.mem_idx != 0U {
    w.write_u32(ma.align | 0x40U)
    w.write_u32(ma.mem_idx)
  } else {
    w.write_u32(ma.align)
  }
  w.write_u64(ma.offset)
}

///|
fn write_instr(w : BinWriter, instr : Instr) -> Unit {
  match instr {
    Unreachable => w.write_byte(b'\x00')
    Nop => w.write_byte(b'\x01')
    Block(bt, body) => {
      w.write_byte(b'\x02')
      write_block_type(w, bt)
      write_expr(w, body)
    }
    Loop(bt, body) => {
      w.write_byte(b'\x03')
      write_block_type(w, bt)
      write_expr(w, body)
    }
    If(bt, then_b, else_b) => {
      w.write_byte(b'\x04')
      write_block_type(w, bt)
      for ins in then_b {
        write_instr(w, ins)
      }
      if !else_b.is_empty() {
        w.write_byte(b'\x05')
        for ins in else_b {
          write_instr(w, ins)
        }
      }
      w.write_byte(b'\x0B')
    }
    Throw(tag) => {
      w.write_byte(b'\x08')
      w.write_u32(tag)
    }
    ThrowRef => w.write_byte(b'\x0A')
    Br(l) => {
      w.write_byte(b'\x0C')
      w.write_u32(l)
    }
    BrIf(l) => {
      w.write_byte(b'\x0D')
      w.write_u32(l)
    }
    BrTable(targets, def) => {
      w.write_byte(b'\x0E')
      w.write_u32(targets.length().reinterpret_as_uint())
      for t in targets {
        w.write_u32(t)
      }
      w.write_u32(def)
    }
    Return => w.write_byte(b'\x0F')
    Call(f) => {
      w.write_byte(b'\x10')
      w.write_u32(f)
    }
    CallIndirect(t, tbl) => {
      w.write_byte(b'\x11')
      w.write_u32(t)
      w.write_u32(tbl)
    }
    ReturnCall(f) => {
      w.write_byte(b'\x12')
      w.write_u32(f)
    }
    ReturnCallIndirect(t, tbl) => {
      w.write_byte(b'\x13')
      w.write_u32(t)
      w.write_u32(tbl)
    }
    CallRef(t) => {
      w.write_byte(b'\x14')
      w.write_u32(t)
    }
    ReturnCallRef(t) => {
      w.write_byte(b'\x15')
      w.write_u32(t)
    }
    Drop => w.write_byte(b'\x1A')
    Select => w.write_byte(b'\x1B')
    SelectTyped(ts) => {
      w.write_byte(b'\x1C')
      w.write_u32(ts.length().reinterpret_as_uint())
      for t in ts {
        write_val_type(w, t)
      }
    }
    TryTable(bt, catches, body) => {
      w.write_byte(b'\x1F')
      write_block_type(w, bt)
      w.write_u32(catches.length().reinterpret_as_uint())
      for c in catches {
        match c {
          Catch(tag, lbl) => {
            w.write_byte(b'\x00')
            w.write_u32(tag)
            w.write_u32(lbl)
          }
          CatchRef(tag, lbl) => {
            w.write_byte(b'\x01')
            w.write_u32(tag)
            w.write_u32(lbl)
          }
          CatchAll(lbl) => {
            w.write_byte(b'\x02')
            w.write_u32(lbl)
          }
          CatchAllRef(lbl) => {
            w.write_byte(b'\x03')
            w.write_u32(lbl)
          }
        }
      }
      write_expr(w, body)
    }
    LocalGet(l) => {
      w.write_byte(b'\x20')
      w.write_u32(l)
    }
    LocalSet(l) => {
      w.write_byte(b'\x21')
      w.write_u32(l)
    }
    LocalTee(l) => {
      w.write_byte(b'\x22')
      w.write_u32(l)
    }
    GlobalGet(g) => {
      w.write_byte(b'\x23')
      w.write_u32(g)
    }
    GlobalSet(g) => {
      w.write_byte(b'\x24')
      w.write_u32(g)
    }
    TableGet(t) => {
      w.write_byte(b'\x25')
      w.write_u32(t)
    }
    TableSet(t) => {
      w.write_byte(b'\x26')
      w.write_u32(t)
    }
    MemOp(op, ma) => {
      w.write_byte(op)
      write_mem_arg(w, ma)
    }
    MemorySize(m) => {
      w.write_byte(b'\x3F')
      w.write_u32(m)
    }
    MemoryGrow(m) => {
      w.write_byte(b'\x40')
      w.write_u32(m)
    }
    I32Const(v) => {
      w.write_byte(b'\x41')
      w.write_i32(v)
    }
    I64Const(v) => {
      w.write_byte(b'\x42')
      w.write_i64(v)
    }
    F32Const(bits) => {
      w.write_byte(b'\x43')
      w.write_fixed_u32(bits)
    }
    F64Const(bits) => {
      w.write_byte(b'\x44')
      w.write_fixed_u64(bits)
    }
    NumOp(op) => w.write_byte(op)
    RefNull(ht) => {
      w.write_byte(b'\xD0')
      write_heap_type(w, ht)
    }
    RefIsNull => w.write_byte(b'\xD1')
    RefFunc(f) => {
      w.write_byte(b'\xD2')
      w.write_u32(f)
    }
    RefEq => w.write_byte(b'\xD3')
    RefAsNonNull => w.write_byte(b'\xD4')
    BrOnNull(l) => {
      w.write_byte(b'\xD5')
      w.write_u32(l)
    }
    BrOnNonNull(l) => {
      w.write_byte(b'\xD6')
      w.write_u32(l)
    }
    MiscSatTrunc(sub) => {
      w.write_byte(b'\xFC')
      w.write_u32(sub)
    }
    MemoryInit(d, m) => {
      w.write_byte(b'\xFC')
      w.write_u32(8U)
      w.write_u32(d)
      w.write_u32(m)
    }
    DataDrop(d) => {
      w.write_byte(b'\xFC')
      w.write_u32(9U)
      w.write_u32(d)
    }
    MemoryCopy(dst, src) => {
      w.write_byte(b'\xFC')
      w.write_u32(10U)
      w.write_u32(dst)
      w.write_u32(src)
    }
    MemoryFill(m) => {
      w.write_byte(b'\xFC')
      w.write_u32(11U)
      w.write_u32(m)
    }
    TableInit(e, t) => {
      w.write_byte(b'\xFC')
      w.write_u32(12U)
      w.write_u32(e)
      w.write_u32(t)
    }
    ElemDrop(e) => {
      w.write_byte(b'\xFC')
      w.write_u32(13U)
      w.write_u32(e)
    }
    TableCopy(dst, src) => {
      w.write_byte(b'\xFC')
      w.write_u32(14U)
      w.write_u32(dst)
      w.write_u32(src)
    }
    TableGrow(t) => {
      w.write_byte(b'\xFC')
      w.write_u32(15U)
      w.write_u32(t)
    }
    TableSize(t) => {
      w.write_byte(b'\xFC')
      w.write_u32(16U)
      w.write_u32(t)
    }
    TableFill(t) => {
      w.write_byte(b'\xFC')
      w.write_u32(17U)
      w.write_u32(t)
    }
    StructNew(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(0U)
      w.write_u32(t)
    }
    StructNewDefault(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(1U)
      w.write_u32(t)
    }
    StructGet(t, f) => {
      w.write_byte(b'\xFB')
      w.write_u32(2U)
      w.write_u32(t)
      w.write_u32(f)
    }
    StructGetS(t, f) => {
      w.write_byte(b'\xFB')
      w.write_u32(3U)
      w.write_u32(t)
      w.write_u32(f)
    }
    StructGetU(t, f) => {
      w.write_byte(b'\xFB')
      w.write_u32(4U)
      w.write_u32(t)
      w.write_u32(f)
    }
    StructSet(t, f) => {
      w.write_byte(b'\xFB')
      w.write_u32(5U)
      w.write_u32(t)
      w.write_u32(f)
    }
    ArrayNew(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(6U)
      w.write_u32(t)
    }
    ArrayNewDefault(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(7U)
      w.write_u32(t)
    }
    ArrayNewFixed(t, n) => {
      w.write_byte(b'\xFB')
      w.write_u32(8U)
      w.write_u32(t)
      w.write_u32(n)
    }
    ArrayNewData(t, d) => {
      w.write_byte(b'\xFB')
      w.write_u32(9U)
      w.write_u32(t)
      w.write_u32(d)
    }
    ArrayNewElem(t, e) => {
      w.write_byte(b'\xFB')
      w.write_u32(10U)
      w.write_u32(t)
      w.write_u32(e)
    }
    ArrayGet(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(11U)
      w.write_u32(t)
    }
    ArrayGetS(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(12U)
      w.write_u32(t)
    }
    ArrayGetU(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(13U)
      w.write_u32(t)
    }
    ArraySet(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(14U)
      w.write_u32(t)
    }
    ArrayLen => {
      w.write_byte(b'\xFB')
      w.write_u32(15U)
    }
    ArrayFill(t) => {
      w.write_byte(b'\xFB')
      w.write_u32(16U)
      w.write_u32(t)
    }
    ArrayCopy(dst, src) => {
      w.write_byte(b'\xFB')
      w.write_u32(17U)
      w.write_u32(dst)
      w.write_u32(src)
    }
    ArrayInitData(t, d) => {
      w.write_byte(b'\xFB')
      w.write_u32(18U)
      w.write_u32(t)
      w.write_u32(d)
    }
    ArrayInitElem(t, e) => {
      w.write_byte(b'\xFB')
      w.write_u32(19U)
      w.write_u32(t)
      w.write_u32(e)
    }
    RefTest(ht) => {
      w.write_byte(b'\xFB')
      w.write_u32(20U)
      write_heap_type(w, ht)
    }
    RefTestNull(ht) => {
      w.write_byte(b'\xFB')
      w.write_u32(21U)
      write_heap_type(w, ht)
    }
    RefCast(ht) => {
      w.write_byte(b'\xFB')
      w.write_u32(22U)
      write_heap_type(w, ht)
    }
    RefCastNull(ht) => {
      w.write_byte(b'\xFB')
      w.write_u32(23U)
      write_heap_type(w, ht)
    }
    BrOnCast(flags, lbl, ht1, ht2) => {
      w.write_byte(b'\xFB')
      w.write_u32(24U)
      w.write_byte(flags)
      w.write_u32(lbl)
      write_heap_type(w, ht1)
      write_heap_type(w, ht2)
    }
    BrOnCastFail(flags, lbl, ht1, ht2) => {
      w.write_byte(b'\xFB')
      w.write_u32(25U)
      w.write_byte(flags)
      w.write_u32(lbl)
      write_heap_type(w, ht1)
      write_heap_type(w, ht2)
    }
    AnyConvertExtern => {
      w.write_byte(b'\xFB')
      w.write_u32(26U)
    }
    ExternConvertAny => {
      w.write_byte(b'\xFB')
      w.write_u32(27U)
    }
    RefI31 => {
      w.write_byte(b'\xFB')
      w.write_u32(28U)
    }
    I31GetS => {
      w.write_byte(b'\xFB')
      w.write_u32(29U)
    }
    I31GetU => {
      w.write_byte(b'\xFB')
      w.write_u32(30U)
    }
    SimdV128Const(bs) => {
      w.write_byte(b'\xFD')
      w.write_u32(12U)
      w.write_bytes(bs)
    }
    SimdShuffle(bs) => {
      w.write_byte(b'\xFD')
      w.write_u32(13U)
      w.write_bytes(bs)
    }
    SimdMemOp(sub, ma) => {
      w.write_byte(b'\xFD')
      w.write_u32(sub)
      write_mem_arg(w, ma)
    }
    SimdMemLaneOp(sub, ma, lane) => {
      w.write_byte(b'\xFD')
      w.write_u32(sub)
      write_mem_arg(w, ma)
      w.write_byte(lane)
    }
    SimdLaneOp(sub, lane) => {
      w.write_byte(b'\xFD')
      w.write_u32(sub)
      w.write_byte(lane)
    }
    SimdSimpleOp(sub) => {
      w.write_byte(b'\xFD')
      w.write_u32(sub)
    }
  }
}

///|
fn write_expr(w : BinWriter, instrs : Array[Instr]) -> Unit {
  for ins in instrs {
    write_instr(w, ins)
  }
  w.write_byte(b'\x0B')
}

///|
fn encode_func_body(fb : FuncBody) -> Bytes {
  let w = BinWriter::new()
  w.write_u32(fb.locals.length().reinterpret_as_uint())
  for lg in fb.locals {
    w.write_u32(lg.count)
    write_val_type(w, lg.val_type)
  }
  write_expr(w, fb.body)
  w.to_bytes()
}

///|
fn encode_name_section(
  module_name : String,
  func_names : Map[UInt32, String],
) -> Bytes {
  let w = BinWriter::new()
  if !module_name.is_empty() {
    let sub = BinWriter::new()
    sub.write_name(module_name)
    w.write_section(b'\x00', sub.to_bytes())
  }
  if !func_names.is_empty() {
    let entries : Array[(UInt32, String)] = []
    for k, v in func_names {
      entries.push((k, v))
    }
    entries.sort_by((a, b) => a.0.compare(b.0))
    let sub = BinWriter::new()
    sub.write_u32(entries.length().reinterpret_as_uint())
    for pair in entries {
      sub.write_u32(pair.0)
      sub.write_name(pair.1)
    }
    w.write_section(b'\x01', sub.to_bytes())
  }
  w.to_bytes()
}

///|
fn uleb128_u32_len(val : UInt32) -> Int32 {
  let mut v = val
  let mut n = 1
  while v >= 0x80U {
    v = v >> 7
    n += 1
  }
  n
}

///|
fn code_section_total_len(body_lens : Array[Int32]) -> Int32 {
  if body_lens.is_empty() {
    return 0
  }
  let mut payload_len = uleb128_u32_len(
    body_lens.length().reinterpret_as_uint(),
  )
  for blen in body_lens {
    payload_len += uleb128_u32_len(blen.reinterpret_as_uint()) + blen
  }
  1 + uleb128_u32_len(payload_len.reinterpret_as_uint()) + payload_len
}

///|
fn encode_non_code_prefix_len(mod : WasmModule) -> Int32 {
  let out = BinWriter::new()
  write_module_prefix(mod, out)
  out.to_bytes().length()
}

///|
fn encode_non_code_suffix_len(mod : WasmModule) -> Int32 {
  let out = BinWriter::new()
  write_module_suffix(mod, out)
  out.to_bytes().length()
}

///|
fn write_module_prefix(mod : WasmModule, out : BinWriter) -> Unit {
  // Magic + version 1
  out.write_bytes(b"\x00\x61\x73\x6D\x01\x00\x00\x00")

  // 1. Type section
  if !mod.type_groups.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.type_groups.length().reinterpret_as_uint())
    for g in mod.type_groups {
      if g.explicit_rec || g.subtypes.length() != 1 {
        s.write_byte(b'\x4E')
        s.write_u32(g.subtypes.length().reinterpret_as_uint())
        for st in g.subtypes {
          write_sub_type(s, st)
        }
      } else {
        write_sub_type(s, g.subtypes[0])
      }
    }
    out.write_section(b'\x01', s.to_bytes())
  }

  // 2. Import section
  if !mod.imports.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.imports.length().reinterpret_as_uint())
    for imp in mod.imports {
      s.write_name(imp.mod_name)
      s.write_name(imp.field_name)
      match imp.desc {
        Func(tid) => {
          s.write_byte(b'\x00')
          s.write_u32(tid)
        }
        Table(tt) => {
          s.write_byte(b'\x01')
          write_table_type(s, tt)
        }
        Mem(lim) => {
          s.write_byte(b'\x02')
          write_limits(s, lim)
        }
        Global(gt) => {
          s.write_byte(b'\x03')
          write_global_type(s, gt)
        }
        Tag(tt) => {
          s.write_byte(b'\x04')
          write_tag_type(s, tt)
        }
      }
    }
    out.write_section(b'\x02', s.to_bytes())
  }

  // 3. Function section
  if !mod.func_types.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.func_types.length().reinterpret_as_uint())
    for tid in mod.func_types {
      s.write_u32(tid)
    }
    out.write_section(b'\x03', s.to_bytes())
  }

  // 4. Table section
  if !mod.tables.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.tables.length().reinterpret_as_uint())
    for tt in mod.tables {
      write_table_type(s, tt)
    }
    out.write_section(b'\x04', s.to_bytes())
  }

  // 5. Memory section
  if !mod.memories.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.memories.length().reinterpret_as_uint())
    for lim in mod.memories {
      write_limits(s, lim)
    }
    out.write_section(b'\x05', s.to_bytes())
  }

  // 13. Tag section (spec order: between Memory(5) and Global(6))
  if !mod.tags.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.tags.length().reinterpret_as_uint())
    for tt in mod.tags {
      write_tag_type(s, tt)
    }
    out.write_section(b'\x0D', s.to_bytes())
  }

  // 6. Global section
  if !mod.globals.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.globals.length().reinterpret_as_uint())
    for g in mod.globals {
      write_global_type(s, g.global_type)
      write_expr(s, g.init)
    }
    out.write_section(b'\x06', s.to_bytes())
  }

  // 7. Export section
  if !mod.exports.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.exports.length().reinterpret_as_uint())
    for exp in mod.exports {
      s.write_name(exp.name)
      s.write_byte(
        match exp.kind {
          Func => b'\x00'
          Table => b'\x01'
          Mem => b'\x02'
          Global => b'\x03'
          Tag => b'\x04'
        },
      )
      s.write_u32(exp.idx)
    }
    out.write_section(b'\x07', s.to_bytes())
  }

  // 8. Start section
  match mod.start_func {
    Some(idx) => {
      let s = BinWriter::new()
      s.write_u32(idx)
      out.write_section(b'\x08', s.to_bytes())
    }
    None => ()
  }

  // 9. Element section
  if !mod.elements.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.elements.length().reinterpret_as_uint())
    for el in mod.elements {
      s.write_u32(el.flags)
      let is_passive_or_decl = (el.flags & 1U) != 0U
      let has_explicit_table = !is_passive_or_decl && (el.flags & 2U) != 0U
      let uses_exprs = (el.flags & 4U) != 0U
      if has_explicit_table {
        s.write_u32(el.table_idx)
      }
      match el.offset {
        Some(expr) => write_expr(s, expr)
        None => ()
      }
      if el.flags == 1U || el.flags == 2U || el.flags == 3U {
        s.write_byte(el.elem_kind)
      } else if el.flags == 5U || el.flags == 6U || el.flags == 7U {
        match el.ref_type {
          Some(rt) => write_val_type(s, rt)
          None => s.write_byte(b'\x70')
        }
      }
      if uses_exprs {
        s.write_u32(el.init_exprs.length().reinterpret_as_uint())
        for expr in el.init_exprs {
          write_expr(s, expr)
        }
      } else {
        s.write_u32(el.func_indices.length().reinterpret_as_uint())
        for idx in el.func_indices {
          s.write_u32(idx)
        }
      }
    }
    out.write_section(b'\x09', s.to_bytes())
  }

  // 12. DataCount section (spec order: before Code(10))
  if mod.has_data_count {
    let s = BinWriter::new()
    s.write_u32(mod.datas.length().reinterpret_as_uint())
    out.write_section(b'\x0C', s.to_bytes())
  }
}

///|
fn write_module_suffix(mod : WasmModule, out : BinWriter) -> Unit {
  // 11. Data section
  if !mod.datas.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.datas.length().reinterpret_as_uint())
    for ds in mod.datas {
      s.write_u32(ds.flags)
      if ds.flags == 2U {
        s.write_u32(ds.mem_idx)
      }
      match ds.offset {
        Some(expr) => write_expr(s, expr)
        None => ()
      }
      s.write_u32(ds.data.length().reinterpret_as_uint())
      s.write_bytes(ds.data)
    }
    out.write_section(b'\x0B', s.to_bytes())
  }

  // 0. Custom sections
  for cs in mod.custom_sections {
    let s = BinWriter::new()
    s.write_name(cs.name)
    s.write_bytes(cs.payload)
    out.write_section(b'\x00', s.to_bytes())
  }
}

///|
/// Encode a `WasmModule` back into a spec-compliant WebAssembly 2.0 / WasmGC binary.
pub fn encode_module(mod : WasmModule) -> Bytes {
  let out = BinWriter::new()
  write_module_prefix(mod, out)

  // 10. Code section
  if !mod.codes.is_empty() {
    let s = BinWriter::new()
    s.write_u32(mod.codes.length().reinterpret_as_uint())
    for fb in mod.codes {
      let body_bytes = encode_func_body(fb)
      s.write_u32(body_bytes.length().reinterpret_as_uint())
      s.write_bytes(body_bytes)
    }
    out.write_section(b'\x0A', s.to_bytes())
  }

  write_module_suffix(mod, out)
  out.to_bytes()
}

///|
/// Rebuild the `"name"` custom section inside `mod.custom_sections` from `mod.module_name` and `mod.func_names`.
pub fn rebuild_name_custom_section(mod : WasmModule) -> Array[CustomSection] {
  let out : Array[CustomSection] = []
  let mut had_name = false
  for cs in mod.custom_sections {
    if cs.name == "name" {
      had_name = true
      let payload = encode_name_section(mod.module_name, mod.func_names)
      if !payload.is_empty() {
        out.push({ name: "name", payload, after_section: cs.after_section, })
      }
    } else {
      out.push(cs)
    }
  }
  if !had_name && (!mod.module_name.is_empty() || !mod.func_names.is_empty()) {
    let payload = encode_name_section(mod.module_name, mod.func_names)
    if !payload.is_empty() {
      out.push({ name: "name", payload, after_section: b'\x0B', })
    }
  }
  out
}
