///|
test "fuzz: decode_module handles 256 malformed inputs and all truncated prefixes without panicking" {
  // 1. All truncated prefixes of a valid Wasm module must cleanly return Err
  let valid = @moon-wasm-opt.encode_module(make_sample_linear_module())
  for len in 0..<valid.length() {
    let prefix = Bytes::makei(len, i => valid[i])
    let res : Result[@moon-wasm-opt.WasmModule, Error] = Ok(
      @moon-wasm-opt.decode_module(prefix),
    ) catch {
      e => Err(e)
    }
    // Truncated prefixes shorter than valid header or cutting mid-section must not panic
    match res {
      Ok(_) => assert_true(len >= 8)
      Err(_) => ()
    }
  }

  // 2. 256 deterministic pseudo-random malformed payloads with valid \0asm header
  let mut seed = 0x1234_5678U
  fn next_u32() -> UInt32 {
    seed = seed * 1664525U + 1013904223U
    seed
  }
  for case_i in 0..<256 {
    let body_len = (next_u32() % 96U).reinterpret_as_int()
    let raw = Bytes::makei(8 + body_len, idx => {
      if idx == 0 {
        b'\x00'
      } else if idx == 1 {
        b'\x61'
      } else if idx == 2 {
        b'\x73'
      } else if idx == 3 {
        b'\x6D'
      } else if idx == 4 {
        b'\x01'
      } else if idx <= 7 {
        b'\x00'
      } else if case_i % 4 == 0 && idx == 8 {
        // Force code section id with garbage payload
        b'\x0A'
      } else {
        (next_u32() & 0xFFU).reinterpret_as_int().to_byte()
      }
    })
    let res : Result[@moon-wasm-opt.WasmModule, Error] = Ok(
      @moon-wasm-opt.decode_module(raw),
    ) catch {
      e => Err(e)
    }
    match res {
      Ok(m) => {
        // If random bytes happened to be structurally decodable, re-encoding must succeed too
        let re = @moon-wasm-opt.encode_module(m)
        assert_true(re.length() >= 8)
      }
      Err(_) => ()
    }
  }
}
