///|
priv struct Vec2 {
  x : Int32
  y : Int32
  weight : Int32
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
    pts.push({ x: i + 1, y: i * 2 + 3, weight: (i % 5) + 1 })
  }
  let mut total = 0
  for p in pts {
    total += (p.x * 7 + p.y * 11) * p.weight
  }
  total
}

///|
/// Two structurally identical exported numeric kernels (targets for ICF merging).
pub fn dup_calc_a(x : Int32, y : Int32) -> Int32 {
  let mut acc = x * 31 + y * 17
  for i in 0..<8 {
    acc = (acc ^ (i * 13 + 7)) + ((acc >> 2) & 0xFF)
  }
  acc
}

///|
pub fn dup_calc_b(x : Int32, y : Int32) -> Int32 {
  let mut acc = x * 31 + y * 17
  for i in 0..<8 {
    acc = (acc ^ (i * 13 + 7)) + ((acc >> 2) & 0xFF)
  }
  acc
}
