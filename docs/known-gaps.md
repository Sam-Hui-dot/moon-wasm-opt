# Known Scope & Remaining Gaps vs C++ Binaryen

`moon-wasm-opt@0.4.0` is a pure-MoonBit WebAssembly 2.0 + WasmGC optimizer verified across V8, Bytecode Alliance `wasm-tools`, and the official `WebAssembly/spec` suite. To make evaluation transparent for downstream users and hackathon reviewers, this document tracks where `moon-wasm-opt` currently excels and where C++ Binaryen `v133` still compresses further.

## Relationship to Bundled `~/.moon/bin/moon-wasm-opt`

The official MoonBit toolchain ships an ~10 MB C++ Binaryen executable named `moon-wasm-opt` inside `~/.moon/bin/`. `Sam-Hui-dot/moon-wasm-opt` is **not** a wrapper around that C++ binary:
- **Zero C/C++ dependency**: 100% pure MoonBit source, importable directly as a library across `wasm`, `wasm-gc`, `js`, and `native`;
- **Runs in-browser without uploads**: Powers the zero-upload GitHub Pages workbench ([live demo](https://sam-hui-dot.github.io/moon-wasm-opt/)) via compiled JS/Wasm;
- **Structured telemetry**: Emits JSON / Markdown reports, readable WAT disassembly, module size Treemaps, and pass-by-pass SVG waterfalls natively.

## Current Compression Gap Analysis (~17–21% vs Binaryen ~27–33%)

On MoonBit 1.0 `--release` binaries, `moon-wasm-opt@0.4.0` achieves ~60–72% of Binaryen `v133`'s total byte reduction while running faster end-to-end on real binaries. The remaining size delta comes from:

1. **Struct/Array Field Scalarization & Type Pruning (`SignaturePruning` / `TypeRefining` / `GUFA`)**:
   Binaryen tracks whole-program field reads/writes across WasmGC heap types (`struct.get`/`struct.set`) and prunes write-only struct fields or tightens nullable struct references globally.
2. **Expression-Level GVN / CSE (`LocalCSE` / `SimplifyLocals` sink-and-rematerialize)**:
   `moon-wasm-opt` currently performs intra-block local alias propagation (`prop_copies_seq`) and `local.set + local.get -> local.tee` fusion, but does not yet extract repeated multi-instruction subexpressions across blocks into shared locals or sink pure single-use computations into deeper blocks.
3. **Cold Code Outlining & Multi-Value Control-Flow Re-structuring (`Outlining` / `MergeBlocks`)**:
   Binaryen identifies repeated multi-instruction sequences inside unrelated functions and outlines them into shared helper functions, and performs global multi-value block reshaping across `br_table` / `try_table`.
4. **Full Constant-Expression Global Evaluation**:
   `pass_const_globals` folds immutable scalar and static ref globals (`I32Const`, `I64Const`, `F32Const`, `F64Const`, `RefNull`, `RefFunc`) and deliberately avoids replicating WasmGC heap allocations (`struct.new` / `array.new`) to preserve `ref.eq` object identity.

## Roadmap (`0.5.0`+)

- `0.5.0`: WasmGC field liveness pruning (eliminating unread struct fields), intra-block expression CSE, and pure single-use local sinking.
- `0.6.0`: Cold instruction sequence outlining and `moon prove` formal proofs over core leb128/control-flow validator invariants.
