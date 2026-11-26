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
  enable_const_globals : Bool
  enable_inline : Bool
  enable_dce : Bool
  enable_peephole : Bool
  enable_simplify_cfg : Bool
  enable_locals : Bool
  enable_module_dce : Bool
  enable_icf : Bool
  enable_opt_data : Bool
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
) -> OptConfig {
  match level {
    O1 =>
      {
        level,
        converge: false,
        max_rounds: 1,
        strip_custom: false,
        keep_names: true,
        enable_const_globals: true,
        enable_inline: enable_inline.unwrap_or(false),
        enable_dce: true,
        enable_peephole: true,
        enable_simplify_cfg: true,
        enable_locals: false,
        enable_module_dce: false,
        enable_icf: false,
        enable_opt_data: false,
      }
    O2 =>
      {
        level,
        converge,
        max_rounds,
        strip_custom,
        keep_names,
        enable_const_globals: true,
        enable_inline: enable_inline.unwrap_or(true),
        enable_dce: true,
        enable_peephole: true,
        enable_simplify_cfg: true,
        enable_locals: true,
        enable_module_dce: true,
        enable_icf: false,
        enable_opt_data: true,
      }
    Os | Oz =>
      {
        level,
        converge,
        max_rounds,
        strip_custom,
        keep_names,
        enable_const_globals: true,
        enable_inline: enable_inline.unwrap_or(true),
        enable_dce: true,
        enable_peephole: true,
        enable_simplify_cfg: true,
        enable_locals: true,
        enable_module_dce: true,
        enable_icf: true,
        enable_opt_data: true,
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
  let mut cur_bytes = encode_module(cur)
  let mut cur_len = before_bytes
  let passes : Array[PassStats] = []

  fn run_pass(
    name : String,
    round : Int32,
    f : (WasmModule) -> WasmModule,
  ) -> Bool {
    let next = f(cur)
    let encoded = encode_module(next)
    let next_len = encoded.length()
    let saved = cur_len - next_len
    let changed = next != cur
    if changed || saved != 0 {
      passes.push({
        name,
        round,
        before_bytes: cur_len,
        after_bytes: next_len,
        saved_bytes: saved,
        saved_pct: pct_of(saved, before_bytes),
      })
      cur = next
      cur_bytes = encoded
      cur_len = next_len
      true
    } else {
      false
    }
  }

  // One-shot strip custom sections first (so size breakdown cleanly separates metadata vs bytecode passes)
  if config.strip_custom {
    ignore(
      run_pass("strip-custom", 1, m => {
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
    if config.enable_const_globals {
      if run_pass("const-globals", round, m => {
          pass_const_globals(m, prefer_speed~)
        }) {
        any_change = true
      }
    }
    if config.enable_peephole {
      if run_pass("const-fold+peephole", round, pass_peephole) {
        any_change = true
      }
    }
    if config.enable_simplify_cfg {
      if run_pass("simplify-cfg", round, pass_simplify_cfg) {
        any_change = true
      }
    }
    if config.enable_dce {
      if run_pass("dce-instr", round, pass_dce_instr) {
        any_change = true
      }
    }
    if config.enable_locals {
      if run_pass("local-opt", round, pass_local_opt) {
        any_change = true
      }
    }
    if config.enable_module_dce {
      if run_pass("module-dce", round, pass_module_dce) {
        any_change = true
      }
    }
    if config.enable_icf {
      if run_pass("merge-funcs (ICF)", round, pass_merge_funcs) {
        any_change = true
      }
    }
    // Inline AFTER ICF so identical single-use helpers merge before being inlined, then immediately clean up dead callees
    if config.enable_inline {
      if run_pass("inline", round, m => {
          pass_inline(
            m,
            prefer_speed~,
            max_multi_instrs=multi_limit,
            max_single_instrs=single_limit,
          )
        }) {
        any_change = true
        if config.enable_peephole {
          ignore(run_pass("const-fold+peephole", round, pass_peephole))
        }
        if config.enable_simplify_cfg {
          ignore(run_pass("simplify-cfg", round, pass_simplify_cfg))
        }
        if config.enable_dce {
          ignore(run_pass("dce-instr", round, pass_dce_instr))
        }
        if config.enable_locals {
          ignore(run_pass("local-opt", round, pass_local_opt))
        }
        if config.enable_module_dce {
          ignore(run_pass("module-dce", round, pass_module_dce))
        }
      }
    }
    if config.enable_opt_data {
      if run_pass("opt-data", round, m => pass_opt_data(m, allow_split=true)) {
        any_change = true
      }
    }
    if !config.converge || !any_change || cur_len >= round_start_len {
      break
    }
  }

  // Final output: if pipeline made zero changes and encoded length wasn't smaller, preserve original bytes when unchanged
  let final_bytes = if passes.is_empty() { bytes } else { cur_bytes }
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
