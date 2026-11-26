///|
priv struct Vec2 {
  x : Int32
  y : Int32
  weight : Int32
}

///|
let mix_const_a : Int32 = 31

///|
let mix_const_b : Int32 = 17

///|
let tag_offset : Int32 = 7

///|
let lookup_bytes : Bytes = b"\x00\x00\x00\x00\x03\x05\x07\x0B\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0D\x11\x13\x17\x00\x00\x00\x00"

///|
fn clamp_non_neg(v : Int32) -> Int32 {
  if !(v >= 0) {
    0
  } else {
    v
  }
}

///|
fn scale_step(acc : Int32, i : Int32) -> Int32 {
  (acc ^ (i * 13 + tag_offset)) + ((acc >> 2) & 0xFF)
}

///|
fn single_use_accum(n : Int32) -> Int32 {
  let limit = clamp_non_neg(n)
  let mut sum = 0
  for i in 0..<limit {
    if !(i % 3 != 0) {
      sum += i * mix_const_a
    } else {
      sum += i * mix_const_b + tag_offset
    }
  }
  sum
}

///|
pub fn fib(n : Int32) -> Int32 {
  if n <= 1 {
    return n
  }
  let mut a = 0
  let mut b = 1
  for _ in 2..<=n {
    let next = a + b
    a = b
    b = next
  }
  b
}

///|
pub fn gcd(a0 : Int32, b0 : Int32) -> Int32 {
  let mut a = if a0 < 0 { -a0 } else { a0 }
  let mut b = if b0 < 0 { -b0 } else { b0 }
  while b != 0 {
    let t = a % b
    a = b
    b = t
  }
  a
}

///|
pub fn hash_mix(seed : Int32, steps : Int32) -> Int32 {
  let mut h = seed.reinterpret_as_uint() ^ 0x811C_9DC5U
  for i in 0..<steps {
    h = (h ^ i.reinterpret_as_uint()) * 16777619U
    h = h ^ (h >> 13)
  }
  h.reinterpret_as_int()
}

///|
pub fn sum_weighted(n : Int32) -> Int32 {
  let arr : Array[Int32] = []
  for i in 0..<n {
    arr.push(i * 3 + 1)
  }
  let mut acc = 0
  for i, v in arr {
    acc += v * (i + 1)
  }
  acc
}

///|
pub fn gc_point_score(n : Int32) -> Int32 {
  let pts : Array[Vec2] = []
  for i in 0..<n {
    pts.push({ x: i + 1, y: i * 2 + 3, weight: i % 5 + 1, })
  }
  let mut total = 0
  for p in pts {
    total += (p.x * 7 + p.y * 11) * p.weight
  }
  total
}

///|
/// Exercises `br_table` switch dispatch, negated integer comparisons, and static Bytes data lookup.
pub fn dispatch_score(code : Int32, x : Int32) -> Int32 {
  let base = match code {
    0 => x * 2 + 1
    1 => x * 3 - 2
    2 => (x ^ 0x5A) + 11
    3 => x + single_use_accum(x & 15)
    4 => clamp_non_neg(x) * 5
    _ => x + tag_offset
  }
  let idx = (if base < 0 { -base } else { base }) % lookup_bytes.length()
  base + lookup_bytes[idx].to_int()
}

///|
/// Exercises float comparison with NaN-sensitive negation (must preserve IEEE-754 semantics).
pub fn float_clamp_flag(x : Double) -> Int32 {
  if !(x < 0.0) {
    if !(x > 100.0) {
      1
    } else {
      2
    }
  } else {
    -1
  }
}

///|
/// Two structurally identical exported numeric kernels (targets for ICF merging + helper inlining).
pub fn dup_calc_a(x : Int32, y : Int32) -> Int32 {
  let mut acc = x * mix_const_a + y * mix_const_b
  for i in 0..<8 {
    acc = scale_step(acc, i)
  }
  acc
}

///|
pub fn dup_calc_b(x : Int32, y : Int32) -> Int32 {
  let mut acc = x * mix_const_a + y * mix_const_b
  for i in 0..<8 {
    acc = scale_step(acc, i)
  }
  acc
}
