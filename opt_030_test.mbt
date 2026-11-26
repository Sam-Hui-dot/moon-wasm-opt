///|
test "local-dse eliminates dead stores/tees and copy-propagates while keeping loop back-edge live stores" {
  let fn_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [{ explicit_rec: false, subtypes: [fn_t], }],
    imports: [],
    func_types: [0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "dse_loop", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        // p0: arg; l1: dead copy; l2: loop accumulator; l3: dead tee target
        locals: [{ count: 3U, val_type: I32, }],
        body: [
          // Copy p0 -> l1, read l1 -> copy-prop replaces with p0, DSE kills LocalSet(1)
          LocalGet(0U),
          LocalSet(1U),
          LocalGet(1U),
          LocalSet(2U),
          // Loop where l2 is updated at bottom and read at top (MUST stay live across back-edge!)
          Loop(Empty, [
            LocalGet(2U),
            I32Const(1),
            NumOp(b'\x6B'), // l2 - 1
            LocalTee(3U), // l3 is NEVER read -> dead LocalTee(3) eliminated!
            LocalTee(2U), // l2 IS live across back-edge -> MUST stay!
            BrIf(0U),
          ]),
          // Dead overwrite of l1 before return -> DSE turns into Drop -> peephole removes I32Const(999); Drop
          I32Const(999),
          LocalSet(1U),
          LocalGet(2U),
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
  // Both l1 and l3 were completely eliminated; l2 even coalesced into dead param 0 -> 0 non-param locals left!
  assert_eq(dec.codes[0].locals.length(), 0)
}

///|
test "coalesce-locals merges disjoint lifetimes into fewer slots while pinning entry-live zero-init locals" {
  let fn_t : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [{ explicit_rec: false, subtypes: [fn_t], }],
    imports: [],
    func_types: [0U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "coalesce", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        // p0: param; l1: relies on zero-init (read before any write -> pinned!); l2, l3, l4: disjoint sequential i32 temps
        locals: [{ count: 4U, val_type: I32, }],
        body: [
          // l2 live only in phase 1
          LocalGet(0U),
          I32Const(5),
          NumOp(b'\x6A'),
          LocalSet(2U),
          LocalGet(2U),
          I32Const(2),
          NumOp(b'\x6C'),
          // l3 live only in phase 2 (after l2 is dead)
          LocalSet(3U),
          LocalGet(3U),
          I32Const(3),
          NumOp(b'\x6A'),
          // l4 live only in phase 3 (after l3 is dead)
          LocalSet(4U),
          LocalGet(4U),
          // l1 read without prior write (must keep default 0, NOT merged with p0 or l2/l3/l4!)
          LocalGet(1U),
          NumOp(b'\x6A'),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let opt_mod = @moon-wasm-opt.pass_coalesce_locals(m)
  // l1 must remain its own pinned non-param slot (not slot 0!), while l2/l3/l4 coalesce into param slot 0!
  let mut total_non_param = 0U
  for lg in opt_mod.codes[0].locals {
    total_non_param += lg.count
  }
  assert_eq(total_non_param, 1U)
  // Verify the zero-init read still reads slot 1 (non-param), NOT param slot 0
  let body = opt_mod.codes[0].body
  assert_eq(body[body.length() - 2], LocalGet(1U))
}

///|
test "wasmgc dedup-types merges identical RecGroups, keeps distinct RecGroups separate, eliminates static ref.cast, and devirtualizes call_ref" {
  let s_base : @moon-wasm-opt.SubType = {
    is_final: false,
    explicit_sub: true,
    supers: [],
    comp: Struct([{ storage: Val(I32), mutable: false, }]),
  }
  let s_child : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: true,
    supers: [0U],
    comp: Struct([
      { storage: Val(I32), mutable: false, },
      { storage: Val(I32), mutable: false, },
    ]),
  }
  // Two identical singleton Func types (idx 2 and idx 3) -> dedup-types merges idx 3 into idx 2!
  let fn_i32 : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [
      { explicit_rec: false, subtypes: [s_base], },
      { explicit_rec: false, subtypes: [s_child], },
      { explicit_rec: true, subtypes: [fn_i32], }, // redundant explicit rec-1 wrapper
      { explicit_rec: false, subtypes: [fn_i32], }, // duplicate of idx 2!
    ],
    imports: [],
    func_types: [2U, 3U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "gc_entry", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [
      {
        flags: 3U,
        table_idx: 0U,
        offset: None,
        elem_kind: b'\x00',
        ref_type: None,
        func_indices: [1U],
        init_exprs: [],
      },
    ],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [
          // Create s_child (subtype of s_base), redundant ref.cast to s_base & ref.as_non_null eliminated!
          LocalGet(0U),
          I32Const(7),
          StructNew(1U),
          RefCast(Concrete(0U)),
          RefAsNonNull,
          StructGet(0U, 0U),
          // Constant i31 roundtrip: (5 << 1 >> 1) == 5
          I32Const(5),
          RefI31,
          I31GetS,
          NumOp(b'\x6A'),
          // Devirtualize RefFunc(1) + CallRef(3) -> Call(1)
          RefFunc(1U),
          CallRef(3U),
        ],
      },
      { locals: [], body: [LocalGet(0U), I32Const(1), NumOp(b'\x6A')], },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let deduped = @moon-wasm-opt.pass_dedup_types(m)
  // Duplicate Func type 3 merged into type 2 -> 3 types total instead of 4, and explicit_rec=false on singleton!
  assert_eq(deduped.total_type_count(), 3U)
  assert_eq(deduped.type_groups[2].explicit_rec, false)
  assert_eq(deduped.func_types[1], 2U)

  let gc_opt = @moon-wasm-opt.pass_wasmgc_opt(deduped)
  // Redundant RefCast(0) + RefAsNonNull removed, RefI31+I31GetS folded to I32Const(5), RefFunc(1)+CallRef -> Call(1)
  assert_eq(gc_opt.codes[0].body, [
    LocalGet(0U),
    I32Const(7),
    StructNew(1U),
    StructGet(0U, 0U),
    I32Const(5),
    NumOp(b'\x6A'),
    Call(1U),
  ])
}

///|
test "dae propagates uniform constant arguments and prunes trailing dead parameters on internal functions" {
  let fn_1 : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let fn_2 : @moon-wasm-opt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32, I32], [I32]),
  }
  let m : @moon-wasm-opt.WasmModule = {
    type_groups: [
      { explicit_rec: false, subtypes: [fn_1], },
      { explicit_rec: false, subtypes: [fn_2], },
    ],
    imports: [],
    func_types: [0U, 1U],
    tables: [],
    memories: [],
    tags: [],
    globals: [],
    exports: [{ name: "main", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      // f0 calls internal f1 twice, BOTH times passing constant 10 as the 2nd param
      {
        locals: [],
        body: [
          LocalGet(0U),
          I32Const(10),
          Call(1U),
          LocalGet(0U),
          I32Const(10),
          Call(1U),
          NumOp(b'\x6A'),
        ],
      },
      // f1 (internal, non-exported): returns p0 + p1 + l2 (where l2 is non-param local index 2 -> shifts to 1!)
      {
        locals: [{ count: 1U, val_type: I32, }],
        body: [
          LocalGet(0U),
          LocalGet(1U),
          NumOp(b'\x6A'),
          LocalSet(2U),
          LocalGet(2U),
          I32Const(3),
          NumOp(b'\x6C'),
        ],
      },
    ],
    datas: [],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }

  let after_dae = @moon-wasm-opt.pass_dae(m)
  // f1's 2nd param (always 10) was propagated into f1 and pruned -> f1 now reuses fn_1 (type 0)!
  assert_eq(after_dae.func_types[1], 0U)
  // Inside f1, LocalGet(1) became I32Const(10) and non-param local 2 shifted to local 1
  assert_eq(after_dae.codes[1].body[1], I32Const(10))
  assert_eq(after_dae.codes[1].body[3], LocalSet(1U))
  // Full pipeline (with inline disabled) fuses [I32Const(10), Drop] at both call sites and shrinks module!
  let raw = @moon-wasm-opt.encode_module(m)
  let (opt_b, rep) = @moon-wasm-opt.optimize_bytes(
    raw,
    config=@moon-wasm-opt.opt_config(level=Oz, enable_inline=Some(false)),
  )
  assert_true(rep.saved_bytes > 0)
  let dec = @moon-wasm-opt.decode_module(opt_b)
  assert_eq(dec.func_types[1], 0U)
}
