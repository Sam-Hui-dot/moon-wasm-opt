import base64
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
FIXTURES = ROOT / "demo" / "fixtures"


def main() -> None:
    cmd = ["moon", "build", "--target", "js", "--release", "--deny-warn", "web"]
    print("Running:", " ".join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)

    built_js = ROOT / "_build" / "js" / "release" / "build" / "web" / "web.js"
    if not built_js.exists():
        raise FileNotFoundError(f"Expected JS build artifact not found: {built_js}")

    DOCS.mkdir(parents=True, exist_ok=True)
    target_js = DOCS / "moon-wasm-opt.js"
    shutil.copy2(built_js, target_js)
    print(f"Copied {built_js} -> {target_js} ({target_js.stat().st_size} bytes)")

    sample_map = {
        "kernel_wasm": "moonbit-kernel-wasm.wasm",
        "kernel_wasmgc": "moonbit-kernel-wasmgc.wasm",
        "self_cli_wasm": "moonbit-self-cli-wasm.wasm",
    }
    encoded = {}
    for key, fname in sample_map.items():
        path = FIXTURES / fname
        encoded[key] = base64.b64encode(path.read_bytes()).decode("ascii")

    samples_js = DOCS / "samples.js"
    samples_js.write_text(
        "globalThis.MOON_WASM_OPT_SAMPLES = " + json.dumps(encoded) + ";\n",
        encoding="utf-8",
    )
    print(f"Wrote {samples_js} ({samples_js.stat().st_size} bytes)")

    smoke = (
        "require('./docs/moon-wasm-opt.js');\n"
        "require('./docs/samples.js');\n"
        "const S = globalThis.MOON_WASM_OPT_SAMPLES;\n"
        "const M = globalThis.MoonWasmOpt;\n"
        "for (const [k, b64] of Object.entries(S)) {\n"
        "  const res = M.optimizeWasm(b64, { preset: 'Oz', converge: true });\n"
        "  if (!res.ok) throw new Error('optimize failed for ' + k + ': ' + res.error);\n"
        "  const bytes = Buffer.from(res.optimized_b64, 'base64');\n"
        "  if (!WebAssembly.validate(bytes)) throw new Error('WebAssembly.validate failed for ' + k);\n"
        "  if (res.report.saved_bytes <= 0) throw new Error('expected positive savings for ' + k);\n"
        "  console.log('WEB_SMOKE_OK', k, res.report.before_bytes, '->', res.report.after_bytes, 'saved=' + res.report.saved_pct + '%', 'funcs=' + res.report.before_funcs + '->' + res.report.after_funcs);\n"
        "}\n"
    )
    subprocess.run(["node", "-e", smoke], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
