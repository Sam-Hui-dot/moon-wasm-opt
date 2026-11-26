///|
test "disassemble_function and analyze_module produce valid WAT and SVG Treemap" {
  let m = make_sample_linear_module()
  let bytes = @moon-wasm-opt.encode_module(m)
  let decoded = @moon-wasm-opt.decode_module(bytes)

  let wat = @moon-wasm-opt.disassemble_function(decoded, 0U)
  assert_true(wat.contains("(func (;0;)"))
  assert_true(wat.contains("i32.add"))
  assert_true(wat.contains("local.set 2"))

  let report = @moon-wasm-opt.analyze_module(bytes, top_k=10)
  assert_eq(report.defined_func_count, 3)
  assert_false(report.is_wasmgc)
  assert_true(report.total_bytes == bytes.length())
  assert_true(report.top_functions.length() == 3)

  let svg = @moon-wasm-opt.render_treemap_svg(report)
  assert_true(svg.has_prefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
  assert_true(svg.contains("moon-wasm-treemap"))
  assert_true(svg.contains("tm-tile"))
  assert_true(svg.contains("</svg>"))

  let md = @moon-wasm-opt.render_module_markdown(report)
  assert_true(md.contains("# moon-wasm-opt Module Size Report"))
}
