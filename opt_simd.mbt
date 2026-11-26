///|
fn bytes16_is_zero(b : Bytes) -> Bool {
  if b.length() != 16 {
    return false
  }
  for i in 0..<16 {
    if b[i] != b'\x00' {
      return false
    }
  }
  true
}

///|
fn bytes16_is_all_ones(b : Bytes) -> Bool {
  if b.length() != 16 {
    return false
  }
  for i in 0..<16 {
    if b[i] != b'\xFF' {
      return false
    }
  }
  true
}

///|
fn is_identity_shuffle(lanes : Bytes) -> Bool {
  if lanes.length() != 16 {
    return false
  }
  for i in 0..<16 {
    if lanes[i].to_int() != i {
      return false
    }
  }
  true
}

///|
fn bytes16_not(a : Bytes) -> Bytes {
  Bytes::makei(16, i => (a[i].to_int() ^ 0xFF).to_byte())
}

///|
fn bytes16_bin(a : Bytes, b : Bytes, op : UInt32) -> Bytes {
  Bytes::makei(16, i => {
    let x = a[i].to_int()
    let y = b[i].to_int()
    let r = match op {
      78U => x & y
      79U => x & (y ^ 0xFF)
      80U => x | y
      81U => x ^ y
      _ => x
    }
    r.to_byte()
  })
}

///|
fn read_le_i32(b : Bytes, lane : Int32) -> Int32 {
  let off = lane * 4
  let u = b[off].to_uint() |
    (b[off + 1].to_uint() << 8) |
    (b[off + 2].to_uint() << 16) |
    (b[off + 3].to_uint() << 24)
  u.reinterpret_as_int()
}

///|
fn write_le_i32_into(arr : FixedArray[Byte], off : Int32, v : Int32) -> Unit {
  let u = v.reinterpret_as_uint()
  arr[off] = (u & 0xFFU).to_byte()
  arr[off + 1] = ((u >> 8) & 0xFFU).to_byte()
  arr[off + 2] = ((u >> 16) & 0xFFU).to_byte()
  arr[off + 3] = ((u >> 24) & 0xFFU).to_byte()
}

///|
fn read_le_i64(b : Bytes, lane : Int32) -> Int64 {
  let off = lane * 8
  let mut u = 0UL
  for k in 0..<8 {
    u = u | (b[off + k].to_int().to_uint64() << (k * 8))
  }
  u.reinterpret_as_int64()
}

///|
fn write_le_i64_into(arr : FixedArray[Byte], off : Int32, v : Int64) -> Unit {
  let u = v.reinterpret_as_uint64()
  for k in 0..<8 {
    arr[off + k] = ((u >> (k * 8)) & 0xFFUL).to_byte()
  }
}

///|
fn splat_i32_bytes(v : Int32) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for lane in 0..<4 {
    write_le_i32_into(arr, lane * 4, v)
  }
  Bytes::from_array(arr)
}

///|
fn splat_i64_bytes(v : Int64) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for lane in 0..<2 {
    write_le_i64_into(arr, lane * 8, v)
  }
  Bytes::from_array(arr)
}

///|
fn fold_i32x4_bin(a : Bytes, b : Bytes, is_sub : Bool) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for lane in 0..<4 {
    let va = read_le_i32(a, lane).reinterpret_as_uint()
    let vb = read_le_i32(b, lane).reinterpret_as_uint()
    let vr = if is_sub { va - vb } else { va + vb }
    write_le_i32_into(arr, lane * 4, vr.reinterpret_as_int())
  }
  Bytes::from_array(arr)
}

///|
fn fold_i64x2_bin(a : Bytes, b : Bytes, is_sub : Bool) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  for lane in 0..<2 {
    let va = read_le_i64(a, lane).reinterpret_as_uint64()
    let vb = read_le_i64(b, lane).reinterpret_as_uint64()
    let vr = if is_sub { va - vb } else { va + vb }
    write_le_i64_into(arr, lane * 8, vr.reinterpret_as_int64())
  }
  Bytes::from_array(arr)
}

///|
fn shuffle_const_bytes(a : Bytes, b : Bytes, lanes : Bytes) -> Bytes? {
  if a.length() != 16 || b.length() != 16 || lanes.length() != 16 {
    return None
  }
  for i in 0..<16 {
    if lanes[i].to_int() >= 32 {
      return None
    }
  }
  Some(
    Bytes::makei(16, i => {
      let sel = lanes[i].to_int()
      if sel < 16 {
        a[sel]
      } else {
        b[sel - 16]
      }
    }),
  )
}

///|
fn opt_simd_seq(instrs : Array[Instr]) -> Array[Instr] {
  let staged : Array[Instr] = []
  let mut child_changed = false
  for ins in instrs {
    match ins {
      Block(bt, b) => {
        let nb = opt_simd_seq(b)
        if !physical_equal(nb, b) {
          child_changed = true
        }
        staged.push(Block(bt, nb))
      }
      Loop(bt, b) => {
        let nb = opt_simd_seq(b)
        if !physical_equal(nb, b) {
          child_changed = true
        }
        staged.push(Loop(bt, nb))
      }
      If(bt, t, e) => {
        let nt = opt_simd_seq(t)
        let ne = opt_simd_seq(e)
        if !physical_equal(nt, t) || !physical_equal(ne, e) {
          child_changed = true
        }
        staged.push(If(bt, nt, ne))
      }
      TryTable(bt, cs, b) => {
        let nb = opt_simd_seq(b)
        if !physical_equal(nb, b) {
          child_changed = true
        }
        staged.push(TryTable(bt, cs, nb))
      }
      other => staged.push(other)
    }
  }

  let out : Array[Instr] = []
  let mut folded_any = false
  for raw in staged {
    out.push(raw)
    let mut reduced = true
    while reduced && !out.is_empty() {
      reduced = false
      let n = out.length()
      if n >= 3 {
        match (out[n - 3], out[n - 2], out[n - 1]) {
          (SimdV128Const(a), SimdV128Const(b), SimdSimpleOp(op)) if a.length() ==
            16 &&
            b.length() == 16 =>
            if op == 78U || op == 79U || op == 80U || op == 81U {
              ignore(out.pop())
              ignore(out.pop())
              ignore(out.pop())
              out.push(SimdV128Const(bytes16_bin(a, b, op)))
              folded_any = true
              reduced = true
              continue
            } else if op == 174U || op == 177U {
              ignore(out.pop())
              ignore(out.pop())
              ignore(out.pop())
              out.push(SimdV128Const(fold_i32x4_bin(a, b, op == 177U)))
              folded_any = true
              reduced = true
              continue
            } else if op == 206U || op == 209U {
              ignore(out.pop())
              ignore(out.pop())
              ignore(out.pop())
              out.push(SimdV128Const(fold_i64x2_bin(a, b, op == 209U)))
              folded_any = true
              reduced = true
              continue
            }
          (SimdV128Const(a), SimdV128Const(b), SimdShuffle(lanes)) =>
            match shuffle_const_bytes(a, b, lanes) {
              Some(res) => {
                ignore(out.pop())
                ignore(out.pop())
                ignore(out.pop())
                out.push(SimdV128Const(res))
                folded_any = true
                reduced = true
                continue
              }
              None => ()
            }
          _ => ()
        }
      }
      if n >= 2 {
        match (out[n - 2], out[n - 1]) {
          (I32Const(v), SimdSimpleOp(17U)) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(SimdV128Const(splat_i32_bytes(v)))
            folded_any = true
            reduced = true
            continue
          }
          (I64Const(v), SimdSimpleOp(18U)) => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(SimdV128Const(splat_i64_bytes(v)))
            folded_any = true
            reduced = true
            continue
          }
          (SimdV128Const(a), SimdSimpleOp(77U)) if a.length() == 16 => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(SimdV128Const(bytes16_not(a)))
            folded_any = true
            reduced = true
            continue
          }
          (SimdV128Const(a), SimdLaneOp(27U, lane)) if a.length() == 16 &&
            lane.to_int() < 4 => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(I32Const(read_le_i32(a, lane.to_int())))
            folded_any = true
            reduced = true
            continue
          }
          (SimdV128Const(a), SimdLaneOp(29U, lane)) if a.length() == 16 &&
            lane.to_int() < 2 => {
            ignore(out.pop())
            ignore(out.pop())
            out.push(I64Const(read_le_i64(a, lane.to_int())))
            folded_any = true
            reduced = true
            continue
          }
          // Algebraic v128 bit identities: x OR 0 == x, x XOR 0 == x, x AND all1 == x, x ANDNOT 0 == x
          (SimdV128Const(z), SimdSimpleOp(op)) if (
              op == 80U || op == 81U || op == 79U
            ) &&
            bytes16_is_zero(z) => {
            ignore(out.pop())
            ignore(out.pop())
            folded_any = true
            reduced = true
            continue
          }
          (SimdV128Const(ones), SimdSimpleOp(78U)) if bytes16_is_all_ones(ones) => {
            ignore(out.pop())
            ignore(out.pop())
            folded_any = true
            reduced = true
            continue
          }
          // [x, pure_v2, i8x16.shuffle [0..15]] -> [x]
          (pure_v2, SimdShuffle(lanes)) if is_identity_shuffle(lanes) &&
            is_pure_single_push(pure_v2) => {
            ignore(out.pop())
            ignore(out.pop())
            folded_any = true
            reduced = true
            continue
          }
          _ => ()
        }
      }
    }
  }

  if !child_changed && !folded_any {
    instrs
  } else {
    out
  }
}

///|
fn pass_opt_simd_dirty(
  mod : WasmModule,
  dirty : Array[Bool]?,
) -> (WasmModule, Array[Bool]) {
  let out_changed : Array[Bool] = Array::make(mod.codes.length(), false)
  if mod.codes.is_empty() {
    return (mod, out_changed)
  }
  let new_codes : Array[FuncBody] = []
  let mut changed = false
  for i, fb in mod.codes {
    let run = match dirty {
      Some(d) => d[i]
      None => true
    }
    if run {
      let nb = opt_simd_seq(fb.body)
      if !physical_equal(nb, fb.body) && nb != fb.body {
        let cand : FuncBody = { locals: fb.locals, body: nb, }
        if encode_func_body(cand).length() <= encode_func_body(fb).length() {
          changed = true
          out_changed[i] = true
          new_codes.push(cand)
          continue
        }
      }
    }
    new_codes.push(fb)
  }
  if !changed {
    (mod, out_changed)
  } else {
    ({ ..mod, codes: new_codes, }, out_changed)
  }
}

///|
/// Pass 17: WebAssembly SIMD `0xFD` constant folding (`v128` bit ops, `i32x4`/`i64x2` splat/extract/add/sub)
/// and bitwise/shuffle identity simplification.
pub fn pass_opt_simd(mod : WasmModule) -> WasmModule {
  let (next, _) = pass_opt_simd_dirty(mod, None)
  next
}
