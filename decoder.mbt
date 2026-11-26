///|
fn is_short_ref_byte(b : Byte) -> Bool {
  let v = b.to_int()
  v >= 0x69 && v <= 0x74
}

///|
fn read_heap_type(r : BinReader) -> HeapType raise WasmError {
  let v = r.read_i64()
  if v < 0L {
    let b = (v & 0x7FL).to_int().to_byte()
    Abstract(b)
  } else {
    Concrete(v.reinterpret_as_uint64().to_uint())
  }
}

///|
fn read_val_type(r : BinReader) -> ValType raise WasmError {
  let b = r.read_byte()
  match b {
    b'\x7F' => I32
    b'\x7E' => I64
    b'\x7D' => F32
    b'\x7C' => F64
    b'\x7B' => V128
    b'\x63' => RefNull(read_heap_type(r))
    b'\x64' => Ref(read_heap_type(r))
    _ =>
      if is_short_ref_byte(b) {
        ShortRef(b)
      } else {
        raise InvalidBinary(
          "unknown value type 0x\{b.to_int()} at offset \{r.pos - 1}",
        )
      }
  }
}

///|
fn read_storage_type(r : BinReader) -> StorageType raise WasmError {
  let b = r.peek_byte()
  match b {
    b'\x78' => {
      ignore(r.read_byte())
      I8
    }
    b'\x77' => {
      ignore(r.read_byte())
      I16
    }
    _ => Val(read_val_type(r))
  }
}

///|
fn read_field_type(r : BinReader) -> FieldType raise WasmError {
  let storage = read_storage_type(r)
  let m = r.read_byte()
  guard m == b'\x00' || m == b'\x01' else {
    raise InvalidBinary("invalid field mutability \{m.to_int()}")
  }
  { storage, mutable: m == b'\x01', }
}

///|
fn read_comp_type(r : BinReader) -> CompType raise WasmError {
  let tag = r.read_byte()
  match tag {
    b'\x60' => {
      let pn = r.read_u32().reinterpret_as_int()
      let params : Array[ValType] = []
      for _ in 0..<pn {
        params.push(read_val_type(r))
      }
      let rn = r.read_u32().reinterpret_as_int()
      let results : Array[ValType] = []
      for _ in 0..<rn {
        results.push(read_val_type(r))
      }
      Func(params, results)
    }
    b'\x5F' => {
      let fn_cnt = r.read_u32().reinterpret_as_int()
      let fields : Array[FieldType] = []
      for _ in 0..<fn_cnt {
        fields.push(read_field_type(r))
      }
      Struct(fields)
    }
    b'\x5E' => Array(read_field_type(r))
    _ =>
      raise InvalidBinary(
        "unknown composite type tag 0x\{tag.to_int()} at offset \{r.pos - 1}",
      )
  }
}

///|
fn read_sub_type(r : BinReader) -> SubType raise WasmError {
  let b = r.peek_byte()
  if b == b'\x50' || b == b'\x4F' {
    ignore(r.read_byte())
    let is_final = b == b'\x4F'
    let sn = r.read_u32().reinterpret_as_int()
    let supers : Array[UInt32] = []
    for _ in 0..<sn {
      supers.push(r.read_u32())
    }
    let comp = read_comp_type(r)
    { is_final, explicit_sub: true, supers, comp, }
  } else {
    let comp = read_comp_type(r)
    { is_final: true, explicit_sub: false, supers: [], comp, }
  }
}

///|
fn read_limits(r : BinReader) -> Limits raise WasmError {
  let flags = r.read_byte()
  let f = flags.to_int()
  let is_mem64 = (f & 0x04) != 0
  let has_max = (f & 0x01) != 0
  let min = if is_mem64 { r.read_u64() } else { r.read_u32().to_uint64() }
  let max : UInt64? = if has_max {
    Some(if is_mem64 { r.read_u64() } else { r.read_u32().to_uint64() })
  } else {
    None
  }
  { flags, min, max, }
}

///|
fn read_table_type(
  r : BinReader,
  allow_init : Bool,
) -> TableType raise WasmError {
  if allow_init && r.peek_byte() == b'\x40' {
    ignore(r.read_byte())
    let zero = r.read_byte()
    guard zero == b'\x00' else {
      raise InvalidBinary("expected 0x00 after 0x40 table header")
    }
    let elem_type = read_val_type(r)
    let limits = read_limits(r)
    let init_expr = read_expr(r)
    { elem_type, limits, init_expr: Some(init_expr), }
  } else {
    let elem_type = read_val_type(r)
    let limits = read_limits(r)
    { elem_type, limits, init_expr: None, }
  }
}

///|
fn read_global_type(r : BinReader) -> GlobalType raise WasmError {
  let val_type = read_val_type(r)
  let m = r.read_byte()
  guard m == b'\x00' || m == b'\x01' else {
    raise InvalidBinary("invalid global mutability \{m.to_int()}")
  }
  { val_type, mutable: m == b'\x01', }
}

///|
fn read_tag_type(r : BinReader) -> TagType raise WasmError {
  let attr = r.read_byte()
  let type_idx = r.read_u32()
  { attr, type_idx, }
}

///|
fn read_block_type(r : BinReader) -> BlockType raise WasmError {
  let b = r.peek_byte()
  if b == b'\x40' {
    ignore(r.read_byte())
    return Empty
  }
  let bi = b.to_int()
  if (bi >= 0x7B && bi <= 0x7F) ||
    is_short_ref_byte(b) ||
    b == b'\x63' ||
    b == b'\x64' {
    return Val(read_val_type(r))
  }
  let idx = r.read_i64()
  guard idx >= 0L else {
    raise InvalidBinary("invalid negative block type index \{idx}")
  }
  TypeIdx(idx.reinterpret_as_uint64().to_uint())
}

///|
fn read_mem_arg(r : BinReader) -> MemArg raise WasmError {
  let raw_align = r.read_u32()
  if (raw_align & 0x40U) != 0U {
    let align = raw_align & 0x3FU
    let mem_idx = r.read_u32()
    let offset = r.read_u64()
    { align, offset, mem_idx, }
  } else {
    let offset = r.read_u64()
    { align: raw_align, offset, mem_idx: 0U, }
  }
}

///|
fn read_fc_instr(r : BinReader) -> Instr raise WasmError {
  let sub = r.read_u32()
  if sub <= 7U {
    MiscSatTrunc(sub)
  } else {
    match sub {
      8U => {
        let data_idx = r.read_u32()
        let mem_idx = r.read_u32()
        MemoryInit(data_idx, mem_idx)
      }
      9U => DataDrop(r.read_u32())
      10U => {
        let dst = r.read_u32()
        let src = r.read_u32()
        MemoryCopy(dst, src)
      }
      11U => MemoryFill(r.read_u32())
      12U => {
        let elem_idx = r.read_u32()
        let table_idx = r.read_u32()
        TableInit(elem_idx, table_idx)
      }
      13U => ElemDrop(r.read_u32())
      14U => {
        let dst = r.read_u32()
        let src = r.read_u32()
        TableCopy(dst, src)
      }
      15U => TableGrow(r.read_u32())
      16U => TableSize(r.read_u32())
      17U => TableFill(r.read_u32())
      _ => raise UnsupportedFeature("unsupported 0xFC sub-opcode \{sub}")
    }
  }
}

///|
fn read_fb_instr(r : BinReader) -> Instr raise WasmError {
  let sub = r.read_u32()
  match sub {
    0U => StructNew(r.read_u32())
    1U => StructNewDefault(r.read_u32())
    2U => {
      let tid = r.read_u32()
      let fid = r.read_u32()
      StructGet(tid, fid)
    }
    3U => {
      let tid = r.read_u32()
      let fid = r.read_u32()
      StructGetS(tid, fid)
    }
    4U => {
      let tid = r.read_u32()
      let fid = r.read_u32()
      StructGetU(tid, fid)
    }
    5U => {
      let tid = r.read_u32()
      let fid = r.read_u32()
      StructSet(tid, fid)
    }
    6U => ArrayNew(r.read_u32())
    7U => ArrayNewDefault(r.read_u32())
    8U => {
      let tid = r.read_u32()
      let len = r.read_u32()
      ArrayNewFixed(tid, len)
    }
    9U => {
      let tid = r.read_u32()
      let did = r.read_u32()
      ArrayNewData(tid, did)
    }
    10U => {
      let tid = r.read_u32()
      let eid = r.read_u32()
      ArrayNewElem(tid, eid)
    }
    11U => ArrayGet(r.read_u32())
    12U => ArrayGetS(r.read_u32())
    13U => ArrayGetU(r.read_u32())
    14U => ArraySet(r.read_u32())
    15U => ArrayLen
    16U => ArrayFill(r.read_u32())
    17U => {
      let dst = r.read_u32()
      let src = r.read_u32()
      ArrayCopy(dst, src)
    }
    18U => {
      let tid = r.read_u32()
      let did = r.read_u32()
      ArrayInitData(tid, did)
    }
    19U => {
      let tid = r.read_u32()
      let eid = r.read_u32()
      ArrayInitElem(tid, eid)
    }
    20U => RefTest(read_heap_type(r))
    21U => RefTestNull(read_heap_type(r))
    22U => RefCast(read_heap_type(r))
    23U => RefCastNull(read_heap_type(r))
    24U => {
      let flags = r.read_byte()
      let lbl = r.read_u32()
      let ht1 = read_heap_type(r)
      let ht2 = read_heap_type(r)
      BrOnCast(flags, lbl, ht1, ht2)
    }
    25U => {
      let flags = r.read_byte()
      let lbl = r.read_u32()
      let ht1 = read_heap_type(r)
      let ht2 = read_heap_type(r)
      BrOnCastFail(flags, lbl, ht1, ht2)
    }
    26U => AnyConvertExtern
    27U => ExternConvertAny
    28U => RefI31
    29U => I31GetS
    30U => I31GetU
    _ => raise UnsupportedFeature("unsupported 0xFB WasmGC sub-opcode \{sub}")
  }
}

///|
fn read_fd_instr(r : BinReader) -> Instr raise WasmError {
  let sub = r.read_u32()
  if sub <= 11U || sub == 92U || sub == 93U {
    SimdMemOp(sub, read_mem_arg(r))
  } else if sub == 12U {
    SimdV128Const(r.read_bytes(16))
  } else if sub == 13U {
    SimdShuffle(r.read_bytes(16))
  } else if sub >= 21U && sub <= 34U {
    SimdLaneOp(sub, r.read_byte())
  } else if sub >= 84U && sub <= 91U {
    let ma = read_mem_arg(r)
    let lane = r.read_byte()
    SimdMemLaneOp(sub, ma, lane)
  } else {
    SimdSimpleOp(sub)
  }
}

///|
fn read_instr_seq(
  r : BinReader,
  stop_on_else : Bool,
) -> (Array[Instr], Bool) raise WasmError {
  let out : Array[Instr] = []
  while true {
    let op = r.read_byte()
    if op == b'\x0B' {
      return (out, false)
    }
    if op == b'\x05' {
      guard stop_on_else else {
        raise InvalidBinary(
          "unexpected 0x05 else opcode at offset \{r.pos - 1}",
        )
      }
      return (out, true)
    }
    let oi = op.to_int()
    let instr : Instr = match op {
      b'\x00' => Unreachable
      b'\x01' => Nop
      b'\x02' => {
        let bt = read_block_type(r)
        let (body, _) = read_instr_seq(r, false)
        Block(bt, body)
      }
      b'\x03' => {
        let bt = read_block_type(r)
        let (body, _) = read_instr_seq(r, false)
        Loop(bt, body)
      }
      b'\x04' => {
        let bt = read_block_type(r)
        let (then_b, has_else) = read_instr_seq(r, true)
        let else_b = if has_else {
          let (eb, _) = read_instr_seq(r, false)
          eb
        } else {
          []
        }
        If(bt, then_b, else_b)
      }
      b'\x08' => Throw(r.read_u32())
      b'\x0A' => ThrowRef
      b'\x0C' => Br(r.read_u32())
      b'\x0D' => BrIf(r.read_u32())
      b'\x0E' => {
        let n = r.read_u32().reinterpret_as_int()
        let targets : Array[UInt32] = []
        for _ in 0..<n {
          targets.push(r.read_u32())
        }
        let def = r.read_u32()
        BrTable(targets, def)
      }
      b'\x0F' => Return
      b'\x10' => Call(r.read_u32())
      b'\x11' => {
        let type_idx = r.read_u32()
        let table_idx = r.read_u32()
        CallIndirect(type_idx, table_idx)
      }
      b'\x12' => ReturnCall(r.read_u32())
      b'\x13' => {
        let type_idx = r.read_u32()
        let table_idx = r.read_u32()
        ReturnCallIndirect(type_idx, table_idx)
      }
      b'\x14' => CallRef(r.read_u32())
      b'\x15' => ReturnCallRef(r.read_u32())
      b'\x1A' => Drop
      b'\x1B' => Select
      b'\x1C' => {
        let n = r.read_u32().reinterpret_as_int()
        let types : Array[ValType] = []
        for _ in 0..<n {
          types.push(read_val_type(r))
        }
        SelectTyped(types)
      }
      b'\x1F' => {
        let bt = read_block_type(r)
        let cn = r.read_u32().reinterpret_as_int()
        let catches : Array[CatchClause] = []
        for _ in 0..<cn {
          let kind = r.read_byte()
          match kind {
            b'\x00' => {
              let tag = r.read_u32()
              let lbl = r.read_u32()
              catches.push(Catch(tag, lbl))
            }
            b'\x01' => {
              let tag = r.read_u32()
              let lbl = r.read_u32()
              catches.push(CatchRef(tag, lbl))
            }
            b'\x02' => catches.push(CatchAll(r.read_u32()))
            b'\x03' => catches.push(CatchAllRef(r.read_u32()))
            _ =>
              raise InvalidBinary(
                "unknown try_table catch kind \{kind.to_int()}",
              )
          }
        }
        let (body, _) = read_instr_seq(r, false)
        TryTable(bt, catches, body)
      }
      b'\x20' => LocalGet(r.read_u32())
      b'\x21' => LocalSet(r.read_u32())
      b'\x22' => LocalTee(r.read_u32())
      b'\x23' => GlobalGet(r.read_u32())
      b'\x24' => GlobalSet(r.read_u32())
      b'\x25' => TableGet(r.read_u32())
      b'\x26' => TableSet(r.read_u32())
      b'\x3F' => MemorySize(r.read_u32())
      b'\x40' => MemoryGrow(r.read_u32())
      b'\x41' => I32Const(r.read_i32())
      b'\x42' => I64Const(r.read_i64())
      b'\x43' => F32Const(r.read_fixed_u32())
      b'\x44' => F64Const(r.read_fixed_u64())
      b'\xD0' => RefNull(read_heap_type(r))
      b'\xD1' => RefIsNull
      b'\xD2' => RefFunc(r.read_u32())
      b'\xD3' => RefEq
      b'\xD4' => RefAsNonNull
      b'\xD5' => BrOnNull(r.read_u32())
      b'\xD6' => BrOnNonNull(r.read_u32())
      b'\xFB' => read_fb_instr(r)
      b'\xFC' => read_fc_instr(r)
      b'\xFD' => read_fd_instr(r)
      _ =>
        if oi >= 0x28 && oi <= 0x3E {
          MemOp(op, read_mem_arg(r))
        } else if oi >= 0x45 && oi <= 0xC4 {
          NumOp(op)
        } else {
          raise UnsupportedFeature(
            "unsupported opcode 0x\{oi} at offset \{r.pos - 1}",
          )
        }
    }
    out.push(instr)
  }
  (out, false)
}

///|
fn read_expr(r : BinReader) -> Array[Instr] raise WasmError {
  let (instrs, _) = read_instr_seq(r, false)
  instrs
}

///|
fn parse_name_section(payload : Bytes) -> (String, Map[UInt32, String]) {
  let func_names : Map[UInt32, String] = Map([])
  let mut mod_name = ""
  let r = BinReader::new(payload)
  try {
    while !r.eof() {
      let sub_id = r.read_byte()
      let sub_len = r.read_u32().reinterpret_as_int()
      if sub_len < 0 || r.pos + sub_len > r.end {
        break
      }
      let sub_end = r.pos + sub_len
      let sub_r = BinReader::slice(payload, r.pos, sub_end)
      r.pos = sub_end
      if sub_id == b'\x00' {
        mod_name = sub_r.read_name()
      } else if sub_id == b'\x01' {
        let cnt = sub_r.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          if sub_r.eof() {
            break
          }
          let idx = sub_r.read_u32()
          let nm = sub_r.read_name()
          func_names[idx] = nm
        }
      }
    }
  } catch {
    _ => ()
  }
  (mod_name, func_names)
}

///|
/// Decode a WebAssembly 2.0 or WasmGC binary (`.wasm`) into a complete `WasmModule`.
pub fn decode_module(bytes : Bytes) -> WasmModule raise WasmError {
  guard bytes.length() >= 8 else {
    raise InvalidBinary("binary too short (\{bytes.length()} bytes)")
  }
  guard bytes[0] == b'\x00' &&
    bytes[1] == b'\x61' &&
    bytes[2] == b'\x73' &&
    bytes[3] == b'\x6D' else {
    raise InvalidBinary("missing \\0asm magic header")
  }
  guard bytes[4] == b'\x01' &&
    bytes[5] == b'\x00' &&
    bytes[6] == b'\x00' &&
    bytes[7] == b'\x00' else {
    raise InvalidBinary("unsupported wasm binary version")
  }

  let type_groups : Array[RecGroup] = []
  let imports : Array[Import] = []
  let func_types : Array[UInt32] = []
  let tables : Array[TableType] = []
  let memories : Array[Limits] = []
  let tags : Array[TagType] = []
  let globals : Array[GlobalDef] = []
  let exports : Array[Export] = []
  let mut start_func : UInt32? = None
  let elements : Array[ElemSegment] = []
  let mut has_data_count = false
  let mut expected_data_count : UInt32? = None
  let codes : Array[FuncBody] = []
  let datas : Array[DataSegment] = []
  let custom_sections : Array[CustomSection] = []
  let mut module_name = ""
  let mut func_names : Map[UInt32, String] = Map([])

  let r = BinReader::slice(bytes, 8, bytes.length())
  let mut last_std_section = b'\x00'

  while !r.eof() {
    let sec_id = r.read_byte()
    let sec_len = r.read_u32().reinterpret_as_int()
    guard sec_len >= 0 && r.pos + sec_len <= r.end else {
      raise InvalidBinary(
        "section \{sec_id.to_int()} length \{sec_len} exceeds file bounds",
      )
    }
    let sec_end = r.pos + sec_len
    let sr = BinReader::slice(bytes, r.pos, sec_end)
    r.pos = sec_end

    if sec_id != b'\x00' {
      last_std_section = sec_id
    }

    match sec_id {
      b'\x00' => {
        let cname = sr.read_name()
        let payload = sr.read_bytes(sr.remaining())
        if cname == "name" {
          let (mn, fnm) = parse_name_section(payload)
          if !mn.is_empty() {
            module_name = mn
          }
          func_names = fnm
        }
        custom_sections.push({
          name: cname,
          payload,
          after_section: last_std_section,
        })
      }
      b'\x01' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          if sr.peek_byte() == b'\x4E' {
            ignore(sr.read_byte())
            let gn = sr.read_u32().reinterpret_as_int()
            let subs : Array[SubType] = []
            for _ in 0..<gn {
              subs.push(read_sub_type(sr))
            }
            type_groups.push({ explicit_rec: true, subtypes: subs, })
          } else {
            type_groups.push({
              explicit_rec: false,
              subtypes: [read_sub_type(sr)],
            })
          }
        }
      }
      b'\x02' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let mod_name = sr.read_name()
          let field_name = sr.read_name()
          let kind = sr.read_byte()
          let desc : ImportDesc = match kind {
            b'\x00' => Func(sr.read_u32())
            b'\x01' => Table(read_table_type(sr, false))
            b'\x02' => Mem(read_limits(sr))
            b'\x03' => Global(read_global_type(sr))
            b'\x04' => Tag(read_tag_type(sr))
            _ => raise InvalidBinary("unknown import kind \{kind.to_int()}")
          }
          imports.push({ mod_name, field_name, desc, })
        }
      }
      b'\x03' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          func_types.push(sr.read_u32())
        }
      }
      b'\x04' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          tables.push(read_table_type(sr, true))
        }
      }
      b'\x05' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          memories.push(read_limits(sr))
        }
      }
      b'\x06' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let global_type = read_global_type(sr)
          let init = read_expr(sr)
          globals.push({ global_type, init, })
        }
      }
      b'\x07' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let name = sr.read_name()
          let k = sr.read_byte()
          let kind : ExportKind = match k {
            b'\x00' => Func
            b'\x01' => Table
            b'\x02' => Mem
            b'\x03' => Global
            b'\x04' => Tag
            _ => raise InvalidBinary("unknown export kind \{k.to_int()}")
          }
          let idx = sr.read_u32()
          exports.push({ name, kind, idx, })
        }
      }
      b'\x08' => start_func = Some(sr.read_u32())
      b'\x09' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let flags = sr.read_u32()
          guard flags <= 7U else {
            raise InvalidBinary("invalid element segment flags \{flags}")
          }
          let is_passive_or_decl = (flags & 1U) != 0U
          let has_explicit_table = !is_passive_or_decl && (flags & 2U) != 0U
          let uses_exprs = (flags & 4U) != 0U
          let table_idx = if has_explicit_table { sr.read_u32() } else { 0U }
          let offset : Array[Instr]? = if !is_passive_or_decl {
            Some(read_expr(sr))
          } else {
            None
          }
          let mut elem_kind = b'\x00'
          let mut ref_type : ValType? = None
          if flags == 1U || flags == 2U || flags == 3U {
            elem_kind = sr.read_byte()
          } else if flags == 5U || flags == 6U || flags == 7U {
            ref_type = Some(read_val_type(sr))
          }
          let func_indices : Array[UInt32] = []
          let init_exprs : Array[Array[Instr]] = []
          let item_cnt = sr.read_u32().reinterpret_as_int()
          if uses_exprs {
            for _ in 0..<item_cnt {
              init_exprs.push(read_expr(sr))
            }
          } else {
            for _ in 0..<item_cnt {
              func_indices.push(sr.read_u32())
            }
          }
          elements.push({
            flags,
            table_idx,
            offset,
            elem_kind,
            ref_type,
            func_indices,
            init_exprs,
          })
        }
      }
      b'\x0A' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let body_len = sr.read_u32().reinterpret_as_int()
          guard body_len >= 0 && sr.pos + body_len <= sr.end else {
            raise InvalidBinary("code body length \{body_len} out of bounds")
          }
          let body_end = sr.pos + body_len
          let br = BinReader::slice(bytes, sr.pos, body_end)
          sr.pos = body_end
          let local_cnt = br.read_u32().reinterpret_as_int()
          let locals : Array[LocalGroup] = []
          for _ in 0..<local_cnt {
            let lcnt = br.read_u32()
            let ltype = read_val_type(br)
            locals.push({ count: lcnt, val_type: ltype, })
          }
          let body = read_expr(br)
          guard br.eof() else {
            raise InvalidBinary(
              "trailing \{br.remaining()} bytes in function body",
            )
          }
          codes.push({ locals, body, })
        }
      }
      b'\x0B' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          let flags = sr.read_u32()
          let mut mem_idx = 0U
          let mut offset : Array[Instr]? = None
          match flags {
            0U => offset = Some(read_expr(sr))
            1U => ()
            2U => {
              mem_idx = sr.read_u32()
              offset = Some(read_expr(sr))
            }
            _ => raise InvalidBinary("invalid data segment flags \{flags}")
          }
          let dlen = sr.read_u32().reinterpret_as_int()
          let data = sr.read_bytes(dlen)
          datas.push({ flags, mem_idx, offset, data, })
        }
      }
      b'\x0C' => {
        has_data_count = true
        expected_data_count = Some(sr.read_u32())
      }
      b'\x0D' => {
        let cnt = sr.read_u32().reinterpret_as_int()
        for _ in 0..<cnt {
          tags.push(read_tag_type(sr))
        }
      }
      _ =>
        raise InvalidBinary(
          "unknown wasm section id \{sec_id.to_int()} at offset \{r.pos}",
        )
    }
    guard sr.eof() else {
      raise InvalidBinary(
        "trailing \{sr.remaining()} bytes in section \{sec_id.to_int()}",
      )
    }
  }

  guard func_types.length() == codes.length() else {
    raise InvalidBinary(
      "function section count (\{func_types.length()}) != code section count (\{codes.length()})",
    )
  }
  match expected_data_count {
    Some(ec) =>
      if ec.reinterpret_as_int() != datas.length() {
        raise InvalidBinary(
          "datacount (\{ec}) != data section count (\{datas.length()})",
        )
      }
    None => ()
  }

  {
    type_groups,
    imports,
    func_types,
    tables,
    memories,
    tags,
    globals,
    exports,
    start_func,
    elements,
    has_data_count,
    codes,
    datas,
    custom_sections,
    module_name,
    func_names,
  }
}
