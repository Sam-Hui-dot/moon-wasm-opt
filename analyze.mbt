///|
/// Per-section byte accounting for a WebAssembly module.
#derive(Debug, Eq, ToJson)
pub(all) struct SectionSize {
  name : String
  bytes : Int32
  pct : Double
}

///|
pub extend SectionSize with @debug.Debug::{to_repr}

///|
pub extend SectionSize with Eq::{not_equal, equal}

///|
pub extend SectionSize with @json.ToJson::{to_json}

///|
/// Per-function size and complexity metrics.
#derive(Debug, Eq, ToJson)
pub(all) struct FuncSizeEntry {
  func_idx : UInt32
  name : String
  bytes : Int32
  pct_of_module : Double
  pct_of_code : Double
  instr_count : Int32
  local_count : Int32
  exported : Bool
}

///|
pub extend FuncSizeEntry with @debug.Debug::{to_repr}

///|
pub extend FuncSizeEntry with Eq::{not_equal, equal}

///|
pub extend FuncSizeEntry with @json.ToJson::{to_json}

///|
/// Complete static size and structural profile of a WebAssembly binary.
#derive(Debug, Eq, ToJson)
pub(all) struct ModuleReport {
  total_bytes : Int32
  code_bytes : Int32
  custom_bytes : Int32
  is_wasmgc : Bool
  type_count : Int32
  import_count : Int32
  defined_func_count : Int32
  export_count : Int32
  global_count : Int32
  data_count : Int32
  total_instrs : Int32
  sections : Array[SectionSize]
  top_functions : Array[FuncSizeEntry]
}

///|
pub extend ModuleReport with @debug.Debug::{to_repr}

///|
pub extend ModuleReport with Eq::{not_equal, equal}

///|
pub extend ModuleReport with @json.ToJson::{to_json}

///|
/// Function-level size delta between two WebAssembly binaries.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffFuncEntry {
  name : String
  before_bytes : Int32
  after_bytes : Int32
  delta_bytes : Int32
  status : String
}

///|
pub extend DiffFuncEntry with @debug.Debug::{to_repr}

///|
pub extend DiffFuncEntry with Eq::{not_equal, equal}

///|
pub extend DiffFuncEntry with @json.ToJson::{to_json}

///|
/// Module-level comparison report between baseline and optimized WebAssembly binaries.
#derive(Debug, Eq, ToJson)
pub(all) struct ModuleDiffReport {
  before_bytes : Int32
  after_bytes : Int32
  saved_bytes : Int32
  saved_pct : Double
  before_funcs : Int32
  after_funcs : Int32
  before_instrs : Int32
  after_instrs : Int32
  entries : Array[DiffFuncEntry]
}

///|
pub extend ModuleDiffReport with @debug.Debug::{to_repr}

///|
pub extend ModuleDiffReport with Eq::{not_equal, equal}

///|
pub extend ModuleDiffReport with @json.ToJson::{to_json}

///|
fn round2(v : Double) -> Double {
  let s = v * 100.0
  let r = if s >= 0.0 {
    (s + 0.5).to_int64().to_double()
  } else {
    (s - 0.5).to_int64().to_double()
  }
  r / 100.0
}

///|
fn pct_of(part : Int32, total : Int32) -> Double {
  if total <= 0 {
    0.0
  } else {
    round2(part.to_double() * 100.0 / total.to_double())
  }
}

///|
fn count_instrs(instrs : Array[Instr]) -> Int32 {
  let mut total = 0
  for ins in instrs {
    total += 1
    match ins {
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) => total += count_instrs(b)
      If(_, t, e) => total += count_instrs(t) + count_instrs(e)
      _ => ()
    }
  }
  total
}

///|
fn module_uses_wasmgc(mod : WasmModule) -> Bool {
  for g in mod.type_groups {
    if g.explicit_rec {
      return true
    }
    for st in g.subtypes {
      match st.comp {
        Struct(_) | Array(_) => return true
        _ => ()
      }
    }
  }
  false
}

///|
fn section_label(sec_id : Byte) -> String {
  match sec_id {
    b'\x01' => "type"
    b'\x02' => "import"
    b'\x03' => "function"
    b'\x04' => "table"
    b'\x05' => "memory"
    b'\x06' => "global"
    b'\x07' => "export"
    b'\x08' => "start"
    b'\x09' => "element"
    b'\x0A' => "code"
    b'\x0B' => "data"
    b'\x0C' => "datacount"
    b'\x0D' => "tag"
    _ => "section_\{sec_id.to_int()}"
  }
}

///|
fn scan_section_sizes(bytes : Bytes) -> (Array[(String, Int32)], Int32, Int32) {
  let out : Array[(String, Int32)] = []
  let mut code_bytes = 0
  let mut custom_bytes = 0
  if bytes.length() < 8 {
    return (out, 0, 0)
  }
  let r = BinReader::slice(bytes, 8, bytes.length())
  try {
    while !r.eof() {
      let start = r.pos
      let sid = r.read_byte()
      let slen = r.read_u32().reinterpret_as_int()
      if slen < 0 || r.pos + slen > r.end {
        break
      }
      let payload_start = r.pos
      let full_bytes = payload_start + slen - start
      if sid == b'\x00' {
        let sr = BinReader::slice(bytes, payload_start, payload_start + slen)
        let cname = sr.read_name()
        out.push(("custom:\{cname}", full_bytes))
        custom_bytes += full_bytes
      } else {
        out.push((section_label(sid), full_bytes))
        if sid == b'\x0A' {
          code_bytes += full_bytes
        }
      }
      r.pos = payload_start + slen
    }
  } catch {
    _ => ()
  }
  (out, code_bytes, custom_bytes)
}

///|
/// Analyze exact section and per-function byte sizes of a WebAssembly binary.
pub fn analyze_module(
  bytes : Bytes,
  top_k~ : Int32 = 30,
) -> ModuleReport raise WasmError {
  let mod = decode_module(bytes)
  let total_bytes = bytes.length()
  let (raw_secs, code_bytes, custom_bytes) = scan_section_sizes(bytes)
  let sections : Array[SectionSize] = []
  for pair in raw_secs {
    sections.push({
      name: pair.0,
      bytes: pair.1,
      pct: pct_of(pair.1, total_bytes),
    })
  }
  sections.sort_by((a, b) => b.bytes.compare(a.bytes))

  let exported_funcs : Set[UInt32] = Set([])
  for exp in mod.exports {
    if exp.kind == Func {
      exported_funcs.add(exp.idx)
    }
  }

  let imp_cnt = mod.imported_func_count()
  let funcs : Array[FuncSizeEntry] = []
  let mut total_instrs = 0
  let mut sum_body_bytes = 0
  let raw_bodies : Array[(UInt32, Int32, Int32, Int32)] = []
  for i, fb in mod.codes {
    let fidx = imp_cnt + i.reinterpret_as_uint()
    let bsz = encode_func_body(fb).length()
    let icnt = count_instrs(fb.body)
    let mut lcnt = 0
    for lg in fb.locals {
      lcnt += lg.count.reinterpret_as_int()
    }
    total_instrs += icnt
    sum_body_bytes += bsz
    raw_bodies.push((fidx, bsz, icnt, lcnt))
  }
  let code_denom = if code_bytes > 0 { code_bytes } else { sum_body_bytes }
  for item in raw_bodies {
    let (fidx, bsz, icnt, lcnt) = item
    funcs.push({
      func_idx: fidx,
      name: mod.resolve_func_name(fidx),
      bytes: bsz,
      pct_of_module: pct_of(bsz, total_bytes),
      pct_of_code: pct_of(bsz, code_denom),
      instr_count: icnt,
      local_count: lcnt,
      exported: exported_funcs.contains(fidx),
    })
  }
  funcs.sort_by((a, b) => {
    let c = b.bytes.compare(a.bytes)
    if c != 0 {
      c
    } else {
      a.func_idx.compare(b.func_idx)
    }
  })

  let limit = if top_k < 1 { 1 } else { top_k }
  let top_functions : Array[FuncSizeEntry] = []
  for i in 0..<funcs.length() {
    if i >= limit {
      break
    }
    top_functions.push(funcs[i])
  }

  {
    total_bytes,
    code_bytes,
    custom_bytes,
    is_wasmgc: module_uses_wasmgc(mod),
    type_count: mod.total_type_count().reinterpret_as_int(),
    import_count: mod.imports.length(),
    defined_func_count: mod.codes.length(),
    export_count: mod.exports.length(),
    global_count: mod.globals.length(),
    data_count: mod.datas.length(),
    total_instrs,
    sections,
    top_functions,
  }
}

///|
/// Render a module size report as plain text.
pub fn render_module_text(report : ModuleReport) -> String {
  let out = StringBuilder()
  let kind = if report.is_wasmgc { "WasmGC" } else { "Linear Wasm 2.0" }
  out.write_string(
    "Module (\{kind}): \{report.total_bytes} bytes | funcs=\{report.defined_func_count} | types=\{report.type_count} | instrs=\{report.total_instrs} | code=\{report.code_bytes} B | custom=\{report.custom_bytes} B\n",
  )
  out.write_string("Sections:\n")
  for s in report.sections {
    out.write_string("  \{s.name}: \{s.bytes} B (\{s.pct}%)\n")
  }
  out.write_string("Top \{report.top_functions.length()} Functions:\n")
  for f in report.top_functions {
    let exp = if f.exported { " [export]" } else { "" }
    out.write_string(
      "  #\{f.func_idx} \{f.name}: \{f.bytes} B (\{f.pct_of_module}% mod, \{f.instr_count} instrs, \{f.local_count} locals)\{exp}\n",
    )
  }
  out.to_string()
}

///|
/// Render a module size report as GitHub-flavored Markdown.
pub fn render_module_markdown(report : ModuleReport) -> String {
  let out = StringBuilder()
  let kind = if report.is_wasmgc { "WasmGC" } else { "Linear Wasm 2.0" }
  out.write_string("# moon-wasm-opt Module Size Report\n\n")
  out.write_string(
    "- **Format**: `\{kind}`\n- **Total Size**: `\{report.total_bytes}` bytes\n- **Code Section**: `\{report.code_bytes}` bytes (`\{pct_of(report.code_bytes, report.total_bytes)}%`)\n- **Custom Sections**: `\{report.custom_bytes}` bytes (`\{pct_of(report.custom_bytes, report.total_bytes)}%`)\n- **Functions / Types / Instrs**: `\{report.defined_func_count}` / `\{report.type_count}` / `\{report.total_instrs}`\n\n",
  )
  out.write_string(
    "## Sections\n\n| Section | Bytes | Share |\n|---|---:|---:|\n",
  )
  for s in report.sections {
    out.write_string("| `\{s.name}` | \{s.bytes} | \{s.pct}% |\n")
  }
  out.write_string(
    "\n## Top Functions\n\n| Idx | Function | Bytes | Module % | Instrs | Locals |\n|---:|---|---:|---:|---:|---:|\n",
  )
  for f in report.top_functions {
    out.write_string(
      "| \{f.func_idx} | `\{f.name}` | \{f.bytes} | \{f.pct_of_module}% | \{f.instr_count} | \{f.local_count} |\n",
    )
  }
  out.to_string()
}

///|
fn xml_escape(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&#39;")
}

///|
priv struct TileItem {
  label : String
  detail : String
  bytes : Int32
  func_idx : Int32
  color : String
}

///|
fn tile_color(label : String, is_func : Bool) -> String {
  if !is_func {
    if label.has_prefix("custom:") {
      return "#cbd5e1"
    }
    if label == "data" {
      return "#bae6fd"
    }
    if label == "type" {
      return "#ddd6fe"
    }
    return "#e2e8f0"
  }
  let mut h = 2166136261U
  for ch in label {
    h = (h ^ ch.to_int().reinterpret_as_uint()) * 16777619U
  }
  let palette = [
    "#60a5fa", "#34d399", "#fbbf24", "#f87171", "#a78bfa", "#38bdf8", "#fb923c",
    "#4ade80", "#f472b6", "#818cf8",
  ]
  palette[(h % palette.length().reinterpret_as_uint()).reinterpret_as_int()]
}

///|
fn fit_tile_label(label : String, w : Double) -> String {
  if w < 44.0 {
    return ""
  }
  let max_c = ((w - 10.0) / 6.8).to_int()
  if max_c <= 2 {
    return ""
  }
  let chars = label.to_array()
  if chars.length() <= max_c {
    return label
  }
  let out = StringBuilder()
  for i in 0..<(max_c - 1) {
    out.write_char(chars[i])
  }
  out.write_char('…')
  out.to_string()
}

///|
fn layout_treemap(
  out : StringBuilder,
  items : Array[TileItem],
  start : Int32,
  end : Int32,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  total_mod : Int32,
) -> Unit {
  if start >= end || w < 2.0 || h < 2.0 {
    return
  }
  if end - start == 1 {
    let it = items[start]
    let share = pct_of(it.bytes, total_mod)
    let rx = round2(x + 1.0)
    let ry = round2(y + 1.0)
    let rw = round2(if w > 2.0 { w - 2.0 } else { 1.0 })
    let rh = round2(if h > 2.0 { h - 2.0 } else { 1.0 })
    out.write_string(
      "<g class=\"tm-tile\" data-func-idx=\"\{it.func_idx}\" data-name=\"\{xml_escape(it.label)}\">",
    )
    out.write_string(
      "<title>\{xml_escape(it.label)} | \{it.bytes} B (\{share}%) | \{xml_escape(it.detail)}</title>",
    )
    out.write_string(
      "<rect x=\"\{rx}\" y=\"\{ry}\" width=\"\{rw}\" height=\"\{rh}\" rx=\"3\" fill=\"\{it.color}\" stroke=\"#ffffff\" stroke-width=\"1\"/>",
    )
    if rh >= 22.0 {
      let lbl = fit_tile_label(it.label, rw)
      if !lbl.is_empty() {
        out.write_string(
          "<text x=\"\{round2(rx + 5.0)}\" y=\"\{round2(ry + 15.0)}\" font-size=\"11\" font-weight=\"600\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#0f172a\">\{xml_escape(lbl)}</text>",
        )
      }
      if rh >= 38.0 && rw >= 58.0 {
        out.write_string(
          "<text x=\"\{round2(rx + 5.0)}\" y=\"\{round2(ry + 29.0)}\" font-size=\"10\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#334155\">\{it.bytes} B (\{share}%)</text>",
        )
      }
    }
    out.write_string("</g>\n")
    return
  }
  let mut sum = 0L
  for i in start..<end {
    sum += items[i].bytes.to_int64()
  }
  if sum <= 0L {
    return
  }
  let half = sum / 2L
  let mut acc = 0L
  let mut split = start + 1
  for i in start..<(end - 1) {
    acc += items[i].bytes.to_int64()
    split = i + 1
    if acc >= half {
      break
    }
  }
  let frac = acc.to_double() / sum.to_double()
  if w >= h {
    let w1 = w * frac
    layout_treemap(out, items, start, split, x, y, w1, h, total_mod)
    layout_treemap(out, items, split, end, x + w1, y, w - w1, h, total_mod)
  } else {
    let h1 = h * frac
    layout_treemap(out, items, start, split, x, y, w, h1, total_mod)
    layout_treemap(out, items, split, end, x, y + h1, w, h - h1, total_mod)
  }
}

///|
/// Render an interactive pure-MoonBit binary-partition SVG Treemap of module size attribution.
pub fn render_treemap_svg(
  report : ModuleReport,
  title~ : String = "moon-wasm-opt Binary Size Treemap",
  width~ : Int32 = 1100,
  height~ : Int32 = 420,
) -> String {
  let w = if width < 600 { 600.0 } else { width.to_double() }
  let h = if height < 280 { 280.0 } else { height.to_double() }
  let items : Array[TileItem] = []

  let mut top_func_sum = 0
  for f in report.top_functions {
    if f.bytes > 0 {
      top_func_sum += f.bytes
      items.push({
        label: f.name,
        detail: "func #\{f.func_idx} | \{f.instr_count} instrs | \{f.local_count} locals",
        bytes: f.bytes,
        func_idx: f.func_idx.reinterpret_as_int(),
        color: tile_color(f.name, true),
      })
    }
  }
  let rest_code = report.code_bytes - top_func_sum
  if rest_code > 0 {
    items.push({
      label: "(other functions)",
      detail: "remaining code section bodies",
      bytes: rest_code,
      func_idx: -1,
      color: "#94a3b8",
    })
  }
  for s in report.sections {
    if s.name != "code" && s.bytes > 0 {
      items.push({
        label: s.name,
        detail: "wasm section",
        bytes: s.bytes,
        func_idx: -1,
        color: tile_color(s.name, false),
      })
    }
  }
  items.sort_by((a, b) => b.bytes.compare(a.bytes))

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{w.to_int()} \{h.to_int()}\" width=\"100%\" class=\"moon-wasm-treemap\" data-total=\"\{report.total_bytes}\">\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#f8fafc\"/>\n")
  out.write_string(
    "<text x=\"12\" y=\"24\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#0f172a\">\{xml_escape(title)}</text>\n",
  )
  let kind = if report.is_wasmgc { "WasmGC" } else { "Linear Wasm 2.0" }
  out.write_string(
    "<text x=\"12\" y=\"42\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#475569\">\{kind} | total: \{report.total_bytes} B | code: \{report.code_bytes} B | funcs: \{report.defined_func_count} | types: \{report.type_count}</text>\n",
  )
  layout_treemap(
    out,
    items,
    0,
    items.length(),
    12.0,
    52.0,
    w - 24.0,
    h - 64.0,
    report.total_bytes,
  )
  out.write_string("</svg>\n")
  out.to_string()
}

///|
/// Compare two WebAssembly binaries and summarize total & per-function size deltas.
pub fn diff_modules(
  before_bytes : Bytes,
  after_bytes : Bytes,
  top_k~ : Int32 = 30,
) -> ModuleDiffReport raise WasmError {
  let r1 = analyze_module(before_bytes, top_k=100_000)
  let r2 = analyze_module(after_bytes, top_k=100_000)
  let map1 : Map[String, Int32] = Map([])
  let map2 : Map[String, Int32] = Map([])
  for f in r1.top_functions {
    map1[f.name] = map1.get(f.name).unwrap_or(0) + f.bytes
  }
  for f in r2.top_functions {
    map2[f.name] = map2.get(f.name).unwrap_or(0) + f.bytes
  }
  let all_names : Set[String] = Set([])
  for k, _ in map1 {
    all_names.add(k)
  }
  for k, _ in map2 {
    all_names.add(k)
  }
  let entries : Array[DiffFuncEntry] = []
  for name in all_names {
    let b = map1.get(name).unwrap_or(0)
    let a = map2.get(name).unwrap_or(0)
    let d = a - b
    if d != 0 {
      let status = if a == 0 {
        "eliminated"
      } else if b == 0 {
        "added"
      } else if d < 0 {
        "shrunk"
      } else {
        "grown"
      }
      entries.push({
        name,
        before_bytes: b,
        after_bytes: a,
        delta_bytes: d,
        status,
      })
    }
  }
  entries.sort_by((x, y) => {
    let ax = if x.delta_bytes < 0 { -x.delta_bytes } else { x.delta_bytes }
    let ay = if y.delta_bytes < 0 { -y.delta_bytes } else { y.delta_bytes }
    ay.compare(ax)
  })
  let limit = if top_k < 1 { 1 } else { top_k }
  let sliced : Array[DiffFuncEntry] = []
  for i in 0..<entries.length() {
    if i >= limit {
      break
    }
    sliced.push(entries[i])
  }
  let saved = r1.total_bytes - r2.total_bytes
  {
    before_bytes: r1.total_bytes,
    after_bytes: r2.total_bytes,
    saved_bytes: saved,
    saved_pct: pct_of(saved, r1.total_bytes),
    before_funcs: r1.defined_func_count,
    after_funcs: r2.defined_func_count,
    before_instrs: r1.total_instrs,
    after_instrs: r2.total_instrs,
    entries: sliced,
  }
}

///|
/// Render a module diff report as Markdown.
pub fn render_diff_markdown(diff : ModuleDiffReport) -> String {
  let out = StringBuilder()
  out.write_string("# moon-wasm-opt Binary Size Diff\n\n")
  out.write_string(
    "- **Size**: `\{diff.before_bytes}` B -> `\{diff.after_bytes}` B (**saved `\{diff.saved_bytes}` B / `\{diff.saved_pct}%`**)\n",
  )
  out.write_string(
    "- **Functions**: `\{diff.before_funcs}` -> `\{diff.after_funcs}` | **Instructions**: `\{diff.before_instrs}` -> `\{diff.after_instrs}`\n\n",
  )
  out.write_string(
    "| Function | Status | Before (B) | After (B) | Delta (B) |\n|---|---|---:|---:|---:|\n",
  )
  for e in diff.entries {
    out.write_string(
      "| `\{e.name}` | `\{e.status}` | \{e.before_bytes} | \{e.after_bytes} | \{e.delta_bytes} |\n",
    )
  }
  out.to_string()
}
