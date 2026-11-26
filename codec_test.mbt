///|
fn make_sample_linear_module() -> @moon-wasm-opt.WasmModule {
  let fn_add : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32, I32], [I32]),
  }
  let fn_void : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([], [I32]),
  }
  {
    type_groups: [
      { explicit_rec: false, subtypes: [fn_add], },
      { explicit_rec: false, subtypes: [fn_void], },
    ],
    imports: [],
    func_types: [0U, 1U, 0U],
    tables: [],
    memories: [{ flags: b'\x00', min: 1UL, max: None, }],
    tags: [],
    globals: [
      { global_type: { val_type: I32, mutable: false, }, init: [I32Const(42)], },
    ],
    exports: [
      { name: "add", kind: Func, idx: 0U, },
      { name: "memory", kind: Mem, idx: 0U, },
    ],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          LocalGet(1U),
          NumOp(b'\x6A'), // i32.add
          I32Const(0),
          NumOp(b'\x6A'), // + 0
          LocalSet(2U),
          LocalGet(2U),
        ],
      },
      { locals: [], body: [I32Const(10), I32Const(20), NumOp(b'\x6A')], },
      {
        // Duplicate of func 0 body (different only before folding, identical after)
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          LocalGet(1U),
          NumOp(b'\x6A'),
          LocalSet(2U),
          LocalGet(2U),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "sample",
    func_names: Map([(0U, "add"), (1U, "dead_helper"), (2U, "add_dup")]),
  }
}

///|
test "decode_module and encode_module lossless round-trip for Wasm 2.0 and WasmGC" {
  let m = make_sample_linear_module()
  let bytes = @moon-wasm-opt.encode_module(m)
  assert_true(bytes.length() > 8)
  let decoded = @moon-wasm-opt.decode_module(bytes)
  assert_eq(decoded.func_types.length(), 3)
  assert_eq(decoded.codes.length(), 3)
  assert_eq(decoded.exports.length(), 2)
  assert_eq(decoded.globals.length(), 1)
  let reencoded = @moon-wasm-opt.encode_module(decoded)
  assert_eq(bytes, reencoded)

  // WasmGC rec/struct/array round-trip
  let gc_mod : @moon-wasm-opt.WasmModule = {
    type_groups: [
      {
        explicit_rec: true,
        subtypes: [
          {
            is_final: false,
            explicit_sub: true,
            supers: [],
            comp: Struct([
              { storage: Val(I32), mutable: true, },
              { storage: I8, mutable: false, },
            ]),
          },
          {
            is_final: true,
            explicit_sub: true,
            supers: [0U],
            comp: Struct([
              { storage: Val(I32), mutable: true, },
              { storage: I8, mutable: false, },
              { storage: Val(RefNull(Concrete(0U))), mutable: true, },
            ]),
          },
          {
            is_final: true,
            explicit_sub: false,
            supers: [],
            comp: Func([I32], [Ref(Concrete(0U))]),
          },
        ],
      },
    ],
    imports: [],
    func_types: [2U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "make_obj", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [{ locals: [], body: [LocalGet(0U), I32Const(7), StructNew(0U)], }],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }
  let gc_bytes = @moon-wasm-opt.encode_module(gc_mod)
  let gc_dec = @moon-wasm-opt.decode_module(gc_bytes)
  assert_eq(gc_dec.total_type_count(), 3U)
  assert_eq(@moon-wasm-opt.encode_module(gc_dec), gc_bytes)
}

///|
test "decode_module rejects malformed or truncated wasm binaries cleanly" {
  let bad_magic = b"\x00\x00\x00\x00\x01\x00\x00\x00"
  let r1 : Result[@moon-wasm-opt.WasmModule, Error] = Ok(
    @moon-wasm-opt.decode_module(bad_magic),
  ) catch {
    e => Err(e)
  }
  assert_true(r1 is Err(_))
  let too_short = b"\x00\x61\x73"
  let r2 : Result[@moon-wasm-opt.WasmModule, Error] = Ok(
    @moon-wasm-opt.decode_module(too_short),
  ) catch {
    e => Err(e)
  }
  assert_true(r2 is Err(_))
}
