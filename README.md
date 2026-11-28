# moon-wasm-opt

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-047857?style=for-the-badge)](https://sam-hui-dot.github.io/moon-wasm-opt/)
[![CI](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--wasm--opt%400.5.1-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-wasm-opt%400.5.1)

纯 MoonBit 实现的 **WebAssembly 2.0 与 WasmGC 二进制优化器、WAT 反汇编器、体积 Treemap 剖析器与零上传浏览器在线优化工作台**（零 C++ Binaryen 依赖）。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-wasm-opt`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器工作台**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-wasm-opt/)）三形态交付。能够直接解析、优化并重编码真实 MoonBit 1.0 `--release` Linear Wasm 与 WasmGC 产物，并通过 **Node.js v24 V8 `WebAssembly.validate()` + Bytecode Alliance `wasm-tools validate` + 自动扫描官方 `WebAssembly/spec/test/core` & GC 回归测试（109 套 / 1,131 模块 / 16,970 条 `assert_return` 0 偏差等价）**。

## 与工具链内置 `~/.moon/bin/moon-wasm-opt` 的定位区分

MoonBit 官方工具链自带一个约 10 MB 的本地 C++ Binaryen 二进制（`~/.moon/bin/moon-wasm-opt`），用于本地构建链路的离线后处理。本仓库 `Sam-Hui-dot/moon-wasm-opt` 的定位与之互补，核心差异在于：

- **可编程纯 MoonBit 核心库（全目标）**：可直接 `moon add` 编译进 `wasm` / `wasm-gc` / `js` / `native` 业务程序、边缘 Worker、IDE 扩展或前端工具链，无需子进程调用本机 C++ 二进制；
- **内置可观测性与零上传工作台**：同一份纯 MoonBit 引擎提供二进制体积账单、SVG Treemap、17-Pass 减重瀑布图、符号化 WAT 反汇编与浏览器端零上传实时 `WebAssembly.validate()`；
- **执行速度与诚实边界**：`0.4.0` 通过位集合 `LocalBitSet` 活跃分析与脏标记按函数增量编码，在 GitHub Actions Ubuntu CI 上 4 份真实 MoonBit `--release` 产物耗时全面快于 Binaryen `v133`；剩余压缩率差距与演进路线详见 [docs/known-gaps.md](docs/known-gaps.md)。

## 核心能力（`0.5.0`）

- **完整的 Wasm 2.0 + WasmGC 无损二进制编解码器**（`types.mbt`, `leb128.mbt`, `decoder.mbt`, `encoder.mbt`）
  - 覆盖全部 13 个标准段（含 WasmGC `rec` / `sub` / `sub final` / `struct` / `array` / `func` 复合类型、`Tag`、`DataCount`、全部 8 种 `Element` 与 3 种 `Data` 段形态）与自定义段（含 `name` 符号表解析与同步重编码）；
  - 覆盖核心控制流、变量、表、内存、数值、引用、`0xFC` bulk-memory / 饱和转换、`0xFB` WasmGC（`struct.*` / `array.*` / `ref.test` / `ref.cast` / `br_on_cast` / `i31`）、`try_table` 异常处理与 `0xFD` SIMD 指令。
- **20 个编译优化 Pass 与脏标记增量收敛管线（`-O1` / `-O2` / `-Os` / `-Oz --converge`）**
  - **`0.5.0` 新增三大优化 Pass**：
    - `wasmgc-gufa`（`opt_wasmgc_gufa.mbt`）：全程序 WasmGC 结构体写后不读尾部字段裁剪与只读可变字段 `mut -> imm` 收紧；
    - `local-cse`（`opt_cse.mbt`）：基本块内零新增局部变量的 2/3 指令纯表达式公共子表达式复用与内存/字段读转发；
    - `cfg-merge`（`opt_cfg_merge.mbt`）：无分支 `block`/`loop` 拆壳、尾部冗余 `br 0` 消除、同型嵌套块合并与同构 `if/else` 折叠。
  - **高性能管线底座**：`LocalBitSet` 稠密位矩阵活跃分析与干涉图、按函数脏标记跳过空转 Pass、按变更函数增量计量字节并在收敛结束时仅执行 1 次全模块编码；
  1. `strip-custom`：按需剥离非执行自定义段（支持 `--keep-names` 保留并同步符号名）；
  2. `dedup-types`：严格遵循 WasmGC Iso-Recursive 类型等价规范的同构 `RecGroup` 去重与单元素 `rec` 包装清理；
  3. `const-globals`：模块内不可变标量/静态引用全局常量传播（显式禁止传播 WasmGC 堆构造初值以保持 `ref.eq` 语义）；
  4. `write-only-globals`（`0.4.0` 新增）：识别未导出且全模块零读取的可变全局变量，将 `global.set` 降级为 `drop` 并交由后续 `peephole` 与 `module-dce` 彻底清理；
  5. `dae`：严格内部函数的统一常量实参传播与尾死参数裁剪（支持 `--no-dae`）；
  6. `const-fold + peephole`：`i32`/`i64` 常量折叠、代数恒等化简、整数比较取反折叠（排除 `f32`/`f64` 保护 IEEE-754 `NaN` 语义）、`local.set + local.get -> local.tee` 融合、纯表达式（含 `v128.const`）`drop` 消除及常量控制流剪枝；
  7. `simd-opt`（`0.4.0` 新增）：Wasm SIMD `0xFD` 常量折叠与恒等化简（`v128.not`/`and`/`andnot`/`or`/`xor`、`i32x4`/`i64x2` `splat`/`extract_lane`/`add`/`sub`、恒等 `i8x16.shuffle` 消除）；
  8. `wasmgc-opt`：WasmGC 验证器安全的静态冗余 `ref.cast`/`ref.cast_null`/`ref.as_non_null` 消除、`ref.func + call_ref -> call` 去虚化、`ref.is_null`/`ref.test` 与 `i31` 常量折叠；
  9. `simplify-cfg`：`i32.eqz + if` 条件反转、`if -> br_if` 规约、提前终止分支的 `else` 展平、`br_table` 尾部默认项裁剪与冗余嵌套空 `block` 合并；
  10. `code-folding`（`0.4.0` 新增）：纯条件 `If -> Select` 规约、布尔结果折叠、空类型 `If` 公共尾 `local.set`/`global.set` 提拉及单值 `If` 公共安全一元/常量二元尾算术提拉；
  11. `dce-instr`：消除 `nop`、`unreachable`/`return`/`br` 后的不可达死代码以及无分支目标的冗余 `block`/`loop`；
  12. `local-dse`：基于 `LocalBitSet` 的精确结构化后向活跃分析（含 `loop` 不动点与 `try_table` 异常路径保活）、死存储消除与直行基本块复制传播；
  13. `coalesce-locals`：稠密位矩阵干涉图 + 复制亲和贪心图着色局部槽位合并（保护入口活跃零初始化局部、安全复用死亡参数槽位，支持 `--no-coalesce`）；
  14. `local-opt`：移除未使用局部变量声明、按引用频次优先分配 1 字节 LEB128 槽位并按类型合并 `LocalGroup`；
  15. `module-dce`：从 `export` / `start` / `element` 根集出发做全模块调用图可达性垃圾回收，安全清理不可达函数、全局变量与未引用 `RecGroup`；
  16. `merge-funcs (ICF)`：基于规范化自调用指令体做精确同构函数合并并多轮收敛重定向全部调用点与表项；
  17. `inline` + `opt-data`：精确字节成本门禁函数内联（支持 `--no-inline`）及主动 Data 段前导/尾随零裁剪与长零洞拆分。

## 实测验证结果

### 1. 真实 MoonBit 1.0 `--release` 产物横向对比（GitHub Actions Ubuntu CI，vs C++ Binaryen `v133`）

全部 4 份产物均 100% 通过 Node.js v24 V8 `WebAssembly.validate()` 与 Bytecode Alliance `wasm-tools 1.227.1 validate`（数据取自 CI Run `#45866500394`）：

| 真实夹具 | 格式 | 原始体积 | `moon-wasm-opt@0.4.0 -Oz` | `0.4.0` CI 耗时 | Binaryen `v133 -Oz`（同机同测） | 相对 Binaryen 速度 | 函数变化 | V8 + `wasm-tools` | 运行时对拍 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| `moonbit-self-cli-wasm.wasm`（自身 CLI） | Linear Wasm | 419,023 B | **328,161 B (-21.68%)** | **589 ms** | 286,276 B (-31.68%, 878 ms) | **1.49x faster** | 1,446→913 | PASS / PASS | WASI CLI |
| `moonbit-self-lib-wasmgc.wasm`（自身库 WasmGC） | WasmGC | 204,727 B | **167,671 B (-18.10%)** | **437 ms** | 150,180 B (-26.64%, 627 ms) | **1.43x faster** | 857→600 | PASS / PASS | **5/5 self-exec exact** |
| `moonbit-kernel-wasm.wasm` | Linear Wasm | 10,285 B | **8,339 B (-18.92%)** | **15 ms** | 6,928 B (-32.64%, 51 ms) | **3.40x faster** | 94→64 | PASS / PASS | **32/32 exact (含 NaN)** |
| `moonbit-kernel-wasmgc.wasm` | WasmGC | 5,988 B | **4,891 B (-18.32%)** | **7 ms** | 4,207 B (-29.74%, 32 ms) | **4.57x faster** | 60→43 | PASS / PASS | **32/32 exact (含 NaN)** |

> 相比 `0.3.0`（`1,313 ms` / `1,183 ms`），`0.4.0` 大模块优化耗时分别降至 `589 ms` / `437 ms`（提速 `2.2x–2.7x`），全部 4 份真实夹具均快于 C++ Binaryen `v133`。关于剩余压缩率差距的技术原因（如表达式级 CSE、WasmGC 字段裁剪等）与后续版本规划，请见 [docs/known-gaps.md](docs/known-gaps.md)。

### 2. 官方 `WebAssembly/spec/test/core` + GC 自动发现全量规范回归（CI 实测）

CI 自动拉取官方 `WebAssembly/spec` 仓库并扫描 `test/core/*.wast` 与 `test/core/gc/*.wast`（[demo/verify_spec.py](demo/verify_spec.py)）：

- **官方 `.wast` 套件覆盖**：自动发现 **`114` 套** -> **`109` 套通过**，`5` 套跳过（`core/align.wast`、`gc/type-subtyping.wast` 因 `wasm-tools 1.227.1 json-from-wast` 语法不支持跳过；`core/annotations.wast`、`core/comments.wast`、`core/utf8-invalid-encoding.wast` 为畸形/非标准二进制编码测试跳过）；
- **规范 `.wasm` 模块双重验签**（`roundtrip` + 17-Pass `-Oz --converge`，`wasm-tools validate` + V8 `WebAssembly.validate()`）：**`1,131 / 1,131` PASS（0 错误）**；
- **V8 `assert_return` 优化前后运行时等价性对拍**：**`16,970 / 16,970` 精确一致（0 偏差）**；
- **1,131 个官方规范模块总体积**：`200,019 B -> 161,615 B`（**-38,404 B / -19.20%**）。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-wasm-opt@0.4.0
```

```moonbit
let (opt_bytes, report) = @moon-wasm-opt.optimize_bytes(
  raw_wasm_bytes,
  config=@moon-wasm-opt.opt_config(level=Oz, converge=true),
)
let treemap_svg = @moon-wasm-opt.render_treemap_svg(@moon-wasm-opt.analyze_module(opt_bytes))
let waterfall_svg = @moon-wasm-opt.render_opt_waterfall_svg(report)
```

### 2. CLI 命令

```powershell
# 执行 17-Pass -Oz --converge 优化并输出逐 Pass 减重报告
moon run --target native cmd/main -- opt demo/fixtures/moonbit-self-cli-wasm.wasm --out demo/out/self.opt.wasm -Oz --converge

# 可选诊断开关：关闭内联、图着色局部合并或死参数裁剪
moon run --target native cmd/main -- opt demo/fixtures/moonbit-kernel-wasm.wasm --out demo/out/kernel.opt.wasm -Oz --no-inline --no-coalesce --no-dae

# 查看模块体积账单或导出原生 SVG 体积 Treemap
moon run --target native cmd/main -- inspect demo/fixtures/moonbit-self-lib-wasmgc.wasm --format svg --out demo/out/treemap.svg

# 反汇编指定函数为可读 WAT
moon run --target native cmd/main -- disasm demo/fixtures/moonbit-kernel-wasm.wasm --func fib

# 对比两个 .wasm 的体积与函数变化
moon run --target native cmd/main -- diff demo/fixtures/moonbit-kernel-wasm.wasm demo/out/opt-moonbit-kernel-wasm.wasm --format md
```

### 3. 本地测试与对拍

```powershell
# 四目标单元测试（18 项含 256 组畸形二进制模糊测试与 0.4.0 新 Pass 测试）
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 构建零上传浏览器工作台并跑 V8 冒烟
python demo/build_web.py

# 跑通 V8 WebAssembly.validate()、32/32 内核对拍与 5/5 WasmGC 自举执行对拍
python demo/verify_oracle.py

# 如本机已安装 wasm-tools，可运行官方 WebAssembly/spec 全量自动发现回归
python demo/verify_spec.py --spec-dir /path/to/WebAssembly/spec
```
