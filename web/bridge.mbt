///|
fn b64_val(ch : Int32) -> Int32 {
  if ch >= 65 && ch <= 90 {
    ch - 65
  } else if ch >= 97 && ch <= 122 {
    ch - 97 + 26
  } else if ch >= 48 && ch <= 57 {
    ch - 48 + 52
  } else if ch == 43 || ch == 45 {
    62
  } else if ch == 47 || ch == 95 {
    63
  } else {
    -1
  }
}

///|
fn decode_base64(input : String) -> Bytes raise @moon-wasm-opt.WasmError {
  let buf = @buffer.Buffer()
  let mut acc = 0
  let mut bits = 0
  for ch in input {
    let code = ch.to_int()
    if code == 61 {
      break
    }
    if code == 32 || code == 10 || code == 13 || code == 9 {
      continue
    }
    let v = b64_val(code)
    guard v >= 0 else {
      raise @moon-wasm-opt.WasmError::InvalidInput("invalid base64 character")
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      buf.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  buf.to_bytes()
}

///|
fn encode_base64(bytes : Bytes) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_array()
  let out = StringBuilder()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int()
    let has1 = i + 1 < n
    let has2 = i + 2 < n
    let b1 = if has1 { bytes[i + 1].to_int() } else { 0 }
    let b2 = if has2 { bytes[i + 2].to_int() } else { 0 }
    let triple = (b0 << 16) | (b1 << 8) | b2
    out.write_char(alphabet[(triple >> 18) & 63])
    out.write_char(alphabet[(triple >> 12) & 63])
    out.write_char(if has1 { alphabet[(triple >> 6) & 63] } else { '=' })
    out.write_char(if has2 { alphabet[triple & 63] } else { '=' })
    i += 3
  }
  out.to_string()
}

///|
fn json_err(err : Error) -> String {
  @json.Json::object({
    "ok": @json.ToJson::to_json(false),
    "error": @json.ToJson::to_json(@moon-wasm-opt.error_message(err)),
  }).stringify()
}

///|
fn parse_level(name : String) -> @moon-wasm-opt.OptLevel {
  match name {
    "O1" | "-O1" => O1
    "O2" | "-O2" => O2
    "Os" | "-Os" => Os
    _ => Oz
  }
}

///|
/// Inspect a base64-encoded `.wasm` or `.wasm-gc` binary in the browser.
pub fn inspect_wasm_b64(b64 : String, top_k : Int32) -> String {
  try {
    let bytes = decode_base64(b64)
    let report = @moon-wasm-opt.analyze_module(bytes, top_k~)
    let treemap = @moon-wasm-opt.render_treemap_svg(report)
    let md = @moon-wasm-opt.render_module_markdown(report)
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "report": @json.ToJson::to_json(report),
      "treemap_svg": @json.ToJson::to_json(treemap),
      "markdown": @json.ToJson::to_json(md),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
/// Optimize a base64-encoded `.wasm` or `.wasm-gc` binary in the browser and return the optimized binary + full visual diagnostics.
pub fn optimize_wasm_b64(
  b64 : String,
  preset : String,
  converge : Bool,
  strip_custom : Bool,
  keep_names : Bool,
) -> String {
  try {
    let raw = decode_base64(b64)
    let cfg = @moon-wasm-opt.opt_config(
      level=parse_level(preset),
      converge~,
      strip_custom~,
      keep_names~,
    )
    let before_rep = @moon-wasm-opt.analyze_module(raw, top_k=30)
    let (opt_bytes, opt_rep) = @moon-wasm-opt.optimize_bytes(raw, config=cfg)
    let after_rep = @moon-wasm-opt.analyze_module(opt_bytes, top_k=30)
    let diff = @moon-wasm-opt.diff_modules(raw, opt_bytes, top_k=40)
    let wf_svg = @moon-wasm-opt.render_opt_waterfall_svg(opt_rep)
    let before_tm = @moon-wasm-opt.render_treemap_svg(
      before_rep,
      title="Before Optimization (\{before_rep.total_bytes} B)",
    )
    let after_tm = @moon-wasm-opt.render_treemap_svg(
      after_rep,
      title="After Optimization (\{after_rep.total_bytes} B)",
    )
    let md = @moon-wasm-opt.render_opt_report_markdown(opt_rep) +
      "\n" +
      @moon-wasm-opt.render_diff_markdown(diff)
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "optimized_b64": @json.ToJson::to_json(encode_base64(opt_bytes)),
      "report": @json.ToJson::to_json(opt_rep),
      "before_report": @json.ToJson::to_json(before_rep),
      "after_report": @json.ToJson::to_json(after_rep),
      "diff": @json.ToJson::to_json(diff),
      "waterfall_svg": @json.ToJson::to_json(wf_svg),
      "before_treemap_svg": @json.ToJson::to_json(before_tm),
      "after_treemap_svg": @json.ToJson::to_json(after_tm),
      "markdown": @json.ToJson::to_json(md),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
/// Disassemble a single function by index or name substring into readable WAT text.
pub fn disasm_func_b64(b64 : String, query : String) -> String {
  try {
    let bytes = decode_base64(b64)
    let mod = @moon-wasm-opt.decode_module(bytes)
    guard @moon-wasm-opt.find_function_index(mod, query) is Some(fidx) else {
      raise @moon-wasm-opt.WasmError::InvalidInput(
        "no function matching '\{query}'",
      )
    }
    let wat = @moon-wasm-opt.disassemble_function(mod, fidx)
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "func_idx": @json.ToJson::to_json(fidx.reinterpret_as_int()),
      "name": @json.ToJson::to_json(mod.resolve_func_name(fidx)),
      "wat": @json.ToJson::to_json(wat),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
extern "js" fn register_browser_api(
  inspect : (String, Int32) -> String,
  optimize : (String, String, Bool, Bool, Bool) -> String,
  disasm : (String, String) -> String,
) -> Unit =
  #|(inspect, optimize, disasm) => {
  #|  globalThis.MoonWasmOpt = {
  #|    inspectWasm: (b64, opts = {}) => JSON.parse(inspect(b64, opts.topK || 30)),
  #|    optimizeWasm: (b64, opts = {}) => JSON.parse(optimize(
  #|      b64,
  #|      opts.preset || "Oz",
  #|      opts.converge !== false,
  #|      opts.stripCustom !== false,
  #|      !!opts.keepNames
  #|    )),
  #|    disasmFunc: (b64, query) => JSON.parse(disasm(b64, String(query || "0"))),
  #|  };
  #|}

///|
fn main {
  register_browser_api(inspect_wasm_b64, optimize_wasm_b64, disasm_func_b64)
}
