///|
/// Preset optimization level mirroring Binaryen `wasm-opt`.
#derive(Debug, Eq, ToJson)
pub(all) enum OptLevel {
  O1
  O2
  Os
  Oz
}

///|
pub extend OptLevel with @debug.Debug::{to_repr}

///|
pub extend OptLevel with Eq::{not_equal, equal}

///|
pub extend OptLevel with @json.ToJson::{to_json}

///|
/// Configuration controlling which optimization passes and convergence behavior run.
#derive(Debug, Eq, ToJson)
pub(all) struct OptConfig {
  level : OptLevel
  converge : Bool
  max_rounds : Int32
  strip_custom : Bool
  keep_names : Bool
  enable_dedup_types : Bool
  enable_const_globals : Bool
  enable_dae : Bool
  enable_inline : Bool
  enable_dce : Bool
  enable_peephole : Bool
  enable_wasmgc : Bool
  enable_simplify_cfg : Bool
  enable_liveness : Bool
  enable_coalesce : Bool
  enable_locals : Bool
  enable_module_dce : Bool
  enable_icf : Bool
  enable_opt_data : Bool
  enable_code_folding : Bool
  enable_write_only_globals : Bool
  enable_simd : Bool
}

///|
pub extend OptConfig with @debug.Debug::{to_repr}

///|
pub extend OptConfig with Eq::{not_equal, equal}

///|
pub extend OptConfig with @json.ToJson::{to_json}

///|
/// Build an `OptConfig` from a preset level (`O1`, `O2`, `Os`, `Oz`) with optional overrides.
pub fn opt_config(
  level~ : OptLevel = Oz,
  converge~ : Bool = true,
  max_rounds~ : Int32 = 8,
  strip_custom~ : Bool = true,
  keep_names~ : Bool = false,
  enable_inline~ : Bool? = None,
  enable_coalesce~ : Bool? = None,
  enable_dae~ : Bool? = None,
) -> OptConfig {
  match level {
    O1 =>
      {
        level,
        converge: false,
        max_rounds: 1,
        strip_custom: false,
        keep_names: true,
        enable_dedup_types: false,
        enable_const_globals: true,
        enable_dae: enable_dae.unwrap_or(false),
        enable_inline: enable_inline.unwrap_or(false),
        enable_dce: true,
        enable_peephole: true,
        enable_wasmgc: true,
        enable_simplify_cfg: true,
        enable_liveness: true,
        enable_coalesce: enable_coalesce.unwrap_or(false),
        enable_locals: false,
        enable_module_dce: false,
        enable_icf: false,
        enable_opt_data: false,
        enable_code_folding: false,
        enable_write_only_globals: true,
        enable_simd: true,
      }
    O2 =>
      {
        level,
        converge,
        max_rounds,
        strip_custom,
        keep_names,
        enable_dedup_types: true,
        enable_const_globals: true,
        enable_dae: enable_dae.unwrap_or(true),
        enable_inline: enable_inline.unwrap_or(true),
        enable_dce: true,
        enable_peephole: true,
        enable_wasmgc: true,
        enable_simplify_cfg: true,
        enable_liveness: true,
        enable_coalesce: enable_coalesce.unwrap_or(true),
        enable_locals: true,
        enable_module_dce: true,
        enable_icf: false,
        enable_opt_data: true,
        enable_code_folding: true,
        enable_write_only_globals: true,
        enable_simd: true,
      }
    Os | Oz =>
      {
        level,
        converge,
        max_rounds,
        strip_custom,
        keep_names,
        enable_dedup_types: true,
        enable_const_globals: true,
        enable_dae: enable_dae.unwrap_or(true),
        enable_inline: enable_inline.unwrap_or(true),
        enable_dce: true,
        enable_peephole: true,
        enable_wasmgc: true,
        enable_simplify_cfg: true,
        enable_liveness: true,
        enable_coalesce: enable_coalesce.unwrap_or(true),
        enable_locals: true,
        enable_module_dce: true,
        enable_icf: true,
        enable_opt_data: true,
        enable_code_folding: true,
        enable_write_only_globals: true,
        enable_simd: true,
      }
  }
}

///|
/// Byte-savings accounting for a single pass execution.
#derive(Debug, Eq, ToJson)
pub(all) struct PassStats {
  name : String
  round : Int32
  before_bytes : Int32
  after_bytes : Int32
  saved_bytes : Int32
  saved_pct : Double
}

///|
pub extend PassStats with @debug.Debug::{to_repr}

///|
pub extend PassStats with Eq::{not_equal, equal}

///|
pub extend PassStats with @json.ToJson::{to_json}

///|
/// Full end-to-end optimization summary report with pass-by-pass byte breakdown.
#derive(Debug, Eq, ToJson)
pub(all) struct OptReport {
  preset : String
  rounds : Int32
  is_wasmgc : Bool
  before_bytes : Int32
  after_bytes : Int32
  saved_bytes : Int32
  saved_pct : Double
  before_funcs : Int32
  after_funcs : Int32
  before_types : Int32
  after_types : Int32
  before_instrs : Int32
  after_instrs : Int32
  passes : Array[PassStats]
}

///|
pub extend OptReport with @debug.Debug::{to_repr}

///|
pub extend OptReport with Eq::{not_equal, equal}

///|
pub extend OptReport with @json.ToJson::{to_json}

///|
fn preset_label(level : OptLevel, converge : Bool) -> String {
  let base = match level {
    O1 => "-O1"
    O2 => "-O2"
    Os => "-Os"
    Oz => "-Oz"
  }
  if converge {
    "\{base} --converge"
  } else {
    base
  }
}

///|
fn module_total_instrs(mod : WasmModule) -> Int32 {
  let mut total = 0
  for fb in mod.codes {
    total += count_instrs(fb.body)
  }
  total
}

///|
/// Run the configured optimization pipeline directly on raw `.wasm` / `.wasm-gc` bytes and return `(optimized_bytes, OptReport)`.
pub fn optimize_bytes(
  bytes : Bytes,
  config~ : OptConfig = opt_config(),
) -> (Bytes, OptReport) raise WasmError {
  let initial = decode_module(bytes)
  let before_bytes = bytes.length()
  let before_funcs = initial.codes.length()
  let before_types = initial.total_type_count().reinterpret_as_int()
  let before_instrs = module_total_instrs(initial)
  let is_gc = module_uses_wasmgc(initial)

  let mut cur = initial
  let mut prefix_len = encode_non_code_prefix_len(cur)
  let mut suffix_len = encode_non_code_suffix_len(cur)
  let mut body_lens : Array[Int32] = cur.codes.map(fb => {
    encode_func_body(fb).length()
  })
  let mut cur_len = before_bytes
  let passes : Array[PassStats] = []

  // Per-pass dirty function bitmasks (`0..8`) eliminate scanning already-converged functions across cleanup & rounds
  let num_dirty_tracks = 9
  let pass_dirty : Array[Array[Bool]] = Array::makei(num_dirty_tracks, _ => {
    Array::make(cur.codes.length(), true)
  })
  let mut icf_needed = true

  fn reset_all_dirty(n : Int32) -> Unit {
    for k in 0..<num_dirty_tracks {
      pass_dirty[k] = Array::make(n, true)
    }
    icf_needed = true
  }

  fn propagate_dirty(skip_track : Int32, changed_mask : Array[Bool]) -> Unit {
    let n = changed_mask.length()
    for i in 0..<n {
      if changed_mask[i] {
        icf_needed = true
        for k in 0..<num_dirty_tracks {
          if k != skip_track {
            pass_dirty[k][i] = true
          }
        }
      }
    }
  }

  fn has_any_dirty(track_id : Int32) -> Bool {
    if track_id < 0 || track_id >= num_dirty_tracks {
      return true
    }
    for b in pass_dirty[track_id] {
      if b {
        return true
      }
    }
    false
  }

  fn sync_code_lengths(next_codes : Array[FuncBody]) -> Int32 {
    let n = next_codes.length()
    if n == body_lens.length() && n == cur.codes.length() {
      for i in 0..<n {
        if !physical_equal(next_codes[i], cur.codes[i]) {
          body_lens[i] = encode_func_body(next_codes[i]).length()
        }
      }
    } else {
      body_lens = next_codes.map(fb => encode_func_body(fb).length())
    }
    prefix_len + code_section_total_len(body_lens) + suffix_len
  }

  fn mark_codes_changed_vs_cur(next_codes : Array[FuncBody]) -> Unit {
    let n = next_codes.length()
    if n != cur.codes.length() {
      reset_all_dirty(n)
      return
    }
    let mask = Array::makei(n, i => !physical_equal(next_codes[i], cur.codes[i]))
    propagate_dirty(-1, mask)
  }

  fn run_code_pass(
    name : String,
    round : Int32,
    f : (WasmModule) -> WasmModule,
  ) -> Bool {
    let next = f(cur)
    if physical_equal(next, cur) {
      return false
    }
    mark_codes_changed_vs_cur(next.codes)
    let next_len = sync_code_lengths(next.codes)
    let saved = cur_len - next_len
    passes.push({
      name,
      round,
      before_bytes: cur_len,
      after_bytes: next_len,
      saved_bytes: saved,
      saved_pct: pct_of(saved, before_bytes),
    })
    cur = next
    cur_len = next_len
    true
  }

  fn run_dirty_pass(
    name : String,
    round : Int32,
    track_id : Int32,
    f : (WasmModule, Array[Bool]?) -> (WasmModule, Array[Bool]),
  ) -> Bool {
    if !has_any_dirty(track_id) {
      return false
    }
    let work = pass_dirty[track_id]
    let (next, changed_mask) = f(cur, Some(work))
    pass_dirty[track_id] = Array::make(next.codes.length(), false)
    if physical_equal(next, cur) {
      return false
    }
    propagate_dirty(track_id, changed_mask)
    let next_len = sync_code_lengths(next.codes)
    let saved = cur_len - next_len
    passes.push({
      name,
      round,
      before_bytes: cur_len,
      after_bytes: next_len,
      saved_bytes: saved,
      saved_pct: pct_of(saved, before_bytes),
    })
    cur = next
    cur_len = next_len
    true
  }

  fn run_module_pass(
    name : String,
    round : Int32,
    codes_may_change : Bool,
    f : (WasmModule) -> WasmModule,
  ) -> Bool {
    let next = f(cur)
    if physical_equal(next, cur) || next == cur {
      return false
    }
    if codes_may_change {
      reset_all_dirty(next.codes.length())
    }
    prefix_len = encode_non_code_prefix_len(next)
    suffix_len = encode_non_code_suffix_len(next)
    let next_len = if codes_may_change {
      sync_code_lengths(next.codes)
    } else {
      prefix_len + code_section_total_len(body_lens) + suffix_len
    }
    let saved = cur_len - next_len
    passes.push({
      name,
      round,
      before_bytes: cur_len,
      after_bytes: next_len,
      saved_bytes: saved,
      saved_pct: pct_of(saved, before_bytes),
    })
    cur = next
    cur_len = next_len
    true
  }

  // One-shot strip custom sections first (so size breakdown cleanly separates metadata vs bytecode passes)
  if config.strip_custom {
    ignore(
      run_module_pass("strip-custom", 1, false, m => {
        pass_strip_custom(m, keep_names=config.keep_names)
      }),
    )
  }

  let limit = if config.converge {
    if config.max_rounds < 1 {
      1
    } else {
      config.max_rounds
    }
  } else {
    1
  }

  let mut rounds_run = 0
  let prefer_speed = config.level == O2
  let (multi_limit, single_limit) = match config.level {
    O2 => (14, 96)
    _ => (6, 80)
  }
  for round in 1..<=limit {
    rounds_run = round
    let round_start_len = cur_len
    let mut any_change = false
    if config.enable_dedup_types {
      if run_module_pass("dedup-types", round, true, pass_dedup_types) {
        any_change = true
      }
    }
    if config.enable_const_globals {
      if run_code_pass("const-globals", round, m => {
          pass_const_globals(m, prefer_speed~)
        }) {
        any_change = true
      }
    }
    if config.enable_write_only_globals {
      if run_code_pass("write-only-globals", round, pass_write_only_globals) {
        any_change = true
      }
    }
    if config.enable_dae {
      if run_module_pass("dae", round, true, pass_dae) {
        any_change = true
      }
    }
    if config.enable_simd {
      if run_dirty_pass("simd-opt", round, 0, pass_opt_simd_dirty) {
        any_change = true
      }
    }
    if config.enable_peephole {
      if run_dirty_pass("const-fold+peephole", round, 1, pass_peephole_dirty) {
        any_change = true
      }
    }
    if config.enable_wasmgc {
      if run_dirty_pass("wasmgc-opt", round, 2, pass_wasmgc_opt_dirty) {
        any_change = true
      }
    }
    if config.enable_code_folding {
      if run_dirty_pass("code-folding", round, 3, pass_code_folding_dirty) {
        any_change = true
      }
    }
    if config.enable_simplify_cfg {
      if run_dirty_pass("simplify-cfg", round, 4, pass_simplify_cfg_dirty) {
        any_change = true
      }
    }
    if config.enable_dce {
      if run_dirty_pass("dce-instr", round, 5, pass_dce_instr_dirty) {
        any_change = true
      }
    }
    if config.enable_liveness {
      if run_dirty_pass("local-dse", round, 6, pass_local_dse_dirty) {
        any_change = true
        if config.enable_peephole {
          ignore(
            run_dirty_pass("const-fold+peephole", round, 1, pass_peephole_dirty),
          )
        }
      }
    }
    if config.enable_coalesce {
      if run_dirty_pass("coalesce-locals", round, 7, pass_coalesce_locals_dirty) {
        any_change = true
        if config.enable_peephole {
          ignore(
            run_dirty_pass("const-fold+peephole", round, 1, pass_peephole_dirty),
          )
        }
      }
    }
    if config.enable_locals {
      if run_dirty_pass("local-opt", round, 8, pass_local_opt_dirty) {
        any_change = true
      }
    }
    if config.enable_module_dce {
      if run_module_pass("module-dce", round, true, pass_module_dce) {
        any_change = true
      }
    }
    if config.enable_icf && icf_needed {
      icf_needed = false
      if run_module_pass("merge-funcs (ICF)", round, true, pass_merge_funcs) {
        any_change = true
      }
    }
    // Inline AFTER ICF so identical single-use helpers merge before being inlined, then immediately clean up dead callees
    if config.enable_inline {
      if run_code_pass("inline", round, m => {
          pass_inline(
            m,
            prefer_speed~,
            max_multi_instrs=multi_limit,
            max_single_instrs=single_limit,
          )
        }) {
        any_change = true
        if config.enable_peephole {
          ignore(
            run_dirty_pass("const-fold+peephole", round, 1, pass_peephole_dirty),
          )
        }
        if config.enable_wasmgc {
          ignore(run_dirty_pass("wasmgc-opt", round, 2, pass_wasmgc_opt_dirty))
        }
        if config.enable_code_folding {
          ignore(
            run_dirty_pass("code-folding", round, 3, pass_code_folding_dirty),
          )
        }
        if config.enable_simplify_cfg {
          ignore(
            run_dirty_pass("simplify-cfg", round, 4, pass_simplify_cfg_dirty),
          )
        }
        if config.enable_dce {
          ignore(run_dirty_pass("dce-instr", round, 5, pass_dce_instr_dirty))
        }
        if config.enable_liveness {
          ignore(run_dirty_pass("local-dse", round, 6, pass_local_dse_dirty))
        }
        if config.enable_locals {
          ignore(run_dirty_pass("local-opt", round, 8, pass_local_opt_dirty))
        }
        if config.enable_module_dce {
          ignore(run_module_pass("module-dce", round, true, pass_module_dce))
        }
      }
    }
    if config.enable_opt_data && round == 1 {
      if run_module_pass("opt-data", round, false, m => {
          pass_opt_data(m, allow_split=true)
        }) {
        any_change = true
      }
    }
    if !config.converge || !any_change || cur_len >= round_start_len {
      break
    }
  }

  // Encode full optimized module ONCE at the very end (preserving original bytes if zero passes triggered)
  let final_bytes = if passes.is_empty() { bytes } else { encode_module(cur) }
  let after_bytes = final_bytes.length()
  let saved_bytes = before_bytes - after_bytes

  let report : OptReport = {
    preset: preset_label(config.level, config.converge),
    rounds: rounds_run,
    is_wasmgc: is_gc,
    before_bytes,
    after_bytes,
    saved_bytes,
    saved_pct: pct_of(saved_bytes, before_bytes),
    before_funcs,
    after_funcs: cur.codes.length(),
    before_types,
    after_types: cur.total_type_count().reinterpret_as_int(),
    before_instrs,
    after_instrs: module_total_instrs(cur),
    passes,
  }
  (final_bytes, report)
}

///|
/// Render an optimization report as plain text.
pub fn render_opt_report_text(report : OptReport) -> String {
  let out = StringBuilder()
  let kind = if report.is_wasmgc { "WasmGC" } else { "Linear Wasm 2.0" }
  out.write_string(
    "moon-wasm-opt (\{kind}, \{report.preset}, rounds=\{report.rounds})\n",
  )
  out.write_string(
    "Size: \{report.before_bytes} B -> \{report.after_bytes} B (saved \{report.saved_bytes} B / \{report.saved_pct}%)\n",
  )
  out.write_string(
    "Funcs: \{report.before_funcs} -> \{report.after_funcs} | Types: \{report.before_types} -> \{report.after_types} | Instrs: \{report.before_instrs} -> \{report.after_instrs}\n",
  )
  if !report.passes.is_empty() {
    out.write_string("Passes:\n")
    for p in report.passes {
      out.write_string(
        "  [r\{p.round}] \{p.name}: \{p.before_bytes} -> \{p.after_bytes} B (saved \{p.saved_bytes} B / \{p.saved_pct}%)\n",
      )
    }
  }
  out.to_string()
}

///|
/// Render an optimization report as GitHub-flavored Markdown.
pub fn render_opt_report_markdown(report : OptReport) -> String {
  let out = StringBuilder()
  let kind = if report.is_wasmgc { "WasmGC" } else { "Linear Wasm 2.0" }
  out.write_string("# moon-wasm-opt Optimization Report\n\n")
  out.write_string(
    "- **Target Format**: `\{kind}`\n- **Preset**: `\{report.preset}` (\{report.rounds} round(s))\n- **Binary Size**: `\{report.before_bytes}` B -> `\{report.after_bytes}` B (**saved `\{report.saved_bytes}` B / `\{report.saved_pct}%`**)\n- **Functions**: `\{report.before_funcs}` -> `\{report.after_funcs}` | **Types**: `\{report.before_types}` -> `\{report.after_types}` | **Instructions**: `\{report.before_instrs}` -> `\{report.after_instrs}`\n\n",
  )
  if !report.passes.is_empty() {
    out.write_string(
      "## Pass Breakdown\n\n| Round | Pass | Before (B) | After (B) | Saved (B) | Share of Original |\n|---:|---|---:|---:|---:|---:|\n",
    )
    for p in report.passes {
      out.write_string(
        "| \{p.round} | `\{p.name}` | \{p.before_bytes} | \{p.after_bytes} | \{p.saved_bytes} | \{p.saved_pct}% |\n",
      )
    }
  }
  out.to_string()
}

///|
/// Render a native horizontal SVG waterfall chart showing each pass's exact byte savings.
pub fn render_opt_waterfall_svg(
  report : OptReport,
  title~ : String = "moon-wasm-opt Pass Savings Waterfall",
  width~ : Int32 = 960,
) -> String {
  let w = if width < 600 { 600.0 } else { width.to_double() }
  let rows : Array[(String, Int32, String)] = []
  rows.push(("Original Binary", report.before_bytes, "#64748b"))
  for p in report.passes {
    if p.saved_bytes > 0 {
      let col = if p.name == "strip-custom" {
        "#94a3b8"
      } else if p.name.contains("ICF") {
        "#8b5cf6"
      } else if p.name.contains("module-dce") {
        "#0ea5e9"
      } else if p.name.contains("coalesce") {
        "#2563eb"
      } else if p.name.contains("local-dse") {
        "#0284c7"
      } else if p.name.contains("wasmgc") || p.name.contains("dedup-types") {
        "#7c3aed"
      } else if p.name == "dae" {
        "#d946ef"
      } else if p.name.contains("inline") {
        "#ec4899"
      } else if p.name.contains("simplify-cfg") {
        "#f97316"
      } else if p.name.contains("opt-data") {
        "#14b8a6"
      } else if p.name.contains("const-globals") {
        "#6366f1"
      } else if p.name.contains("peephole") {
        "#f59e0b"
      } else {
        "#10b981"
      }
      rows.push(("-\{p.name} (r\{p.round})", p.saved_bytes, col))
    }
  }
  rows.push(("Optimized Binary", report.after_bytes, "#059669"))

  let row_h = 26.0
  let pad_top = 56.0
  let label_w = 210.0
  let right_pad = 120.0
  let bar_max_w = w - label_w - right_pad
  let h = pad_top + rows.length().to_double() * row_h + 18.0
  let denom = if report.before_bytes > 0 {
    report.before_bytes.to_double()
  } else {
    1.0
  }

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{w.to_int()} \{h.to_int()}\" width=\"100%\" class=\"moon-wasm-waterfall\" data-saved=\"\{report.saved_bytes}\">\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#f8fafc\"/>\n")
  out.write_string(
    "<text x=\"12\" y=\"24\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#0f172a\">\{xml_escape(title)}</text>\n",
  )
  out.write_string(
    "<text x=\"12\" y=\"42\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#475569\">\{xml_escape(report.preset)} | \{report.before_bytes} B -&gt; \{report.after_bytes} B (saved \{report.saved_bytes} B / \{report.saved_pct}%)</text>\n",
  )

  for i, item in rows {
    let (lbl, val, col) = item
    let y = pad_top + i.to_double() * row_h
    let bw = bar_max_w * (val.to_double() / denom)
    let draw_w = if bw < 3.0 && val > 0 { 3.0 } else { bw }
    let share = pct_of(val, report.before_bytes)
    out.write_string(
      "<text x=\"\{round2(label_w - 8.0)}\" y=\"\{round2(y + 16.0)}\" text-anchor=\"end\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#1e293b\">\{xml_escape(lbl)}</text>\n",
    )
    out.write_string(
      "<rect x=\"\{round2(label_w)}\" y=\"\{round2(y + 4.0)}\" width=\"\{round2(draw_w)}\" height=\"16\" rx=\"3\" fill=\"\{col}\"><title>\{xml_escape(lbl)}: \{val} B (\{share}%)</title></rect>\n",
    )
    out.write_string(
      "<text x=\"\{round2(label_w + draw_w + 6.0)}\" y=\"\{round2(y + 16.0)}\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#334155\">\{val} B (\{share}%)</text>\n",
    )
  }
  out.write_string("</svg>\n")
  out.to_string()
}
