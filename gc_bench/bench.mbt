///|
/// Self-hosting WasmGC benchmark entry: constructs a synthetic module parameterized by `seed`,
/// runs the full 10-pass `moon-wasm-opt -Oz --converge` pipeline, renders Treemap & Waterfall SVGs,
/// and returns a deterministic checksum for V8 pre/post-optimization runtime equivalence verification.
pub fn self_opt_checksum(seed : Int32) -> Int32 {
  let fn_t : @wopt.SubType = {
    is_final: true,
    explicit_sub: false,
    supers: [],
    comp: Func([I32], [I32]),
  }
  let m : @wopt.WasmModule = {
    type_groups: [{ explicit_rec: false, subtypes: [fn_t], }],
    imports: [],
    func_types: [0U, 0U, 0U],
    tables: [],
    memories: [{ flags: b'\x00', min: 1UL, max: None, }],
    tags: [],
    globals: [
      {
        global_type: { val_type: I32, mutable: false, },
        init: [I32Const(seed)],
      },
    ],
    exports: [{ name: "entry", kind: Func, idx: 0U, }],
    start_func: None,
    elements: [],
    has_data_count: false,
    codes: [
      {
        locals: [],
        body: [
          LocalGet(0U),
          Call(1U),
          GlobalGet(0U),
          NumOp(b'\x6A'),
          I32Const(0),
          NumOp(b'\x6A'),
        ],
      },
      { locals: [], body: [LocalGet(0U), I32Const(3), NumOp(b'\x6C')], },
      { locals: [], body: [LocalGet(0U), I32Const(99), NumOp(b'\x6A')], },
    ],
    datas: [
      {
        flags: 0U,
        mem_idx: 0U,
        offset: Some([I32Const(0)]),
        data: b"\x00\x00\x00\x00\x01\x02\x03\x04\x00\x00\x00\x00",
      },
    ],
    custom_sections: [],
    module_name: "",
    func_names: Map([]),
  }
  let raw = @wopt.encode_module(m)
  try {
    let (opt_b, rep) = @wopt.optimize_bytes(raw)
    let ana = @wopt.analyze_module(opt_b)
    let tm = @wopt.render_treemap_svg(ana)
    let wf = @wopt.render_opt_waterfall_svg(rep)
    let wat = @wopt.disassemble_function(@wopt.decode_module(opt_b), 0U)
    rep.after_bytes * 131 +
    rep.after_funcs * 17 +
    tm.length() +
    wf.length() +
    wat.length()
  } catch {
    _ => -1
  }
}
