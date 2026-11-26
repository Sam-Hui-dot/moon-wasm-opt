# moon-wasm-opt

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-047857?style=for-the-badge)](https://sam-hui-dot.github.io/moon-wasm-opt/)
[![CI](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-wasm-opt/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--wasm--opt%400.3.0-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-wasm-opt%400.3.0)

纯 MoonBit 实现的 **WebAssembly 2.0 与 WasmGC 二进制优化器、WAT 反汇编器、体积 Treemap 剖析器与零上传浏览器在线优化工作台**（零 C++ Binaryen 依赖）。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-wasm-opt`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器工作台**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-wasm-opt/)）三形态交付。能够直接解析、优化并重编码真实 MoonBit 1.0 `--release` Linear Wasm 与 WasmGC 产物，并通过 **Node.js v24 V8 `WebAssembly.validate()` + Bytecode Alliance `wasm-tools validate` + 官方 `WebAssembly/spec/test/core` & GC 回归测试（256/256 模块、12,970/12,970 `assert_return` 0 误差等价）**。

## 核心能力（`0.3.0`）

- **完整的 Wasm 2.0 + WasmGC 无损二进制编解码器**（`types.mbt`, `leb128.mbt`, `decoder.mbt`, `encoder.mbt`）
  - 覆盖全部 13 个标准段（含 WasmGC `rec` / `sub` / `sub final` / `struct` / `array` / `func` 复合类型、`Tag`、`DataCount`、全部 8 种 `Element` 与 3 种 `Data` 段形态）与自定义段（含 `name` 符号表解析与同步重编码）；
  - 覆盖核心控制流、变量、表、内存、数值、引用、`0xFC` bulk-memory / 饱和转换、`0xFB` WasmGC（`struct.*` / `array.*` / `ref.test` / `ref.cast` / `br_on_cast` / `i31`）、`try_table` 异常处理与 `0xFD` SIMD 指令。
- **14 个编译优化 Pass 与不动点收敛管线（`-O1` / `-O2` / `-Os` / `-Oz --converge`）**
  1. `strip-custom`：按需剥离非执行自定义段（支持 `--keep-names` 保留并同步符号名）；
  2. `dedup-types`：严格遵循 WasmGC Iso-Recursive 类型等价规范的同构 `RecGroup` 去重与单元素 `rec` 包装清理，并解锁更多 ICF 同构函数合并；
  3. `const-globals`：模块内不可变标量/静态引用全局常量传播（带体积守卫，显式禁止传播 WasmGC 堆构造初值以保持 `ref.eq` 语义）；
  4. `dae`：严格内部函数的统一常量实参传播与尾死参数裁剪（自动同步调用点 `drop` 与局部索引重排，支持 `--no-dae`）；
  5. `const-fold + peephole`：`i32`/`i64` 常量折叠、代数恒等化简、整数比较取反折叠（排除 `f32`/`f64` 保护 IEEE-754 `NaN` 语义）、`local.set + local.get -> local.tee` 融合、纯表达式 `drop` 消除、常量 `br_if`/`br_table`/`if`/`select` 剪枝及 WasmGC 冗余 `ref.as_non_null` 消除；
  6. `wasmgc-opt`：WasmGC 验证器安全的静态冗余 `ref.cast`/`ref.cast_null`/`ref.as_non_null` 消除、`ref.func + call_ref -> call` 去虚化、`ref.is_null`/`ref.test` 常量折叠及 `i31` 往返常量折叠；
  7. `simplify-cfg`：`i32.eqz + if` 条件反转、`if -> br_if` 规约、提前终止分支的 `else` 展平、`br_table` 尾部默认项裁剪与冗余嵌套空 `block` 合并；
  8. `dce-instr`：消除 `nop`、`unreachable`/`return`/`br` 后的不可达死代码以及无分支目标的冗余 `block`/`loop`；
  9. `local-dse`：精确结构化后向活跃分析（含 `loop` 不动点与 `try_table` 异常路径保活）、死存储消除（`local.set -> drop`、死 `local.tee` 删除）与直行基本块局部复制/小常量传播；
  10. `coalesce-locals`：干涉图构建 + 复制亲和贪心图着色局部槽位合并（保护入口活跃零初始化局部、安全复用死亡参数槽位，支持 `--no-coalesce`）；
  11. `local-opt`：移除未使用局部变量声明、按引用频次优先分配 1 字节 LEB128 槽位并按类型合并 `LocalGroup`；
  12. `module-dce`：从 `export` / `start` / `element` 根集出发做全模块调用图可达性垃圾回收，安全清理不可达函数、不可达全局变量与未引用 `RecGroup` 类型组并全模块重映射索引；
  13. `merge-funcs (ICF)`：面向泛型单态化重复代码，基于规范化自调用指令体做精确同构函数合并并多轮收敛重定向全部调用点与表项；
  14. `inline` + `opt-data`：在 ICF 之后运行的精确字节成本门禁函数内联（循环深度零初始化保护、`return`/`br 0` 块展开与互递归防护，支持 `--no-inline`）及主动 Data 段前导/尾随零裁剪与长零洞拆分。
- **体积剖析、WAT 反汇编与零上传浏览器工作台**
  - 按段与函数输出精确字节账单、原生 SVG 体积 Treemap 与 14-Pass 减重瀑布图；
  - 函数级可读 WAT 反汇编（自动关联 `name` 段符号名）与优化前后左右对照；
  - 浏览器端零上传执行，内嵌实时原生 `WebAssembly.validate()` 验签与优化产物一键下载。

## 实测验证结果

### 1. 真实 MoonBit 1.0 `--release` 产物横向对比（GitHub Actions Ubuntu CI，vs C++ Binaryen `v133`）

全部 4 份产物均 100% 通过 Node.js v24 V8 `WebAssembly.validate()` 与 Bytecode Alliance `wasm-tools 1.227.1 validate`：

| 真实夹具 | 格式 | 原始体积 | `moon-wasm-opt@0.3.0 -Oz` | 较 `0.2.0` 演进 | CI 耗时 | 函数 / 类型变化 | Binaryen `v133 -Oz`（参考） | V8 + `wasm-tools` | 运行时对拍 |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | --- | --- |
| `moonbit-self-cli-wasm.wasm`（自身 CLI） | Linear Wasm | 419,023 B | **328,721 B (-21.55%)** | -13.14% → **-21.55%** | 1,313 ms | 1,446→913 / 149→120 | 286,276 B (-31.68%, 848 ms) | PASS / PASS | WASI CLI |
| `moonbit-self-lib-wasmgc.wasm`（自身库 WasmGC） | WasmGC | 204,727 B | **168,177 B (-17.85%)** | -7.23% → **-17.85%** | 1,183 ms | 857→600 / 1,004→708 | 150,180 B (-26.64%, 593 ms) | PASS / PASS | **5/5 self-exec exact** |
| `moonbit-kernel-wasm.wasm` | Linear Wasm | 10,285 B | **8,347 B (-18.84%)** | -5.42% → **-18.84%** | **28 ms** | 94→64 | 6,928 B (-32.64%, 48 ms) | PASS / PASS | **32/32 exact (含 NaN)** |
| `moonbit-kernel-wasmgc.wasm` | WasmGC | 5,988 B | **4,899 B (-18.19%)** | -5.63% → **-18.19%** | **13 ms** | 60→43 | 4,207 B (-29.74%, 30 ms) | PASS / PASS | **32/32 exact (含 NaN)** |

> 说明：在 4 份真实 MoonBit 1.0 `--release` 产物上，`0.3.0` 已达到上游最新 C++ Binaryen `v133 -Oz --all-features` 总压缩幅度的 **58%–68%**（其中对自身 419 KB Linear Wasm 缩减 90,302 B，对自身 205 KB WasmGC 缩减 36,550 B 且精简 296 个 WasmGC 类型）。剩余差距主要来自跨分支尾代码折叠、表达式级 CSE 与 WasmGC 结构体字段裁剪，同时大模块活跃分析的耗时热点也将作为后续性能优化重点。

### 2. 官方 `WebAssembly/spec/test/core` + GC 批量规范回归（CI 实测）

CI 自动拉取官方 `WebAssembly/spec` 仓库，通过 `wasm-tools json-from-wast` 编译全部核心与 WasmGC 规范测试集并运行 [demo/verify_spec.py](demo/verify_spec.py)：

- **通过官方 `.wast` 套件**：**`52` 个**（覆盖 `i32`/`i64`/`f32`/`f64`/`f32_cmp`/`f64_cmp`/`block`/`loop`/`if`/`br_table`/`call_indirect`/`return_call`/`memory`/`data`/`elem` 及 16 个官方 **WasmGC** 规范套件 `struct`/`array`/`ref_cast`/`ref_test`/`br_on_cast`/`i31`/`type-equivalence`/`call_ref`/`ref_eq` 等）；
- **规范 `.wasm` 模块双重验签**（`roundtrip` + 14-Pass `-Oz --converge`，`wasm-tools validate` + V8 `WebAssembly.validate()`）：**`256 / 256` PASS（0 错误）**；
- **V8 `assert_return` 优化前后运行时等价性对拍**：**`12,970 / 12,970` 精确一致（0 偏差）**；
- **256 个官方规范模块总体积**：`87,703 B -> 68,308 B`（**-19,395 B / -22.11%**）。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-wasm-opt@0.3.0
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
# 执行 14-Pass -Oz --converge 优化并输出逐 Pass 减重报告
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
# 四目标单元测试（14 项含 256 组畸形二进制模糊测试）
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 构建零上传浏览器工作台并跑 V8 冒烟
python demo/build_web.py

# 跑通 V8 WebAssembly.validate()、32/32 内核对拍与 5/5 WasmGC 自举执行对拍
python demo/verify_oracle.py

# 如本机已安装 wasm-tools，可运行官方 WebAssembly/spec 批量回归
python demo/verify_spec.py --spec-dir /path/to/WebAssembly/spec
```
