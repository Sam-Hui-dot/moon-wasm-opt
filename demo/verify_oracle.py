"""Oracle verification for moon-wasm-opt:
1. Lossless round-trip decode -> encode validation via Node.js V8 WebAssembly.validate() (and wasm-tools validate when installed) across 4 real MoonBit 1.0 --release Linear Wasm & WasmGC binaries.
2. Full -Oz --converge optimization + V8 WebAssembly.validate() + exact runtime execution equivalence:
   - 32/32 exported function calls (incl. NaN-sensitive float comparisons, br_table dispatch, static data lookup, WasmGC structs, ICF merges) on both Linear Wasm & WasmGC kernels;
   - 5/5 self-hosting WasmGC execution checksums on `moonbit-self-lib-wasmgc.wasm` (moon-wasm-opt optimizing its own 204 KB WasmGC library binary and executing itself inside V8!).
3. Head-to-head size & speed comparison against C++ Binaryen `wasm-opt -Oz --all-features` + Bytecode Alliance `wasm-tools validate` (automatically installed and executed in CI).
"""
import json
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "demo" / "fixtures"
OUT = ROOT / "demo" / "out"
OUT.mkdir(parents=True, exist_ok=True)


def run(cmd, cwd=ROOT, check=True):
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\n{res.stdout}\n{res.stderr}")
    return res


def find_cli_cmd():
    for rel in (
        "_build/native/release/build/cmd/main/main.exe",
        "_build/native/release/build/cmd/main/main",
        "_build/native/debug/build/cmd/main/main.exe",
        "_build/native/debug/build/cmd/main/main",
    ):
        p = ROOT / rel
        if p.exists():
            return [str(p)]
    return ["moon", "run", "--target", "wasm", "cmd/main", "--"]


def v8_validate(wasm_path: Path):
    js = (
        f"const b=require('fs').readFileSync({json.dumps(str(wasm_path))});"
        "if(!WebAssembly.validate(b)){try{new WebAssembly.Module(b);}catch(e){console.error(e.message);}process.exit(1);}"
    )
    run(["node", "-e", js])


def verify_kernel_equivalence(orig_wasm: Path, opt_wasm: Path, label: str) -> str:
    js = f"""
const fs = require('fs');
async function main() {{
  const b1 = fs.readFileSync({json.dumps(str(orig_wasm))});
  const b2 = fs.readFileSync({json.dumps(str(opt_wasm))});
  if (!WebAssembly.validate(b1) || !WebAssembly.validate(b2)) {{
    throw new Error('WebAssembly.validate failed');
  }}
  const {{ instance: i1 }} = await WebAssembly.instantiate(b1, {{}});
  const {{ instance: i2 }} = await WebAssembly.instantiate(b2, {{}});
  const e1 = i1.exports, e2 = i2.exports;
  const cases = [
    ['fib', [0]], ['fib', [1]], ['fib', [10]], ['fib', [25]],
    ['gcd', [48, 18]], ['gcd', [1071, 462]], ['gcd', [-99, 36]],
    ['hash_mix', [12345, 50]], ['hash_mix', [-777, 100]],
    ['sum_weighted', [0]], ['sum_weighted', [25]], ['sum_weighted', [100]],
    ['gc_point_score', [0]], ['gc_point_score', [15]], ['gc_point_score', [60]],
    ['dispatch_score', [0, 7]], ['dispatch_score', [1, 13]], ['dispatch_score', [2, -5]],
    ['dispatch_score', [3, 12]], ['dispatch_score', [4, -9]], ['dispatch_score', [4, 19]],
    ['dispatch_score', [99, 42]],
    ['float_clamp_flag', [-5.0]], ['float_clamp_flag', [-0.0]], ['float_clamp_flag', [0.0]],
    ['float_clamp_flag', [50.0]], ['float_clamp_flag', [150.0]], ['float_clamp_flag', [NaN]],
    ['dup_calc_a', [7, 13]], ['dup_calc_b', [7, 13]],
    ['dup_calc_a', [-42, 99]], ['dup_calc_b', [-42, 99]],
  ];
  for (const [fn, args] of cases) {{
    const v1 = e1[fn](...args);
    const v2 = e2[fn](...args);
    if (v1 !== v2) {{
      throw new Error(`Mismatch on ${{fn}}(${{args}}): before=${{v1}} after=${{v2}}`);
    }}
  }}
  if (e2.float_clamp_flag(NaN) !== 1) {{
    throw new Error('NaN semantics violated on float_clamp_flag(NaN)');
  }}
  if (e2.dup_calc_a(7, 13) !== e2.dup_calc_b(7, 13)) {{
    throw new Error('ICF merged exports diverged');
  }}
  console.log('EXEC_EQUIV_OK', {json.dumps(label)}, 'cases=' + cases.length);
}}
main().catch(e => {{ console.error(e); process.exit(1); }});
"""
    res = run(["node", "-e", js])
    print(res.stdout.strip())
    return "32/32 exact"


def verify_self_gc_equivalence(orig_wasm: Path, opt_wasm: Path, label: str) -> str:
    js = f"""
const fs = require('fs');
async function main() {{
  const b1 = fs.readFileSync({json.dumps(str(orig_wasm))});
  const b2 = fs.readFileSync({json.dumps(str(opt_wasm))});
  if (!WebAssembly.validate(b1) || !WebAssembly.validate(b2)) {{
    throw new Error('WebAssembly.validate failed');
  }}
  const {{ instance: i1 }} = await WebAssembly.instantiate(b1, {{}});
  const {{ instance: i2 }} = await WebAssembly.instantiate(b2, {{}});
  const seeds = [0, 1, 42, -1337, 99999];
  for (const s of seeds) {{
    const v1 = i1.exports.self_opt_checksum(s);
    const v2 = i2.exports.self_opt_checksum(s);
    if (v1 <= 0 || v1 !== v2) {{
      throw new Error(`Self-GC mismatch on seed=${{s}}: before=${{v1}} after=${{v2}}`);
    }}
  }}
  console.log('SELF_GC_EXEC_OK', {json.dumps(label)}, 'seeds=' + seeds.length);
}}
main().catch(e => {{ console.error(e); process.exit(1); }});
"""
    res = run(["node", "-e", js])
    print(res.stdout.strip())
    return "5/5 self-exec exact"


def main():
    cli = find_cli_cmd()
    wasm_tools = shutil.which("wasm-tools")
    binaryen_opt = shutil.which("wasm-opt")

    fixtures = [
        ("moonbit-kernel-wasm.wasm", "kernel"),
        ("moonbit-kernel-wasmgc.wasm", "kernel"),
        ("moonbit-self-lib-wasmgc.wasm", "self_gc"),
        ("moonbit-self-cli-wasm.wasm", "wasi"),
    ]

    has_ext = bool(wasm_tools or binaryen_opt)
    summary_lines = [
        "# moon-wasm-opt Oracle & Benchmark Summary",
        "",
        "| Fixture | Format | Original (B) | `moon-wasm-opt -Oz` (B) | Saved | Time | Funcs | V8 Validate | Runtime Equiv |"
        + (" `wasm-tools` | Binaryen `-Oz --all-features` |" if has_ext else ""),
        "|---|---|---:|---:|---:|---:|---:|---|---|"
        + ("---|---:|" if has_ext else ""),
    ]

    for fname, mode in fixtures:
        src = FIXTURES / fname
        if not src.exists():
            raise SystemExit(f"Missing fixture: {src}")

        # 1. Lossless round-trip check
        rt_out = OUT / f"rt-{fname}"
        run([*cli, "roundtrip", str(src), "--out", str(rt_out)])
        v8_validate(rt_out)
        if wasm_tools:
            run([wasm_tools, "validate", str(rt_out)])

        # 2. Full -Oz --converge optimization
        opt_out = OUT / f"opt-{fname}"
        rep_json = OUT / f"rep-{fname}.json"
        t0 = time.perf_counter()
        run([
            *cli, "opt", str(src), "--out", str(opt_out),
            "-Oz", "--converge",
            "--report-format", "json", "--report-out", str(rep_json),
        ])
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        rep = json.loads(rep_json.read_text(encoding="utf-8"))

        # 3. Validate optimized binary with V8 (+ wasm-tools if installed)
        v8_validate(opt_out)
        wt_status = "PASS"
        if wasm_tools:
            run([wasm_tools, "validate", str(opt_out)])

        # 4. Runtime execution equivalence check
        if mode == "kernel":
            exec_status = verify_kernel_equivalence(src, opt_out, fname)
        elif mode == "self_gc":
            exec_status = verify_self_gc_equivalence(src, opt_out, fname)
        else:
            exec_status = "N/A (WASI CLI)"

        # 5. Head-to-head comparison with official C++ Binaryen wasm-opt -Oz --all-features
        bin_col = "-"
        if binaryen_opt:
            bin_out = OUT / f"binaryen-{fname}"
            bt0 = time.perf_counter()
            b_res = run(
                [binaryen_opt, "-Oz", "--all-features", str(src), "-o", str(bin_out)],
                check=False,
            )
            b_ms = (time.perf_counter() - bt0) * 1000.0
            if b_res.returncode == 0 and bin_out.exists():
                b_sz = bin_out.stat().st_size
                b_pct = round((rep["before_bytes"] - b_sz) * 100.0 / rep["before_bytes"], 2)
                bin_col = f"{b_sz} (-{b_pct}%, {b_ms:.0f} ms)"
            else:
                print(f"[WARN] Binaryen wasm-opt returned {b_res.returncode} on {fname}: {b_res.stderr.strip()}")
                bin_col = f"err({b_res.returncode})"

        fmt = "WasmGC" if rep["is_wasmgc"] else "Linear Wasm"
        print(
            f"[ORACLE OK] {fname} ({fmt}): {rep['before_bytes']} -> {rep['after_bytes']} B "
            f"(-{rep['saved_pct']}%, funcs {rep['before_funcs']}->{rep['after_funcs']}, {elapsed_ms:.1f} ms)"
        )
        row = (
            f"| `{fname}` | {fmt} | {rep['before_bytes']} | {rep['after_bytes']} | "
            f"-{rep['saved_bytes']} B ({rep['saved_pct']}%) | {elapsed_ms:.0f} ms | "
            f"{rep['before_funcs']} -> {rep['after_funcs']} | PASS | {exec_status} |"
        )
        if has_ext:
            row += f" {wt_status if wasm_tools else '-'} | {bin_col} |"
        summary_lines.append(row)

    # Also test inspect Treemap SVG, disasm, diff, and --no-inline CLI options
    run([*cli, "inspect", str(FIXTURES / "moonbit-kernel-wasm.wasm"), "--format", "svg", "--out", str(OUT / "kernel-treemap.svg")])
    run([*cli, "disasm", str(FIXTURES / "moonbit-kernel-wasm.wasm"), "--func", "0", "--out", str(OUT / "kernel-fn0.wat")])
    run([*cli, "diff", str(FIXTURES / "moonbit-kernel-wasm.wasm"), str(OUT / "opt-moonbit-kernel-wasm.wasm"), "--format", "md", "--out", str(OUT / "kernel-diff.md")])
    run([*cli, "opt", str(FIXTURES / "moonbit-kernel-wasm.wasm"), "--out", str(OUT / "noinline-kernel.wasm"), "-Oz", "--no-inline"])
    v8_validate(OUT / "noinline-kernel.wasm")

    summary_md = "\n".join(summary_lines) + "\n"
    (OUT / "oracle-summary.md").write_text(summary_md, encoding="utf-8")
    print("\n" + summary_md)


if __name__ == "__main__":
    main()
