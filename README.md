# moon-wasm-opt

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-047857?style=for-the-badge)](https://sam-hui-dot.github.io/moon-wasm-opt/)
[![CI](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--wasm--opt%400.1.0-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-wasm-opt%400.1.0)

纯 MoonBit 实现的 **WebAssembly 2.0 与 WasmGC 二进制优化器、WAT 反汇编器、体积 Treemap 剖析器与零上传浏览器在线优化工作台**（零 C++ Binaryen 依赖）。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-wasm-opt`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器工作台**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-wasm-opt/)）三形态交付。能够直接解析、优化并重编码真实 MoonBit 1.0 编译输出的 Linear Wasm 与 WasmGC 产物，并通过 V8 `WebAssembly.validate()` 及优化前后运行时执行 0 误差对拍验证。

## 核心能力（`0.1.0`）

- **完整的 Wasm 2.0 + WasmGC 无损二进制编解码器**（`types.mbt`, `leb128.mbt`, `decoder.mbt`, `encoder.mbt`）
  - 覆盖全部 13 个标准段（含 WasmGC `rec` / `sub` / `sub final` / `struct` / `array` / `func` 复合类型、`Tag`、`DataCount`、全部 8 种 `Element` 与 3 种 `Data` 段形态）与自定义段（含 `name` 符号表解析与同步重编码）；
  - 覆盖核心控制流、变量、表、内存、数值、引用、`0xFC` bulk-memory / 饱和转换、`0xFB` WasmGC（`struct.*` / `array.*` / `ref.test` / `ref.cast` / `br_on_cast` / `i31`）、`try_table` 异常处理与 `0xFD` SIMD 指令。
- **6 个真实编译优化 Pass 与不动点收敛管线（`-O1` / `-O2` / `-Os` / `-Oz --converge`）**
  1. `strip-custom`：按需剥离非执行自定义段（支持 `--keep-names` 保留并同步符号名）；
  2. `const-fold + peephole`：`i32`/`i64` 常量折叠、代数恒等化简（`+0`、`*1`、`& -1`、`== 0 -> eqz`）、`local.set + local.get -> local.tee` 融合、纯表达式 `drop` 消除、常量 `br_if`/`if`/`select` 剪枝及 WasmGC 冗余 `ref.as_non_null` 消除；
  3. `dce-instr`：消除 `nop`、`unreachable`/`return`/`br` 后的不可达死代码以及无分支目标的冗余 `block`/`loop`；
  4. `local-opt`：移除未使用局部变量声明、按引用频次优先分配 1 字节 LEB128 槽位并按类型合并 `LocalGroup`；
  5. `module-dce`：从 `export` / `start` / `element` 根集出发做全模块调用图可达性垃圾回收，安全清理不可达函数、不可达全局变量与未引用 `RecGroup` 类型组并全模块重映射索引；
  6. `merge-funcs (ICF)`：面向泛型单态化重复代码，基于规范化自调用指令体做精确同构函数合并并多轮收敛重定向全部调用点与表项。
- **体积剖析、WAT 反汇编与零上传浏览器工作台**
  - 按段与函数输出精确字节账单、原生 SVG 体积 Treemap 与 Pass 减重瀑布图；
  - 函数级可读 WAT 反汇编（自动关联 `name` 段符号名）与优化前后左右对照；
  - 浏览器端零上传执行，内嵌实时原生 `WebAssembly.validate()` 验签与优化产物一键下载。

## 实测验证结果（真实 MoonBit 1.0 `--release` 产物）

以下为本地与 CI 在真实 MoonBit `--release` 编译产物上的实测数据（全部 100% 通过 Node.js v24 V8 `WebAssembly.validate()`，其中带导出函数的 Linear Wasm 与 WasmGC 内核均通过 **19/19 组导出函数调用优化前后 0 误差执行对拍**）：

| 真实夹具 | 格式 | 原始体积 | `moon-wasm-opt -Oz --converge` | 纯字节码减重 | 函数数变化 | V8 校验 | 运行时对拍 |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `moonbit-self-cli-wasm.wasm`（自身 CLI `--release` 自举优化） | Linear Wasm | 383,414 B | **339,656 B** | **-43,758 B (-11.41%)** | 1,352 → 1,190 | PASS | WASI CLI |
| `moonbit-kernel-wasm.wasm` | Linear Wasm | 9,860 B | **9,427 B** | **-433 B (-4.39%)** | 90 → 86 | PASS | **19/19 exact** |
| `moonbit-kernel-wasmgc.wasm` | WasmGC | 5,616 B | **5,361 B** | **-255 B (-4.54%)** | 55 → 53 | PASS | **19/19 exact** |

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-wasm-opt@0.1.0
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
# 执行 -Oz --converge 优化并输出逐 Pass 减重报告
moon run --target native cmd/main -- opt demo/fixtures/moonbit-self-cli-wasm.wasm --out demo/out/self.opt.wasm -Oz --converge

# 查看模块体积账单或导出原生 SVG 体积 Treemap
moon run --target native cmd/main -- inspect demo/fixtures/moonbit-kernel-wasm.wasm --format svg --out demo/out/treemap.svg

# 反汇编指定函数为可读 WAT
moon run --target native cmd/main -- disasm demo/fixtures/moonbit-kernel-wasm.wasm --func fib

# 对比两个 .wasm 的体积与函数变化
moon run --target native cmd/main -- diff demo/fixtures/moonbit-kernel-wasm.wasm demo/out/opt-kernel.wasm --format md
```

### 3. 本地测试与对拍

```powershell
# 四目标单元测试与 256 组畸形二进制模糊测试
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 构建零上传浏览器工作台并跑 V8 冒烟
python demo/build_web.py

# 跑通 V8 WebAssembly.validate() 与 Linear Wasm / WasmGC 运行时执行等价性对拍
python demo/verify_oracle.py
```
