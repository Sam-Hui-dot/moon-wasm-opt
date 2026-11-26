///|
test "const-globals propagates immutable scalars and preserves WasmGC heap-allocating globals" {
  let struct_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Struct([{ storage: Val(I32), mutable: false, }]),
  }
  let fn_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [
      { explicit_rec: false, subtypes: [struct_t], },
      { explicit_rec: false, subtypes: [fn_t], },
    ],
    imports: [],
    func_types: [1U],
    tables: [],
    memories: [],
    tags: [],
    globals: [
      // g0: immutable i32 = 40 (propagated + deleted by module-dce)
      { global_type: { val_type: I32, mutable: false, }, init: [I32Const(40)], },
      // g1: immutable alias to g0 (transitively resolved to 40)
      {
        global_type: { val_type: I32, mutable: false, },
        init: [GlobalGet(0U)],
      },
      // g2: immutable WasmGC struct.new global (MUST NOT be propagated!)
      {
        global_type: { val_type: Ref(Concrete(0U)), mutable: false, },
        init: [I32Const(7), StructNew(0U)],
      },
      // g3: mutable i32 global (MUST NOT be propagated!)
      { global_type: { val_type: I32, mutable: true, }, init: [I32Const(5)], },
    ],
    exports: [{ name: "compute", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [
          GlobalGet(0U),
          GlobalGet(1U),
          NumOp(b'\x6A'), // 40 + 40 -> folds to 80
          GlobalGet(2U),
          StructGet(0U, 0U),
          NumOp(b'\x6A'),
          GlobalGet(3U),
          NumOp(b'\x6A'),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let raw = @moon-wasm-opt.encode_module(m)
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(report.saved_bytes > 0)
  let dec = @moon-wasm-opt.decode_module(opt_bytes)
  // g0 and g1 propagated & eliminated; g2 (struct.new) and g3 (mutable) preserved!
  assert_eq(dec.globals.length(), 2)
  assert_eq(dec.globals[0].global_type.mutable, false)
  assert_eq(dec.globals[1].global_type.mutable, true)
  // First instruction is folded I32Const(80)
  assert_eq(dec.codes[0].body[0], I32Const(80))
}

///|
test "simplify-cfg folds integer cmp+eqz, preserves float NaN cmp+eqz, converts if->br_if, compacts br_table, and merges nested blocks" {
  let fn_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32, F64], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [{ explicit_rec: false, subtypes: [fn_t], }],
    imports: [],
    func_types: [0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "cfg_test", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [
          // Nested empty blocks -> single block
          Block(Empty, [
            Block(Empty, [
              // Integer cmp + eqz: (p0 < 10) == 0 -> p0 >= 10, then If(Empty, [Br(1)], []) -> BrIf(0)
              LocalGet(0U),
              I32Const(10),
              NumOp(b'\x48'), // i32.lt_s
              NumOp(b'\x45'), // i32.eqz -> folds to i32.ge_s (0x4E)
              If(Empty, [Br(1U)], []),
              // Float cmp + eqz: MUST NOT invert f64.lt (0x63) because of NaN!
              LocalGet(1U),
              F64Const(0UL),
              NumOp(b'\x63'), // f64.lt
              NumOp(b'\x45'), // i32.eqz -> must remain f64.lt (NOT f64.ge)
              If(Empty, [I32Const(99), Return], []),
              // Loop + Block with BrTable trailing duplicate default targets -> trims [0,1,1,1] to [0]
              Loop(Empty, [
                Block(Empty, [LocalGet(0U), BrTable([0U, 1U, 1U, 1U], 1U)]),
              ]),
            ]),
          ]),
          I32Const(42),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let raw = @moon-wasm-opt.encode_module(m)
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(report.saved_bytes > 0)
  let dec = @moon-wasm-opt.decode_module(opt_bytes)
  let body = dec.codes[0].body
  // Outer nested blocks merged into one Block(Empty, ...)
  guard body[0] is Block(Empty, inner) else {
    abort("expected merged outer Block")
  }
  // Int comparison folded to i32.ge_s (0x4E) followed directly by BrIf(0U)
  assert_eq(inner[2], NumOp(b'\x4E'))
  assert_eq(inner[3], BrIf(0U))
  // Float comparison kept as f64.lt (0x63) and NOT inverted to f64.ge (0x66)
  assert_eq(inner[6], NumOp(b'\x63'))
  // BrTable inside Loop/Block trimmed trailing defaults (length 1 instead of 4)
  let mut found_trimmed_table = false
  for ins in inner {
    match ins {
      Loop(_, lb) =>
        for lins in lb {
          match lins {
            Block(_, bb) =>
              for bins in bb {
                match bins {
                  BrTable(ts, d) => {
                    assert_eq(ts.length(), 1)
                    assert_eq(ts[0], 0U)
                    assert_eq(d, 1U)
                    found_trimmed_table = true
                  }
                  _ => ()
                }
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(found_trimmed_table)
}

///|
test "inline folds single-use helpers with return & loop-safe locals and handles WasmGC non-null ref params" {
  let struct_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Struct([{ storage: Val(I32), mutable: false, }]),
  }
  let fn_entry : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let fn_gc_get : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([Ref(Concrete(0U))], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [
      { explicit_rec: false, subtypes: [struct_t], },
      { explicit_rec: false, subtypes: [fn_entry], },
      { explicit_rec: false, subtypes: [fn_gc_get], },
    ],
    imports: [],
    func_types: [1U, 1U, 2U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "entry", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      // f0 (exported): calls single-use f1 (with return + default-init local) and tiny f2 (WasmGC ref param)
      { locals: [], body: [LocalGet(0U), Call(1U), StructNew(0U), Call(2U)], },
      // f1 (single-use internal): has a non-param i32 local relying on 0-init and an early return
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          If(Empty, [LocalGet(1U), I32Const(10), NumOp(b'\x6A'), Return], []),
          LocalGet(0U),
          I32Const(1),
          NumOp(b'\x6A'),
        ],
      },
      // f2 (single-use WasmGC non-null ref param): fast-path 1-param single-use getter
      { locals: [], body: [LocalGet(0U), StructGet(0U, 0U)], },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let raw = @moon-wasm-opt.encode_module(m)
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(report.saved_bytes > 0)
  // Both f1 and f2 were inlined into f0 and eliminated by module-dce -> 1 function left!
  assert_eq(report.after_funcs, 1)
  let dec = @moon-wasm-opt.decode_module(opt_bytes)
  assert_eq(dec.codes.length(), 1)
}

///|
test "opt-data trims active zero padding, splits long zero runs, and protects overlapping/passive segments" {
  // Build active segment with 8 leading zeros, 4 non-zero bytes, 24 internal zeros, 4 non-zero bytes, 8 trailing zeros
  let payload = Bytes::makei(48, i => {
    if i >= 8 && i < 12 {
      (i + 1).to_byte()
    } else if i >= 36 && i < 40 {
      (i + 1).to_byte()
    } else {
      b'\x00'
    }
  })
  // Build overlapping segment: seg1 writes non-zero at 100..108, seg2 overwrites 104..108 with zeros (MUST NOT trim seg2!)
  let seg1_data = b"\x01\x02\x03\x04\x05\x06\x07\x08"
  let seg2_zeros = b"\x00\x00\x00\x00"

  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [],
    imports: [],
    func_types: [],
    tables: [],
    memories: [{ flags: b'\x00', min: 1UL, max: None, }],
    tags: [],
    globals: [],
    exports: [{ name: "mem", kind: Mem, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: true,
    codes: [],
    datas: [
      { flags: 0U, mem_idx: 0U, offset: Some([I32Const(0)]), data: payload, },
      {
        flags: 0U,
        mem_idx: 0U,
        offset: Some([I32Const(100)]),
        data: seg1_data,
      },
      {
        flags: 0U,
        mem_idx: 0U,
        offset: Some([I32Const(104)]),
        data: seg2_zeros,
      },
      { flags: 1U, mem_idx: 0U, offset: None, data: b"\x00\x00\x00\x00", },
    ],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let opt_mod = @moon-wasm-opt.pass_opt_data(m)
  // seg0 split into 2 segments at offsets 8 (len 4) and 36 (len 4); seg1 kept; overlapping seg2 kept intact; passive seg3 kept intact -> 5 segments total!
  assert_eq(opt_mod.datas.length(), 5)
  assert_eq(opt_mod.datas[0].offset, Some([I32Const(8)]))
  assert_eq(opt_mod.datas[0].data.length(), 4)
  assert_eq(opt_mod.datas[1].offset, Some([I32Const(36)]))
  assert_eq(opt_mod.datas[1].data.length(), 4)
  // Overlapping zero overwrite preserved intact!
  assert_eq(opt_mod.datas[3].offset, Some([I32Const(104)]))
  assert_eq(opt_mod.datas[3].data, seg2_zeros)
  // Passive segment preserved intact!
  assert_eq(opt_mod.datas[4].flags, 1U)
  assert_eq(opt_mod.datas[4].data.length(), 4)
  // Unused DataCount dropped because no memory.init/data.drop instructions exist
  assert_eq(opt_mod.has_data_count, false)
  // Net binary size shrank substantially
  assert_true(
    @moon-wasm-opt.encode_module(opt_mod).length() <
    @moon-wasm-opt.encode_module(m).length(),
  )
}
