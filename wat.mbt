///|
fn format_heap_type(ht : HeapType) -> String {
  match ht {
    Concrete(idx) => "\{idx}"
    Abstract(b) =>
      match b {
        b'\x70' => "func"
        b'\x6F' => "extern"
        b'\x6E' => "any"
        b'\x6D' => "eq"
        b'\x6C' => "i31"
        b'\x6B' => "struct"
        b'\x6A' => "array"
        b'\x71' => "none"
        b'\x72' => "noextern"
        b'\x73' => "nofunc"
        b'\x69' => "exn"
        b'\x74' => "noexn"
        _ => "heap_0x\{b.to_int()}"
      }
  }
}

///|
/// Render a WebAssembly value type in WAT syntax.
pub fn format_val_type(vt : ValType) -> String {
  match vt {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "v128"
    ShortRef(b) =>
      match b {
        b'\x70' => "funcref"
        b'\x6F' => "externref"
        b'\x6E' => "anyref"
        b'\x6D' => "eqref"
        b'\x6C' => "i31ref"
        b'\x6B' => "structref"
        b'\x6A' => "arrayref"
        b'\x71' => "nullref"
        b'\x72' => "nullexternref"
        b'\x73' => "nullfuncref"
        b'\x69' => "exnref"
        b'\x74' => "noexnref"
        _ => "ref_0x\{b.to_int()}"
      }
    RefNull(ht) => "(ref null \{format_heap_type(ht)})"
    Ref(ht) => "(ref \{format_heap_type(ht)})"
  }
}

///|
fn format_block_type(bt : BlockType) -> String {
  match bt {
    Empty => ""
    Val(vt) => " (result \{format_val_type(vt)})"
    TypeIdx(idx) => " (type \{idx})"
  }
}

///|
fn mem_op_name(op : Byte) -> String {
  match op {
    b'\x28' => "i32.load"
    b'\x29' => "i64.load"
    b'\x2A' => "f32.load"
    b'\x2B' => "f64.load"
    b'\x2C' => "i32.load8_s"
    b'\x2D' => "i32.load8_u"
    b'\x2E' => "i32.load16_s"
    b'\x2F' => "i32.load16_u"
    b'\x30' => "i64.load8_s"
    b'\x31' => "i64.load8_u"
    b'\x32' => "i64.load16_s"
    b'\x33' => "i64.load16_u"
    b'\x34' => "i64.load32_s"
    b'\x35' => "i64.load32_u"
    b'\x36' => "i32.store"
    b'\x37' => "i64.store"
    b'\x38' => "f32.store"
    b'\x39' => "f64.store"
    b'\x3A' => "i32.store8"
    b'\x3B' => "i32.store16"
    b'\x3C' => "i64.store8"
    b'\x3D' => "i64.store16"
    b'\x3E' => "i64.store32"
    _ => "mem_0x\{op.to_int()}"
  }
}

///|
fn num_op_name(op : Byte) -> String {
  match op {
    b'\x45' => "i32.eqz"
    b'\x46' => "i32.eq"
    b'\x47' => "i32.ne"
    b'\x48' => "i32.lt_s"
    b'\x49' => "i32.lt_u"
    b'\x4A' => "i32.gt_s"
    b'\x4B' => "i32.gt_u"
    b'\x4C' => "i32.le_s"
    b'\x4D' => "i32.le_u"
    b'\x4E' => "i32.ge_s"
    b'\x4F' => "i32.ge_u"
    b'\x50' => "i64.eqz"
    b'\x51' => "i64.eq"
    b'\x52' => "i64.ne"
    b'\x53' => "i64.lt_s"
    b'\x54' => "i64.lt_u"
    b'\x55' => "i64.gt_s"
    b'\x56' => "i64.gt_u"
    b'\x57' => "i64.le_s"
    b'\x58' => "i64.le_u"
    b'\x59' => "i64.ge_s"
    b'\x5A' => "i64.ge_u"
    b'\x5B' => "f32.eq"
    b'\x5C' => "f32.ne"
    b'\x5D' => "f32.lt"
    b'\x5E' => "f32.gt"
    b'\x5F' => "f32.le"
    b'\x60' => "f32.ge"
    b'\x61' => "f64.eq"
    b'\x62' => "f64.ne"
    b'\x63' => "f64.lt"
    b'\x64' => "f64.gt"
    b'\x65' => "f64.le"
    b'\x66' => "f64.ge"
    b'\x67' => "i32.clz"
    b'\x68' => "i32.ctz"
    b'\x69' => "i32.popcnt"
    b'\x6A' => "i32.add"
    b'\x6B' => "i32.sub"
    b'\x6C' => "i32.mul"
    b'\x6D' => "i32.div_s"
    b'\x6E' => "i32.div_u"
    b'\x6F' => "i32.rem_s"
    b'\x70' => "i32.rem_u"
    b'\x71' => "i32.and"
    b'\x72' => "i32.or"
    b'\x73' => "i32.xor"
    b'\x74' => "i32.shl"
    b'\x75' => "i32.shr_s"
    b'\x76' => "i32.shr_u"
    b'\x77' => "i32.rotl"
    b'\x78' => "i32.rotr"
    b'\x79' => "i64.clz"
    b'\x7A' => "i64.ctz"
    b'\x7B' => "i64.popcnt"
    b'\x7C' => "i64.add"
    b'\x7D' => "i64.sub"
    b'\x7E' => "i64.mul"
    b'\x7F' => "i64.div_s"
    b'\x80' => "i64.div_u"
    b'\x81' => "i64.rem_s"
    b'\x82' => "i64.rem_u"
    b'\x83' => "i64.and"
    b'\x84' => "i64.or"
    b'\x85' => "i64.xor"
    b'\x86' => "i64.shl"
    b'\x87' => "i64.shr_s"
    b'\x88' => "i64.shr_u"
    b'\x89' => "i64.rotl"
    b'\x8A' => "i64.rotr"
    b'\x8B' => "f32.abs"
    b'\x8C' => "f32.neg"
    b'\x8D' => "f32.ceil"
    b'\x8E' => "f32.floor"
    b'\x8F' => "f32.trunc"
    b'\x90' => "f32.nearest"
    b'\x91' => "f32.sqrt"
    b'\x92' => "f32.add"
    b'\x93' => "f32.sub"
    b'\x94' => "f32.mul"
    b'\x95' => "f32.div"
    b'\x96' => "f32.min"
    b'\x97' => "f32.max"
    b'\x98' => "f32.copysign"
    b'\x99' => "f64.abs"
    b'\x9A' => "f64.neg"
    b'\x9B' => "f64.ceil"
    b'\x9C' => "f64.floor"
    b'\x9D' => "f64.trunc"
    b'\x9E' => "f64.nearest"
    b'\x9F' => "f64.sqrt"
    b'\xA0' => "f64.add"
    b'\xA1' => "f64.sub"
    b'\xA2' => "f64.mul"
    b'\xA3' => "f64.div"
    b'\xA4' => "f64.min"
    b'\xA5' => "f64.max"
    b'\xA6' => "f64.copysign"
    b'\xA7' => "i32.wrap_i64"
    b'\xA8' => "i32.trunc_f32_s"
    b'\xA9' => "i32.trunc_f32_u"
    b'\xAA' => "i32.trunc_f64_s"
    b'\xAB' => "i32.trunc_f64_u"
    b'\xAC' => "i64.extend_i32_s"
    b'\xAD' => "i64.extend_i32_u"
    b'\xAE' => "i64.trunc_f32_s"
    b'\xAF' => "i64.trunc_f32_u"
    b'\xB0' => "i64.trunc_f64_s"
    b'\xB1' => "i64.trunc_f64_u"
    b'\xB2' => "f32.convert_i32_s"
    b'\xB3' => "f32.convert_i32_u"
    b'\xB4' => "f32.convert_i64_s"
    b'\xB5' => "f32.convert_i64_u"
    b'\xB6' => "f32.demote_f64"
    b'\xB7' => "f64.convert_i32_s"
    b'\xB8' => "f64.convert_i32_u"
    b'\xB9' => "f64.convert_i64_s"
    b'\xBA' => "f64.convert_i64_u"
    b'\xBB' => "f64.promote_f32"
    b'\xBC' => "i32.reinterpret_f32"
    b'\xBD' => "i64.reinterpret_f64"
    b'\xBE' => "f32.reinterpret_i32"
    b'\xBF' => "f64.reinterpret_i64"
    b'\xC0' => "i32.extend8_s"
    b'\xC1' => "i32.extend16_s"
    b'\xC2' => "i64.extend8_s"
    b'\xC3' => "i64.extend16_s"
    b'\xC4' => "i64.extend32_s"
    _ => "op_0x\{op.to_int()}"
  }
}

///|
fn indent_str(depth : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<depth {
    out.write_string("  ")
  }
  out.to_string()
}

///|
fn write_wat_instrs(
  out : StringBuilder,
  mod : WasmModule,
  instrs : Array[Instr],
  depth : Int32,
) -> Unit {
  let pad = indent_str(depth)
  for ins in instrs {
    match ins {
      Unreachable => out.write_string("\{pad}unreachable\n")
      Nop => out.write_string("\{pad}nop\n")
      Block(bt, body) => {
        out.write_string("\{pad}block\{format_block_type(bt)}\n")
        write_wat_instrs(out, mod, body, depth + 1)
        out.write_string("\{pad}end\n")
      }
      Loop(bt, body) => {
        out.write_string("\{pad}loop\{format_block_type(bt)}\n")
        write_wat_instrs(out, mod, body, depth + 1)
        out.write_string("\{pad}end\n")
      }
      If(bt, then_b, else_b) => {
        out.write_string("\{pad}if\{format_block_type(bt)}\n")
        write_wat_instrs(out, mod, then_b, depth + 1)
        if !else_b.is_empty() {
          out.write_string("\{pad}else\n")
          write_wat_instrs(out, mod, else_b, depth + 1)
        }
        out.write_string("\{pad}end\n")
      }
      TryTable(bt, catches, body) => {
        out.write_string(
          "\{pad}try_table\{format_block_type(bt)} ;; \{catches.length()} catch(es)\n",
        )
        write_wat_instrs(out, mod, body, depth + 1)
        out.write_string("\{pad}end\n")
      }
      Br(l) => out.write_string("\{pad}br \{l}\n")
      BrIf(l) => out.write_string("\{pad}br_if \{l}\n")
      BrTable(targets, def) => {
        let ts = targets.map(t => "\{t}").join(" ")
        out.write_string("\{pad}br_table \{ts} \{def}\n")
      }
      Return => out.write_string("\{pad}return\n")
      Call(f) => {
        let nm = mod.resolve_func_name(f)
        out.write_string("\{pad}call \{f} ;; \{nm}\n")
      }
      CallIndirect(t, tbl) =>
        out.write_string("\{pad}call_indirect (type \{t}) (table \{tbl})\n")
      ReturnCall(f) => {
        let nm = mod.resolve_func_name(f)
        out.write_string("\{pad}return_call \{f} ;; \{nm}\n")
      }
      ReturnCallIndirect(t, tbl) =>
        out.write_string(
          "\{pad}return_call_indirect (type \{t}) (table \{tbl})\n",
        )
      CallRef(t) => out.write_string("\{pad}call_ref \{t}\n")
      ReturnCallRef(t) => out.write_string("\{pad}return_call_ref \{t}\n")
      BrOnNull(l) => out.write_string("\{pad}br_on_null \{l}\n")
      BrOnNonNull(l) => out.write_string("\{pad}br_on_non_null \{l}\n")
      Throw(t) => out.write_string("\{pad}throw \{t}\n")
      ThrowRef => out.write_string("\{pad}throw_ref\n")
      Drop => out.write_string("\{pad}drop\n")
      Select => out.write_string("\{pad}select\n")
      SelectTyped(ts) => {
        let s = ts.map(format_val_type).join(" ")
        out.write_string("\{pad}select (result \{s})\n")
      }
      LocalGet(l) => out.write_string("\{pad}local.get \{l}\n")
      LocalSet(l) => out.write_string("\{pad}local.set \{l}\n")
      LocalTee(l) => out.write_string("\{pad}local.tee \{l}\n")
      GlobalGet(g) => out.write_string("\{pad}global.get \{g}\n")
      GlobalSet(g) => out.write_string("\{pad}global.set \{g}\n")
      TableGet(t) => out.write_string("\{pad}table.get \{t}\n")
      TableSet(t) => out.write_string("\{pad}table.set \{t}\n")
      MemOp(op, ma) => {
        let off = if ma.offset != 0UL { " offset=\{ma.offset}" } else { "" }
        let mem = if ma.mem_idx != 0U { " mem=\{ma.mem_idx}" } else { "" }
        out.write_string(
          "\{pad}\{mem_op_name(op)}\{mem}\{off} align=\{ma.align}\n",
        )
      }
      MemorySize(m) => out.write_string("\{pad}memory.size \{m}\n")
      MemoryGrow(m) => out.write_string("\{pad}memory.grow \{m}\n")
      I32Const(v) => out.write_string("\{pad}i32.const \{v}\n")
      I64Const(v) => out.write_string("\{pad}i64.const \{v}\n")
      F32Const(bits) =>
        out.write_string(
          "\{pad}f32.const \{Float::reinterpret_from_uint(bits)}\n",
        )
      F64Const(bits) =>
        out.write_string("\{pad}f64.const \{bits.reinterpret_as_double()}\n")
      NumOp(op) => out.write_string("\{pad}\{num_op_name(op)}\n")
      RefNull(ht) =>
        out.write_string("\{pad}ref.null \{format_heap_type(ht)}\n")
      RefIsNull => out.write_string("\{pad}ref.is_null\n")
      RefFunc(f) => {
        let nm = mod.resolve_func_name(f)
        out.write_string("\{pad}ref.func \{f} ;; \{nm}\n")
      }
      RefEq => out.write_string("\{pad}ref.eq\n")
      RefAsNonNull => out.write_string("\{pad}ref.as_non_null\n")
      MiscSatTrunc(sub) => out.write_string("\{pad}trunc_sat_\{sub}\n")
      MemoryInit(d, m) => out.write_string("\{pad}memory.init \{d} \{m}\n")
      DataDrop(d) => out.write_string("\{pad}data.drop \{d}\n")
      MemoryCopy(d, s) => out.write_string("\{pad}memory.copy \{d} \{s}\n")
      MemoryFill(m) => out.write_string("\{pad}memory.fill \{m}\n")
      TableInit(e, t) => out.write_string("\{pad}table.init \{e} \{t}\n")
      ElemDrop(e) => out.write_string("\{pad}elem.drop \{e}\n")
      TableCopy(d, s) => out.write_string("\{pad}table.copy \{d} \{s}\n")
      TableGrow(t) => out.write_string("\{pad}table.grow \{t}\n")
      TableSize(t) => out.write_string("\{pad}table.size \{t}\n")
      TableFill(t) => out.write_string("\{pad}table.fill \{t}\n")
      StructNew(t) => out.write_string("\{pad}struct.new \{t}\n")
      StructNewDefault(t) => out.write_string("\{pad}struct.new_default \{t}\n")
      StructGet(t, f) => out.write_string("\{pad}struct.get \{t} \{f}\n")
      StructGetS(t, f) => out.write_string("\{pad}struct.get_s \{t} \{f}\n")
      StructGetU(t, f) => out.write_string("\{pad}struct.get_u \{t} \{f}\n")
      StructSet(t, f) => out.write_string("\{pad}struct.set \{t} \{f}\n")
      ArrayNew(t) => out.write_string("\{pad}array.new \{t}\n")
      ArrayNewDefault(t) => out.write_string("\{pad}array.new_default \{t}\n")
      ArrayNewFixed(t, n) =>
        out.write_string("\{pad}array.new_fixed \{t} \{n}\n")
      ArrayNewData(t, d) => out.write_string("\{pad}array.new_data \{t} \{d}\n")
      ArrayNewElem(t, e) => out.write_string("\{pad}array.new_elem \{t} \{e}\n")
      ArrayGet(t) => out.write_string("\{pad}array.get \{t}\n")
      ArrayGetS(t) => out.write_string("\{pad}array.get_s \{t}\n")
      ArrayGetU(t) => out.write_string("\{pad}array.get_u \{t}\n")
      ArraySet(t) => out.write_string("\{pad}array.set \{t}\n")
      ArrayLen => out.write_string("\{pad}array.len\n")
      ArrayFill(t) => out.write_string("\{pad}array.fill \{t}\n")
      ArrayCopy(d, s) => out.write_string("\{pad}array.copy \{d} \{s}\n")
      ArrayInitData(t, d) =>
        out.write_string("\{pad}array.init_data \{t} \{d}\n")
      ArrayInitElem(t, e) =>
        out.write_string("\{pad}array.init_elem \{t} \{e}\n")
      RefTest(ht) =>
        out.write_string("\{pad}ref.test (ref \{format_heap_type(ht)})\n")
      RefTestNull(ht) =>
        out.write_string("\{pad}ref.test (ref null \{format_heap_type(ht)})\n")
      RefCast(ht) =>
        out.write_string("\{pad}ref.cast (ref \{format_heap_type(ht)})\n")
      RefCastNull(ht) =>
        out.write_string("\{pad}ref.cast (ref null \{format_heap_type(ht)})\n")
      BrOnCast(_, l, ht1, ht2) =>
        out.write_string(
          "\{pad}br_on_cast \{l} \{format_heap_type(ht1)} \{format_heap_type(ht2)}\n",
        )
      BrOnCastFail(_, l, ht1, ht2) =>
        out.write_string(
          "\{pad}br_on_cast_fail \{l} \{format_heap_type(ht1)} \{format_heap_type(ht2)}\n",
        )
      AnyConvertExtern => out.write_string("\{pad}any.convert_extern\n")
      ExternConvertAny => out.write_string("\{pad}extern.convert_any\n")
      RefI31 => out.write_string("\{pad}ref.i31\n")
      I31GetS => out.write_string("\{pad}i31.get_s\n")
      I31GetU => out.write_string("\{pad}i31.get_u\n")
      SimdV128Const(_) => out.write_string("\{pad}v128.const <16B>\n")
      SimdShuffle(_) => out.write_string("\{pad}i8x16.shuffle <16B>\n")
      SimdMemOp(sub, ma) =>
        out.write_string("\{pad}simd_mem_\{sub} offset=\{ma.offset}\n")
      SimdMemLaneOp(sub, ma, lane) =>
        out.write_string(
          "\{pad}simd_mem_lane_\{sub} offset=\{ma.offset} lane=\{lane.to_int()}\n",
        )
      SimdLaneOp(sub, lane) =>
        out.write_string("\{pad}simd_lane_\{sub} \{lane.to_int()}\n")
      SimdSimpleOp(sub) => out.write_string("\{pad}simd_op_\{sub}\n")
    }
  }
}

///|
/// Disassemble a defined function by its module-wide function index into readable WAT text.
pub fn disassemble_function(
  mod : WasmModule,
  func_idx : UInt32,
) -> String raise WasmError {
  let imp_cnt = mod.imported_func_count()
  guard func_idx >= imp_cnt else {
    raise InvalidInput(
      "function \{func_idx} is imported (\{mod.resolve_func_name(func_idx)}) and has no body",
    )
  }
  let def_i = func_idx.reinterpret_as_int() - imp_cnt.reinterpret_as_int()
  guard def_i >= 0 && def_i < mod.codes.length() else {
    raise InvalidInput("function index \{func_idx} out of range")
  }
  let fb = mod.codes[def_i]
  let tidx = mod.func_types[def_i]
  let name = mod.resolve_func_name(func_idx)
  let out = StringBuilder()
  out.write_string("(func (;\{func_idx};) ;; \{name}\n")
  let flat = mod.flat_types()
  let ti = tidx.reinterpret_as_int()
  if ti >= 0 && ti < flat.length() {
    match flat[ti].comp {
      Func(params, results) => {
        if !params.is_empty() {
          let ps = params.map(format_val_type).join(" ")
          out.write_string("  (param \{ps})\n")
        }
        if !results.is_empty() {
          let rs = results.map(format_val_type).join(" ")
          out.write_string("  (result \{rs})\n")
        }
      }
      _ => ()
    }
  }
  if !fb.locals.is_empty() {
    for lg in fb.locals {
      let vt = format_val_type(lg.val_type)
      out.write_string("  (local ;×\{lg.count}; \{vt})\n")
    }
  }
  write_wat_instrs(out, mod, fb.body, 1)
  out.write_string(")\n")
  out.to_string()
}

///|
/// Resolve a function by either numeric index string or name substring.
pub fn find_function_index(mod : WasmModule, query : String) -> UInt32? {
  let q = query.trim().to_owned()
  if q.is_empty() {
    return None
  }
  // Try numeric index first
  let mut all_digits = true
  let mut acc = 0U
  for ch in q {
    if ch >= '0' && ch <= '9' {
      acc = acc * 10U + (ch.to_int() - '0'.to_int()).reinterpret_as_uint()
    } else {
      all_digits = false
      break
    }
  }
  let imp_cnt = mod.imported_func_count()
  let total = imp_cnt + mod.codes.length().reinterpret_as_uint()
  if all_digits && acc < total {
    return Some(acc)
  }
  // Exact name match, then substring match among defined functions
  let mut partial : UInt32? = None
  for i in 0..<mod.codes.length() {
    let fidx = imp_cnt + i.reinterpret_as_uint()
    let nm = mod.resolve_func_name(fidx)
    if nm == q {
      return Some(fidx)
    }
    if partial is None && nm.contains(q) {
      partial = Some(fidx)
    }
  }
  partial
}
