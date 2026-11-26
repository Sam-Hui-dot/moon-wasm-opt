# moon-wasm-opt

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-047857?style=for-the-badge)](https://sam-hui-dot.github.io/moon-wasm-opt/)
[![CI](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--wasm--opt%400.2.0-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-wasm-opt%400.2.0)

纯 MoonBit 实现的 **WebAssembly 2.0 与 WasmGC 二进制优化器、WAT 反汇编器、体积 Treemap 剖析器与零上传浏览器在线优化工作台**（零 C++ Binaryen 依赖）。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-wasm-opt`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器工作台**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-wasm-opt/)）三形态交付。能够直接解析、优化并重编码真实 MoonBit 1.0 `--release` Linear Wasm 与 WasmGC 产物，并通过 **Node.js v24 V8 `WebAssembly.validate()` + Bytecode Alliance `wasm-tools validate` + 优化前后运行时 0 误差执行对拍**。

## 核心能力（`0.2.0`）

- **完整的 Wasm 2.0 + WasmGC 无损二进制编解码器**（`types.mbt`, `leb128.mbt`, `decoder.mbt`, `encoder.mbt`）
  - 覆盖全部 13 个标准段（含 WasmGC `rec` / `sub` / `sub final` / `struct` / `array` / `func` 复合类型、`Tag`、`DataCount`、全部 8 种 `Element` 与 3 种 `Data` 段形态）与自定义段（含 `name` 符号表解析与同步重编码）；
  - 覆盖核心控制流、变量、表、内存、数值、引用、`0xFC` bulk-memory / 饱和转换、`0xFB` WasmGC（`struct.*` / `array.*` / `ref.test` / `ref.cast` / `br_on_cast` / `i31`）、`try_table` 异常处理与 `0xFD` SIMD 指令。
- **10 个编译优化 Pass 与不动点收敛管线（`-O1` / `-O2` / `-Os` / `-Oz --converge`）**
  1. `strip-custom`：按需剥离非执行自定义段（支持 `--keep-names` 保留并同步符号名）；
  2. `const-globals`：模块内不可变标量/静态引用全局常量传播（带体积盈利守卫，显式禁止传播 WasmGC 堆构造初值以保持 `ref.eq` 语义）；
  3. `const-fold + peephole`：`i32`/`i64` 常量折叠、代数恒等化简、整数比较取反折叠（排除 `f32`/`f64` 保护 IEEE-754 `NaN` 语义）、`local.set + local.get -> local.tee` 融合、纯表达式 `drop` 消除、常量 `br_if`/`br_table`/`if`/`select` 剪枝及 WasmGC 冗余 `ref.as_non_null` 消除；
  4. `simplify-cfg`：`i32.eqz + if` 条件反转、`if -> br_if` 规约、提前终止分支的 `else` 展平、`br_table` 尾部默认项裁剪与冗余嵌套空 `block` 合并；
  5. `dce-instr`：消除 `nop`、`unreachable`/`return`/`br` 后的不可达死代码以及无分支目标的冗余 `block`/`loop`；
  6. `local-opt`：移除未使用局部变量声明、按引用频次优先分配 1 字节 LEB128 槽位并按类型合并 `LocalGroup`；
  7. `module-dce`：从 `export` / `start` / `element` 根集出发做全模块调用图可达性垃圾回收，安全清理不可达函数、不可达全局变量与未引用 `RecGroup` 类型组并全模块重映射索引；
  8. `merge-funcs (ICF)`：面向泛型单态化重复代码，基于规范化自调用指令体做精确同构函数合并并多轮收敛重定向全部调用点与表项；
  9. `inline`：尺寸感知的单调用点内部函数与零开销短包装函数内联（在 ICF 后执行避免拆散同构合并，内置精确字节盈利门禁、循环内局部零初始化保护、`return`/`br 0` 块展开与互递归安全检测，支持 `--no-inline`）；
  10. `opt-data`：主动 Data 段前导/尾随零裁剪与长零洞拆分（严格保护被动段、导入内存、重叠覆盖写入与越界 Trap 语义）。
- **体积剖析、WAT 反汇编与零上传浏览器工作台**
  - 按段与函数输出精确字节账单、原生 SVG 体积 Treemap 与 10-Pass 减重瀑布图；
  - 函数级可读 WAT 反汇编（自动关联 `name` 段符号名）与优化前后左右对照；
  - 浏览器端零上传执行，内嵌实时原生 `WebAssembly.validate()` 验签与优化产物一键下载。

## 实测验证结果（真实 MoonBit 1.0 `--release` 产物）

以下为 4 个真实 MoonBit 1.0 `--release` 产物的本地与 CI 实测结果（全部 100% 通过 Node.js v24 V8 `WebAssembly.validate()` 与 Bytecode Alliance `wasm-tools validate`）：

| 真实夹具 | 格式 | 原始体积 | `moon-wasm-opt -Oz` | 纯字节码减重 | 函数数变化 | V8 + `wasm-tools` | 运行时对拍 |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `moonbit-self-cli-wasm.wasm`（自身 CLI `--release`） | Linear Wasm | 419,023 B | **363,945 B** | **-55,078 B (-13.14%)** | 1,446 → 976 | PASS | WASI CLI |
| `moonbit-self-lib-wasmgc.wasm`（自身库 `--release` WasmGC 自举） | WasmGC | 204,727 B | **189,922 B** | **-14,805 B (-7.23%)** | 857 → 671 | PASS | **5/5 self-exec exact** |
| `moonbit-kernel-wasm.wasm` | Linear Wasm | 10,285 B | **9,728 B** | **-557 B (-5.42%)** | 94 → 64 | PASS | **32/32 exact (含 NaN)** |
| `moonbit-kernel-wasmgc.wasm` | WasmGC | 5,988 B | **5,651 B** | **-337 B (-5.63%)** | 60 → 43 | PASS | **32/32 exact (含 NaN)** |

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-wasm-opt@0.2.0
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
# 执行 10-Pass -Oz --converge 优化并输出逐 Pass 减重报告
moon run --target native cmd/main -- opt demo/fixtures/moonbit-self-cli-wasm.wasm --out demo/out/self.opt.wasm -Oz --converge

# 可选关闭函数内联
moon run --target native cmd/main -- opt demo/fixtures/moonbit-kernel-wasm.wasm --out demo/out/kernel.opt.wasm -Oz --no-inline

# 查看模块体积账单或导出原生 SVG 体积 Treemap
moon run --target native cmd/main -- inspect demo/fixtures/moonbit-self-lib-wasmgc.wasm --format svg --out demo/out/treemap.svg

# 反汇编指定函数为可读 WAT
moon run --target native cmd/main -- disasm demo/fixtures/moonbit-kernel-wasm.wasm --func fib

# 对比两个 .wasm 的体积与函数变化
moon run --target native cmd/main -- diff demo/fixtures/moonbit-kernel-wasm.wasm demo/out/opt-moonbit-kernel-wasm.wasm --format md
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

# 跑通 V8 WebAssembly.validate()、32/32 内核对拍与 5/5 WasmGC 自举执行对拍
python demo/verify_oracle.py
```
