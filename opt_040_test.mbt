///|
test "code folding converts pure if to select and hoists common trailing local/global writes and binops" {
  let mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: false,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([I32, I32], [I32]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [0U, 0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [
      { global_type: { val_type: I32, mutable: true, }, init: [I32Const(0)], },
    ],
    exports: [
      { name: "f_select", kind: Func, idx: 0U, },
      { name: "f_hoist", kind: Func, idx: 1U, },
      { name: "g", kind: Global, idx: 0U, },
    ],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      // f_select(a, b): if (a) then 10 else 20 -> select (and redundant bool if -> eqz)
      {
        locals: [],
        body: [
          LocalGet(0U),
          If(Val(I32), [I32Const(10)], [I32Const(20)]),
          LocalGet(1U),
          NumOp(b'\x46'),
          If(Val(I32), [I32Const(1)], [I32Const(0)]),
        ],
      },
      // f_hoist(a, b): if (a) { local.set 1 (b + 7); g = local1 } else { local.set 1 (100 + 7); g = local1 }; return local1
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          If(
            Empty,
            [
              LocalGet(1U),
              I32Const(7),
              NumOp(b'\x6A'),
              LocalSet(2U),
              LocalGet(2U),
              GlobalSet(0U),
            ],
            [
              I32Const(100),
              I32Const(7),
              NumOp(b'\x6A'),
              LocalSet(2U),
              LocalGet(2U),
              GlobalSet(0U),
            ],
          ),
          LocalGet(2U),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let folded = @moon-wasm-opt.pass_code_folding(mod)
  // f_select should no longer contain any If instruction
  assert_true(!folded.codes[0].body.iter().any(ins => ins is If(_, _, _)))
  assert_true(folded.codes[0].body.iter().any(ins => ins is Select))

  // f_hoist should hoist GlobalSet(0) out of If(Empty, ...)
  assert_true(folded.codes[1].body.iter().any(ins => ins is GlobalSet(0U)))
  let raw = @moon-wasm-opt.encode_module(mod)
  let (opt_b, rep) = @moon-wasm-opt.optimize_bytes(
    raw,
    config=@moon-wasm-opt.opt_config(level=Oz, converge=true),
  )
  assert_true(rep.saved_bytes > 0)
  let dec = @moon-wasm-opt.decode_module(opt_b)
  assert_eq(dec.codes.length(), 2)
}

///|
test "write-only mutable globals are eliminated across full pipeline while keeping exported/read globals" {
  let mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: false,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([I32], [I32]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [
      // 0: internal write-only mutable global
      { global_type: { val_type: I32, mutable: true, }, init: [I32Const(0)], },
      // 1: internal mutable global that is both written and read
      { global_type: { val_type: I32, mutable: true, }, init: [I32Const(1)], },
    ],
    exports: [{ name: "step", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [
          LocalGet(0U),
          I32Const(9),
          NumOp(b'\x6A'),
          GlobalSet(0U),
          GlobalGet(1U),
          LocalGet(0U),
          NumOp(b'\x6A'),
          GlobalSet(1U),
          GlobalGet(1U),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let wo = @moon-wasm-opt.pass_write_only_globals(mod)
  assert_true(!wo.codes[0].body.iter().any(ins => ins is GlobalSet(0U)))
  assert_true(wo.codes[0].body.iter().any(ins => ins is GlobalSet(1U)))

  let raw = @moon-wasm-opt.encode_module(mod)
  let (opt_b, rep) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(rep.saved_bytes > 0)
  let dec = @moon-wasm-opt.decode_module(opt_b)
  // Dead write-only global 0 removed, live global 1 remains as index 0
  assert_eq(dec.globals.length(), 1)
}

///|
test "simd 0xFD constant folding and identity elimination" {
  let mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: false,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([V128], [I32]),
          },
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([V128], [I64]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [0U, 1U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [
      { name: "s32", kind: Func, idx: 0U, },
      { name: "s64", kind: Func, idx: 1U, },
    ],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      // splat(10) + splat(3) -> extract_lane 0 => 13; unused xor with zero on param is dropped
      {
        locals: [],
        body: [
          LocalGet(0U),
          SimdV128Const(Bytes::make(16, b'\x00')),
          SimdSimpleOp(81U),
          Drop,
          I32Const(10),
          SimdSimpleOp(17U),
          I32Const(3),
          SimdSimpleOp(17U),
          SimdSimpleOp(174U),
          SimdLaneOp(27U, b'\x00'),
        ],
      },
      // i64x2: (splat(100) - splat(58)) -> extract_lane 1 => 42
      {
        locals: [],
        body: [
          LocalGet(0U),
          LocalGet(0U),
          SimdShuffle(Bytes::makei(16, i => i.to_byte())),
          Drop,
          I64Const(100L),
          SimdSimpleOp(18U),
          I64Const(58L),
          SimdSimpleOp(18U),
          SimdSimpleOp(209U),
          SimdLaneOp(29U, b'\x01'),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let opt_mod = @moon-wasm-opt.pass_opt_simd(mod)
  assert_true(opt_mod.codes[0].body.contains(I32Const(13)))
  assert_true(opt_mod.codes[1].body.contains(I64Const(42L)))
  // Identity shuffle with pure second operand was eliminated
  assert_true(!opt_mod.codes[1].body.iter().any(ins => ins is SimdShuffle(_)))

  let raw = @moon-wasm-opt.encode_module(mod)
  let (opt_b, rep) = @moon-wasm-opt.optimize_bytes(raw)
  assert_true(rep.saved_bytes > 40)
  let dec = @moon-wasm-opt.decode_module(opt_b)
  assert_eq(dec.codes[0].body, [I32Const(13)])
  assert_eq(dec.codes[1].body, [I64Const(42L)])
}

///|
test "bitset liveness agrees with incremental optimization bytes exactness" {
  // Verify optimize_bytes incremental length tracking matches encode_module(decode_module(opt)) 100%
  let mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: false,
        subtypes: [
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([I32], [I32]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "loop_live", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [{ count: 3U, val_type: I32, }],
        body: [
          I32Const(0),
          LocalSet(1U),
          Loop(Empty, [
            I32Const(99),
            LocalSet(3U), // dead store inside loop
            LocalGet(1U),
            I32Const(1),
            NumOp(b'\x6A'),
            LocalTee(1U),
            LocalGet(0U),
            NumOp(b'\x48'),
            BrIf(0U),
          ]),
          LocalGet(1U),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }
  let raw = @moon-wasm-opt.encode_module(mod)
  let (opt_b, rep) = @moon-wasm-opt.optimize_bytes(raw)
  assert_eq(opt_b.length(), rep.after_bytes)
  assert_eq(
    @moon-wasm-opt.encode_module(@moon-wasm-opt.decode_module(opt_b)).length(),
    rep.after_bytes,
  )
}
