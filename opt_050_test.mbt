///|
fn empty_mod_050() -> @moon-wasm-opt.WasmModule {
  {
    type_groups: [],
    imports: [],
    func_types: [],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }
}

///|
test "wasmgc-gufa prunes trailing write-only fields and tightens read-only mut fields" {
  let st_type : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Struct([
      { storage: Val(I32), mutable: true, },
      { storage: Val(I32), mutable: true, },
      { storage: Val(I32), mutable: false, },
    ]),
  }
  let fn_type : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let mod : @moon-wasm-opt.WasmModule = {
    ..empty_mod_050(),
    type_groups: [
      { explicit_rec: false, subtypes: [st_type], },
      { explicit_rec: false, subtypes: [fn_type], },
    ],
    func_types: [1U],
    exports: [{ name: "run", kind: Func, idx: 0U, }],
    codes: [
      {
        locals: [],
        body: [
          LocalGet(0U),
          I32Const(99),
          I32Const(77),
          StructNew(0U),
          StructGet(0U, 0U),
        ],
      },
    ],
  }
  let out = @moon-wasm-opt.pass_wasmgc_gufa(mod)
  match out.type_groups[0].subtypes[0].comp {
    Struct(fs) => {
      assert_eq(fs.length(), 1)
      assert_eq(fs[0].mutable, false)
    }
    _ => abort("expected Struct")
  }
  assert_eq(out.codes[0].body, [LocalGet(0U), StructNew(0U), StructGet(0U, 0U)])
}

///|
test "local-cse reuses cached 3-instr binop and invalidates on write" {
  let fn_type : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let mod : @moon-wasm-opt.WasmModule = {
    ..empty_mod_050(),
    type_groups: [{ explicit_rec: false, subtypes: [fn_type], }],
    func_types: [0U],
    exports: [{ name: "f", kind: Func, idx: 0U, }],
    codes: [
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          I32Const(4),
          NumOp(b'\x6A'),
          LocalSet(1U),
          LocalGet(0U),
          I32Const(4),
          NumOp(b'\x6A'),
          LocalGet(1U),
          NumOp(b'\x6A'),
        ],
      },
    ],
  }
  let out = @moon-wasm-opt.pass_local_cse(mod)
  assert_eq(out.codes[0].body, [
    LocalGet(0U),
    I32Const(4),
    NumOp(b'\x6A'),
    LocalSet(1U),
    LocalGet(1U),
    LocalGet(1U),
    NumOp(b'\x6A'),
  ])

  let mod_inv : @moon-wasm-opt.WasmModule = {
    ..mod,
    codes: [
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          I32Const(4),
          NumOp(b'\x6A'),
          LocalSet(1U),
          I32Const(10),
          LocalSet(0U),
          LocalGet(0U),
          I32Const(4),
          NumOp(b'\x6A'),
        ],
      },
    ],
  }
  let out_inv = @moon-wasm-opt.pass_local_cse(mod_inv)
  assert_eq(out_inv.codes[0].body, mod_inv.codes[0].body)
}

///|
test "cfg-merge unwraps unused blocks/loops, strips trailing br 0, and folds identical if/else" {
  let fn_type : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let mod : @moon-wasm-opt.WasmModule = {
    ..empty_mod_050(),
    type_groups: [{ explicit_rec: false, subtypes: [fn_type], }],
    func_types: [0U],
    exports: [{ name: "g", kind: Func, idx: 0U, }],
    codes: [
      {
        locals: [],
        body: [
          Block(Val(I32), [
            Loop(Val(I32), [
              LocalGet(0U),
              If(Val(I32), [I32Const(42), Br(0U)], [I32Const(42)]),
            ]),
            Br(0U),
          ]),
        ],
      },
    ],
  }
  let out = @moon-wasm-opt.pass_cfg_merge(mod)
  assert_eq(out.codes[0].body, [LocalGet(0U), Drop, I32Const(42)])
}
