///|
test "peephole, dce-instr, local-opt, module-dce, and ICF shrink redundant Wasm accurately" {
  let fn_i32_i32 : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32, I32], [I32]),
  }
  let fn_dead_sig : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([F64], [F64]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [
      { explicit_rec: false, subtypes: [fn_i32_i32], },
      { explicit_rec: false, subtypes: [fn_dead_sig], },
    ],
    imports: [],
    func_types: [0U, 0U, 1U],
    tables: [],
    memories: [],
    tags: [],
    globals: [
      { global_type: { val_type: I32, mutable: false, }, init: [I32Const(99)], },
    ],
    exports: [
      { name: "f_a", kind: Func, idx: 0U, },
      { name: "f_b", kind: Func, idx: 1U, },
    ],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        // Unused local 2 (i64), used local 3 (i32), algebraic +0, const fold 3+4, set/get -> tee, trailing dead code
        locals: [{ count: 1U, val_type: I64, }, { count: 1U, val_type: I32, }],
        body: [
          Nop,
          LocalGet(0U),
          I32Const(0),
          NumOp(b'\x6A'), // + 0
          LocalGet(1U),
          NumOp(b'\x6A'),
          I32Const(3),
          I32Const(4),
          NumOp(b'\x6A'), // folds to 7
          NumOp(b'\x6A'),
          LocalSet(3U),
          LocalGet(3U),
          Return,
          I32Const(999), // dead after return
          Drop,
        ],
      },
      {
        // Functionally identical to func 0 after peephole + local-opt -> merged by ICF!
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          LocalGet(1U),
          NumOp(b'\x6A'),
          I32Const(7),
          NumOp(b'\x6A'),
          LocalTee(2U),
          Return,
        ],
      },
      {
        // Unreachable dead function referencing dead type 1
        locals: [],
        body: [LocalGet(0U)],
      },
    ],
    datas: [],
    custom_sections: [
      {
        name: "producers",
        payload: b"fake_producers_metadata",
        after_section: b'\x0A',
      },
    ],
    module_name: "",
    func_names: Map([(0U, "f_a"), (1U, "f_b"), (2U, "dead_fn")]),
  }

  let raw = @moon-wasm-opt.encode_module(m)
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(
    raw,
    config=@moon-wasm-opt.opt_config(level=Oz, converge=true),
  )

  assert_true(report.saved_bytes > 0)
  assert_eq(report.before_funcs, 3)
  // dead_fn removed by module-dce AND f_b merged into f_a by ICF -> 1 defined func!
  assert_eq(report.after_funcs, 1)
  // dead type 1 removed by module-dce -> 1 type!
  assert_eq(report.after_types, 1)

  let decoded = @moon-wasm-opt.decode_module(opt_bytes)
  // Both exports still exist and both point to surviving func 0!
  assert_eq(decoded.exports.length(), 2)
  assert_eq(decoded.exports[0].idx, 0U)
  assert_eq(decoded.exports[1].idx, 0U)
  // Unused global 0 was eliminated
  assert_eq(decoded.globals.length(), 0)
  // Unused i64 local was eliminated, only 1 i32 local remains
  assert_eq(decoded.codes[0].locals.length(), 1)
  assert_eq(decoded.codes[0].locals[0].val_type, I32)

  let wf = @moon-wasm-opt.render_opt_waterfall_svg(report)
  assert_true(wf.contains("moon-wasm-waterfall"))
  assert_true(wf.contains("Optimized Binary"))

  let md = @moon-wasm-opt.render_opt_report_markdown(report)
  assert_true(md.contains("# moon-wasm-opt Optimization Report"))
}

///|
test "WasmGC module preserves rec groups and folds redundant ref.as_non_null" {
  let gc_mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: true,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Struct([{ storage: Val(I32), mutable: false, }]),
          },
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([I32], [Ref(Concrete(0U))]),
          },
        ],
      },
      {
        explicit_rec: false,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Struct([{ storage: I8, mutable: true, }]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [1U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "box", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [LocalGet(0U), StructNew(0U), RefAsNonNull, RefAsNonNull],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }
  let raw = @moon-wasm-opt.encode_module(gc_mod)
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(report.is_wasmgc)
  assert_true(report.saved_bytes > 0)
  // Unused second type group dropped, rec group 0 (2 types) preserved intact
  assert_eq(report.before_types, 3)
  assert_eq(report.after_types, 2)
  let dec = @moon-wasm-opt.decode_module(opt_bytes)
  assert_eq(dec.codes[0].body, [LocalGet(0U), StructNew(0U)])
}
