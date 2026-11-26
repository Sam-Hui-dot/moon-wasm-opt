///|
/// Errors raised while decoding, encoding, validating, analyzing, or optimizing WebAssembly binaries.
#derive(Debug, Eq)
pub(all) suberror WasmError {
  InvalidBinary(String)
  UnsupportedFeature(String)
  InvalidInput(String)
}

///|
pub extend WasmError with @debug.Debug::{to_repr}

///|
pub extend WasmError with Eq::{not_equal, equal}

///|
/// Return a concise human-readable diagnostic message for any error.
pub fn error_message(error : Error) -> String {
  match error {
    InvalidBinary(msg) | UnsupportedFeature(msg) | InvalidInput(msg) => msg
    other => other.to_string()
  }
}

///|
/// WebAssembly heap type (abstract shorthand byte 0x69..0x74 or concrete type index).
#derive(Debug, Eq)
pub(all) enum HeapType {
  Abstract(Byte)
  Concrete(UInt32)
}

///|
pub extend HeapType with @debug.Debug::{to_repr}

///|
pub extend HeapType with Eq::{not_equal, equal}

///|
/// WebAssembly 2.0 + WasmGC value type.
#derive(Debug, Eq)
pub(all) enum ValType {
  I32
  I64
  F32
  F64
  V128
  ShortRef(Byte)
  RefNull(HeapType)
  Ref(HeapType)
}

///|
pub extend ValType with @debug.Debug::{to_repr}

///|
pub extend ValType with Eq::{not_equal, equal}

///|
/// WasmGC struct/array storage type (`valtype`, packed `i8`, or packed `i16`).
#derive(Debug, Eq)
pub(all) enum StorageType {
  Val(ValType)
  I8
  I16
}

///|
pub extend StorageType with @debug.Debug::{to_repr}

///|
pub extend StorageType with Eq::{not_equal, equal}

///|
/// WasmGC field type with mutability flag.
#derive(Debug, Eq)
pub(all) struct FieldType {
  storage : StorageType
  mutable : Bool
}

///|
pub extend FieldType with @debug.Debug::{to_repr}

///|
pub extend FieldType with Eq::{not_equal, equal}

///|
/// WasmGC composite type (`func`, `struct`, or `array`).
#derive(Debug, Eq)
pub(all) enum CompType {
  Func(Array[ValType], Array[ValType])
  Struct(Array[FieldType])
  Array(FieldType)
}

///|
pub extend CompType with @debug.Debug::{to_repr}

///|
pub extend CompType with Eq::{not_equal, equal}

///|
/// WasmGC subtype wrapper preserving exact `sub` / `sub final` encoding.
#derive(Debug, Eq)
pub(all) struct SubType {
  is_final : Bool
  explicit_sub : Bool
  supers : Array[UInt32]
  comp : CompType
}

///|
pub extend SubType with @debug.Debug::{to_repr}

///|
pub extend SubType with Eq::{not_equal, equal}

///|
/// WasmGC recursive type group (`rec`) or standalone type definition.
#derive(Debug, Eq)
pub(all) struct RecGroup {
  explicit_rec : Bool
  subtypes : Array[SubType]
}

///|
pub extend RecGroup with @debug.Debug::{to_repr}

///|
pub extend RecGroup with Eq::{not_equal, equal}

///|
/// Memory or table limits (supports 32-bit, 64-bit, and shared flags).
#derive(Debug, Eq)
pub(all) struct Limits {
  flags : Byte
  min : UInt64
  max : UInt64?
}

///|
pub extend Limits with @debug.Debug::{to_repr}

///|
pub extend Limits with Eq::{not_equal, equal}

///|
/// Global variable type descriptor.
#derive(Debug, Eq)
pub(all) struct GlobalType {
  val_type : ValType
  mutable : Bool
}

///|
pub extend GlobalType with @debug.Debug::{to_repr}

///|
pub extend GlobalType with Eq::{not_equal, equal}

///|
/// Exception-handling tag descriptor.
#derive(Debug, Eq)
pub(all) struct TagType {
  attr : Byte
  type_idx : UInt32
}

///|
pub extend TagType with @debug.Debug::{to_repr}

///|
pub extend TagType with Eq::{not_equal, equal}

///|
/// Structured control-flow block signature.
#derive(Debug, Eq)
pub(all) enum BlockType {
  Empty
  Val(ValType)
  TypeIdx(UInt32)
}

///|
pub extend BlockType with @debug.Debug::{to_repr}

///|
pub extend BlockType with Eq::{not_equal, equal}

///|
/// Linear memory immediate argument (supports multi-memory index bit `0x40`).
#derive(Debug, Eq)
pub(all) struct MemArg {
  align : UInt32
  offset : UInt64
  mem_idx : UInt32
}

///|
pub extend MemArg with @debug.Debug::{to_repr}

///|
pub extend MemArg with Eq::{not_equal, equal}

///|
/// Catch handler clause inside a Wasm `try_table` instruction.
#derive(Debug, Eq)
pub(all) enum CatchClause {
  Catch(UInt32, UInt32)
  CatchRef(UInt32, UInt32)
  CatchAll(UInt32)
  CatchAllRef(UInt32)
}

///|
pub extend CatchClause with @debug.Debug::{to_repr}

///|
pub extend CatchClause with Eq::{not_equal, equal}

///|
/// Typed WebAssembly 2.0 + WasmGC + Exception-Handling + SIMD instruction AST.
#derive(Debug, Eq)
pub(all) enum Instr {
  // Control flow
  Unreachable
  Nop
  Block(BlockType, Array[Instr])
  Loop(BlockType, Array[Instr])
  If(BlockType, Array[Instr], Array[Instr])
  Br(UInt32)
  BrIf(UInt32)
  BrTable(Array[UInt32], UInt32)
  Return
  Call(UInt32)
  CallIndirect(UInt32, UInt32)
  ReturnCall(UInt32)
  ReturnCallIndirect(UInt32, UInt32)
  CallRef(UInt32)
  ReturnCallRef(UInt32)
  BrOnNull(UInt32)
  BrOnNonNull(UInt32)
  // Exception handling
  Throw(UInt32)
  ThrowRef
  TryTable(BlockType, Array[CatchClause], Array[Instr])
  // Parametric
  Drop
  Select
  SelectTyped(Array[ValType])
  // Variables
  LocalGet(UInt32)
  LocalSet(UInt32)
  LocalTee(UInt32)
  GlobalGet(UInt32)
  GlobalSet(UInt32)
  // Tables
  TableGet(UInt32)
  TableSet(UInt32)
  // Memory
  MemOp(Byte, MemArg)
  MemorySize(UInt32)
  MemoryGrow(UInt32)
  // Constants (IEEE-754 floats stored as exact raw bits for lossless NaN/-0.0 round-trip)
  I32Const(Int32)
  I64Const(Int64)
  F32Const(UInt32)
  F64Const(UInt64)
  // Numeric / conversion / sign-extension single-byte ops (0x45..0xC4)
  NumOp(Byte)
  // Reference ops
  RefNull(HeapType)
  RefIsNull
  RefFunc(UInt32)
  RefEq
  RefAsNonNull
  // 0xFC misc / saturating trunc / bulk-memory / table ops
  MiscSatTrunc(UInt32)
  MemoryInit(UInt32, UInt32)
  DataDrop(UInt32)
  MemoryCopy(UInt32, UInt32)
  MemoryFill(UInt32)
  TableInit(UInt32, UInt32)
  ElemDrop(UInt32)
  TableCopy(UInt32, UInt32)
  TableGrow(UInt32)
  TableSize(UInt32)
  TableFill(UInt32)
  // 0xFB WasmGC ops
  StructNew(UInt32)
  StructNewDefault(UInt32)
  StructGet(UInt32, UInt32)
  StructGetS(UInt32, UInt32)
  StructGetU(UInt32, UInt32)
  StructSet(UInt32, UInt32)
  ArrayNew(UInt32)
  ArrayNewDefault(UInt32)
  ArrayNewFixed(UInt32, UInt32)
  ArrayNewData(UInt32, UInt32)
  ArrayNewElem(UInt32, UInt32)
  ArrayGet(UInt32)
  ArrayGetS(UInt32)
  ArrayGetU(UInt32)
  ArraySet(UInt32)
  ArrayLen
  ArrayFill(UInt32)
  ArrayCopy(UInt32, UInt32)
  ArrayInitData(UInt32, UInt32)
  ArrayInitElem(UInt32, UInt32)
  RefTest(HeapType)
  RefTestNull(HeapType)
  RefCast(HeapType)
  RefCastNull(HeapType)
  BrOnCast(Byte, UInt32, HeapType, HeapType)
  BrOnCastFail(Byte, UInt32, HeapType, HeapType)
  AnyConvertExtern
  ExternConvertAny
  RefI31
  I31GetS
  I31GetU
  // 0xFD SIMD ops
  SimdV128Const(Bytes)
  SimdShuffle(Bytes)
  SimdMemOp(UInt32, MemArg)
  SimdMemLaneOp(UInt32, MemArg, Byte)
  SimdLaneOp(UInt32, Byte)
  SimdSimpleOp(UInt32)
}

///|
pub extend Instr with @debug.Debug::{to_repr}

///|
pub extend Instr with Eq::{not_equal, equal}

///|
/// Table definition (supports WasmGC table init expression).
#derive(Debug, Eq)
pub(all) struct TableType {
  elem_type : ValType
  limits : Limits
  init_expr : Array[Instr]?
}

///|
pub extend TableType with @debug.Debug::{to_repr}

///|
pub extend TableType with Eq::{not_equal, equal}

///|
/// External import descriptor.
#derive(Debug, Eq)
pub(all) enum ImportDesc {
  Func(UInt32)
  Table(TableType)
  Mem(Limits)
  Global(GlobalType)
  Tag(TagType)
}

///|
pub extend ImportDesc with @debug.Debug::{to_repr}

///|
pub extend ImportDesc with Eq::{not_equal, equal}

///|
/// Module import entry.
#derive(Debug, Eq)
pub(all) struct Import {
  mod_name : String
  field_name : String
  desc : ImportDesc
}

///|
pub extend Import with @debug.Debug::{to_repr}

///|
pub extend Import with Eq::{not_equal, equal}

///|
/// Module-defined global variable with constant initializer expression.
#derive(Debug, Eq)
pub(all) struct GlobalDef {
  global_type : GlobalType
  init : Array[Instr]
}

///|
pub extend GlobalDef with @debug.Debug::{to_repr}

///|
pub extend GlobalDef with Eq::{not_equal, equal}

///|
/// Export target kind.
#derive(Debug, Eq)
pub(all) enum ExportKind {
  Func
  Table
  Mem
  Global
  Tag
}

///|
pub extend ExportKind with @debug.Debug::{to_repr}

///|
pub extend ExportKind with Eq::{not_equal, equal}

///|
/// Module export entry.
#derive(Debug, Eq)
pub(all) struct Export {
  name : String
  kind : ExportKind
  idx : UInt32
}

///|
pub extend Export with @debug.Debug::{to_repr}

///|
pub extend Export with Eq::{not_equal, equal}

///|
/// Element segment (covers all 8 Wasm 2.0 + WasmGC segment kinds 0..7).
#derive(Debug, Eq)
pub(all) struct ElemSegment {
  flags : UInt32
  table_idx : UInt32
  offset : Array[Instr]?
  elem_kind : Byte
  ref_type : ValType?
  func_indices : Array[UInt32]
  init_exprs : Array[Array[Instr]]
}

///|
pub extend ElemSegment with @debug.Debug::{to_repr}

///|
pub extend ElemSegment with Eq::{not_equal, equal}

///|
/// Data segment (covers all 3 Wasm 2.0 segment kinds 0..2).
#derive(Debug, Eq)
pub(all) struct DataSegment {
  flags : UInt32
  mem_idx : UInt32
  offset : Array[Instr]?
  data : Bytes
}

///|
pub extend DataSegment with @debug.Debug::{to_repr}

///|
pub extend DataSegment with Eq::{not_equal, equal}

///|
/// Run-length encoded local variable declaration group.
#derive(Debug, Eq)
pub(all) struct LocalGroup {
  count : UInt32
  val_type : ValType
}

///|
pub extend LocalGroup with @debug.Debug::{to_repr}

///|
pub extend LocalGroup with Eq::{not_equal, equal}

///|
/// Function body in the Code section.
#derive(Debug, Eq)
pub(all) struct FuncBody {
  locals : Array[LocalGroup]
  body : Array[Instr]
}

///|
pub extend FuncBody with @debug.Debug::{to_repr}

///|
pub extend FuncBody with Eq::{not_equal, equal}

///|
/// Preserved custom section (e.g. `name`, `producers`, `sourceMappingURL`).
#derive(Debug, Eq)
pub(all) struct CustomSection {
  name : String
  payload : Bytes
  after_section : Byte
}

///|
pub extend CustomSection with @debug.Debug::{to_repr}

///|
pub extend CustomSection with Eq::{not_equal, equal}

///|
/// Complete decoded WebAssembly 2.0 / WasmGC module representation.
#derive(Debug, Eq)
pub(all) struct WasmModule {
  type_groups : Array[RecGroup]
  imports : Array[Import]
  func_types : Array[UInt32]
  tables : Array[TableType]
  memories : Array[Limits]
  tags : Array[TagType]
  globals : Array[GlobalDef]
  exports : Array[Export]
  start_func : UInt32?
  elements : Array[ElemSegment]
  has_data_count : Bool
  codes : Array[FuncBody]
  datas : Array[DataSegment]
  custom_sections : Array[CustomSection]
  module_name : String
  func_names : Map[UInt32, String]
}

///|
pub extend WasmModule with @debug.Debug::{to_repr}

///|
pub extend WasmModule with Eq::{not_equal, equal}

///|
/// Count total imported functions in the module.
pub fn WasmModule::imported_func_count(self : WasmModule) -> UInt32 {
  let mut count = 0U
  for imp in self.imports {
    match imp.desc {
      Func(_) => count += 1U
      _ => ()
    }
  }
  count
}

///|
/// Count total imported globals in the module.
pub fn WasmModule::imported_global_count(self : WasmModule) -> UInt32 {
  let mut count = 0U
  for imp in self.imports {
    match imp.desc {
      Global(_) => count += 1U
      _ => ()
    }
  }
  count
}

///|
/// Count total type definitions across all recursive type groups.
pub fn WasmModule::total_type_count(self : WasmModule) -> UInt32 {
  let mut count = 0U
  for g in self.type_groups {
    count += g.subtypes.length().reinterpret_as_uint()
  }
  count
}

///|
/// Flatten all recursive type groups into a type-index addressable array of `SubType`.
pub fn WasmModule::flat_types(self : WasmModule) -> Array[SubType] {
  let out : Array[SubType] = []
  for g in self.type_groups {
    for st in g.subtypes {
      out.push(st)
    }
  }
  out
}

///|
/// Look up the type index of any function (imported or defined).
pub fn WasmModule::func_type_index(
  self : WasmModule,
  func_idx : UInt32,
) -> UInt32? {
  let mut imp_idx = 0U
  for imp in self.imports {
    match imp.desc {
      Func(tidx) => {
        if imp_idx == func_idx {
          return Some(tidx)
        }
        imp_idx += 1U
      }
      _ => ()
    }
  }
  let def_idx = func_idx.reinterpret_as_int() - imp_idx.reinterpret_as_int()
  if def_idx >= 0 && def_idx < self.func_types.length() {
    Some(self.func_types[def_idx])
  } else {
    None
  }
}

///|
/// Return the number of parameter locals of a function (or 0 if signature cannot be resolved).
pub fn WasmModule::func_param_count(
  self : WasmModule,
  func_idx : UInt32,
) -> UInt32 {
  match self.func_type_index(func_idx) {
    Some(tidx) => {
      let flat = self.flat_types()
      let i = tidx.reinterpret_as_int()
      if i >= 0 && i < flat.length() {
        match flat[i].comp {
          Func(params, _) => params.length().reinterpret_as_uint()
          _ => 0U
        }
      } else {
        0U
      }
    }
    None => 0U
  }
}

///|
/// Resolve a readable display name for any function index using `name` section, exports, or imports.
pub fn WasmModule::resolve_func_name(
  self : WasmModule,
  func_idx : UInt32,
) -> String {
  match self.func_names.get(func_idx) {
    Some(n) => if !n.is_empty() { return n }
    None => ()
  }
  for exp in self.exports {
    if exp.kind == Func && exp.idx == func_idx {
      return exp.name
    }
  }
  let mut imp_i = 0U
  for imp in self.imports {
    match imp.desc {
      Func(_) => {
        if imp_i == func_idx {
          return "\{imp.mod_name}.\{imp.field_name}"
        }
        imp_i += 1U
      }
      _ => ()
    }
  }
  "$func\{func_idx}"
}
