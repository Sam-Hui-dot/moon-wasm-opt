///|
let usage : String =
  #|moon-wasm-opt inspect <FILE.wasm> [--top-k N] [--format text|json|md|svg] [--out FILE]
  #|moon-wasm-opt disasm <FILE.wasm> --func <IDX_OR_NAME> [--out FILE]
  #|moon-wasm-opt opt <IN.wasm> --out <OUT.wasm> [-O1|-O2|-Os|-Oz] [--no-converge] [--no-inline] [--keep-names] [--keep-custom] [--report-format text|json|md|svg] [--report-out FILE]
  #|moon-wasm-opt diff <BEFORE.wasm> <AFTER.wasm> [--top-k N] [--format text|json|md] [--out FILE]
  #|moon-wasm-opt roundtrip <IN.wasm> --out <OUT.wasm>

///|
fn parse_int_arg(
  flag : String,
  raw : String,
) -> Int32 raise @moon-wasm-opt.WasmError {
  @string.parse_int(raw) catch {
    _ =>
      raise @moon-wasm-opt.WasmError::InvalidInput(
        "invalid integer for \{flag}: \{raw}",
      )
  }
}

///|
fn next_flag_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> String raise @moon-wasm-opt.WasmError {
  guard index + 1 < args.length() else {
    raise @moon-wasm-opt.WasmError::InvalidInput("\{flag} requires a value")
  }
  args[index + 1]
}

///|
async fn emit_text(content : String, out_path : String?) -> Unit {
  match out_path {
    Some(p) => @fs.write_file(p, content, create_mode=CreateOrTruncate)
    None => println(content)
  }
}

///|
async fn cmd_inspect(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
  let file = args[1]
  let mut top_k = 25
  let mut format = "text"
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--top-k" => {
        top_k = parse_int_arg("--top-k", next_flag_value(args, i, "--top-k"))
        i += 2
      }
      "--format" => {
        format = next_flag_value(args, i, "--format")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-wasm-opt.WasmError::InvalidInput("unknown option: \{other}")
    }
  }
  let bytes = @fs.read_file(file).binary()
  let report = @moon-wasm-opt.analyze_module(bytes, top_k~)
  let rendered = match format {
    "text" => @moon-wasm-opt.render_module_text(report)
    "json" => @json.ToJson::to_json(report).stringify()
    "md" | "markdown" => @moon-wasm-opt.render_module_markdown(report)
    "svg" => @moon-wasm-opt.render_treemap_svg(report)
    _ =>
      raise @moon-wasm-opt.WasmError::InvalidInput(
        "unsupported --format: \{format}",
      )
  }
  emit_text(rendered, out_path)
  0
}

///|
async fn cmd_disasm(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
  let file = args[1]
  let mut func_q = ""
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--func" => {
        func_q = next_flag_value(args, i, "--func")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-wasm-opt.WasmError::InvalidInput("unknown option: \{other}")
    }
  }
  guard !func_q.is_empty() else {
    raise @moon-wasm-opt.WasmError::InvalidInput(
      "disasm requires --func <IDX_OR_NAME>",
    )
  }
  let bytes = @fs.read_file(file).binary()
  let mod = @moon-wasm-opt.decode_module(bytes)
  guard @moon-wasm-opt.find_function_index(mod, func_q) is Some(fidx) else {
    raise @moon-wasm-opt.WasmError::InvalidInput(
      "no function matching '\{func_q}'",
    )
  }
  let wat = @moon-wasm-opt.disassemble_function(mod, fidx)
  emit_text(wat, out_path)
  0
}

///|
async fn cmd_opt(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
  let file = args[1]
  let mut out_path : String? = None
  let mut level : @moon-wasm-opt.OptLevel = Oz
  let mut converge = true
  let mut enable_inline : Bool? = None
  let mut strip_custom = true
  let mut keep_names = false
  let mut report_format = "text"
  let mut report_out : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--out" | "-o" => {
        out_path = Some(next_flag_value(args, i, args[i]))
        i += 2
      }
      "-O1" => {
        level = O1
        i += 1
      }
      "-O2" => {
        level = O2
        i += 1
      }
      "-Os" => {
        level = Os
        i += 1
      }
      "-Oz" => {
        level = Oz
        i += 1
      }
      "--converge" => {
        converge = true
        i += 1
      }
      "--no-converge" => {
        converge = false
        i += 1
      }
      "--no-inline" => {
        enable_inline = Some(false)
        i += 1
      }
      "--keep-names" => {
        keep_names = true
        i += 1
      }
      "--keep-custom" => {
        strip_custom = false
        i += 1
      }
      "--report-format" => {
        report_format = next_flag_value(args, i, "--report-format")
        i += 2
      }
      "--report-out" => {
        report_out = Some(next_flag_value(args, i, "--report-out"))
        i += 2
      }
      other =>
        raise @moon-wasm-opt.WasmError::InvalidInput("unknown option: \{other}")
    }
  }
  guard out_path is Some(dest) else {
    raise @moon-wasm-opt.WasmError::InvalidInput("opt requires --out <FILE>")
  }
  let raw = @fs.read_file(file).binary()
  let cfg = @moon-wasm-opt.opt_config(
    level~,
    converge~,
    strip_custom~,
    keep_names~,
    enable_inline~,
  )
  let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(raw, config=cfg)
  @fs.write_file(dest, opt_bytes, create_mode=CreateOrTruncate)
  let rendered = match report_format {
    "text" => @moon-wasm-opt.render_opt_report_text(report)
    "json" => @json.ToJson::to_json(report).stringify()
    "md" | "markdown" => @moon-wasm-opt.render_opt_report_markdown(report)
    "svg" => @moon-wasm-opt.render_opt_waterfall_svg(report)
    _ =>
      raise @moon-wasm-opt.WasmError::InvalidInput(
        "unsupported --report-format: \{report_format}",
      )
  }
  emit_text(rendered, report_out)
  0
}

///|
async fn cmd_diff(args : Array[String]) -> Int32 {
  guard args.length() >= 3 else {
    raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
  let before_file = args[1]
  let after_file = args[2]
  let mut top_k = 30
  let mut format = "text"
  let mut out_path : String? = None
  let mut i = 3
  while i < args.length() {
    match args[i] {
      "--top-k" => {
        top_k = parse_int_arg("--top-k", next_flag_value(args, i, "--top-k"))
        i += 2
      }
      "--format" => {
        format = next_flag_value(args, i, "--format")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-wasm-opt.WasmError::InvalidInput("unknown option: \{other}")
    }
  }
  let b1 = @fs.read_file(before_file).binary()
  let b2 = @fs.read_file(after_file).binary()
  let diff = @moon-wasm-opt.diff_modules(b1, b2, top_k~)
  let rendered = match format {
    "json" => @json.ToJson::to_json(diff).stringify()
    "md" | "markdown" => @moon-wasm-opt.render_diff_markdown(diff)
    "text" =>
      "Diff: \{diff.before_bytes} B -> \{diff.after_bytes} B (saved \{diff.saved_bytes} B / \{diff.saved_pct}%), funcs \{diff.before_funcs} -> \{diff.after_funcs}, instrs \{diff.before_instrs} -> \{diff.after_instrs}"
    _ =>
      raise @moon-wasm-opt.WasmError::InvalidInput(
        "unsupported --format: \{format}",
      )
  }
  emit_text(rendered, out_path)
  0
}

///|
async fn cmd_roundtrip(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
  let file = args[1]
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--out" | "-o" => {
        out_path = Some(next_flag_value(args, i, args[i]))
        i += 2
      }
      other =>
        raise @moon-wasm-opt.WasmError::InvalidInput("unknown option: \{other}")
    }
  }
  guard out_path is Some(dest) else {
    raise @moon-wasm-opt.WasmError::InvalidInput(
      "roundtrip requires --out <FILE>",
    )
  }
  let raw = @fs.read_file(file).binary()
  let mod = @moon-wasm-opt.decode_module(raw)
  let encoded = @moon-wasm-opt.encode_module(mod)
  @fs.write_file(dest, encoded, create_mode=CreateOrTruncate)
  println(
    "roundtrip \{file} -> \{dest} (\{raw.length()} B -> \{encoded.length()} B, \{mod.codes.length()} funcs, \{mod.total_type_count()} types)",
  )
  0
}

///|
async fn run(args : Array[String]) -> Int32 {
  match args.get(0) {
    Some("inspect") => cmd_inspect(args)
    Some("disasm") => cmd_disasm(args)
    Some("opt") => cmd_opt(args)
    Some("diff") => cmd_diff(args)
    Some("roundtrip") => cmd_roundtrip(args)
    _ => raise @moon-wasm-opt.WasmError::InvalidInput(usage)
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  let exit_code = match
    (@async.with_timeout_opt(60_000, () => run(args[1:].to_owned())) catch {
      error => {
        println(@moon-wasm-opt.error_message(error))
        Some(2)
      }
    }) {
    Some(code) => code
    None => {
      println("operation timed out after 60s")
      2
    }
  }
  @env.exit(exit_code)
}
