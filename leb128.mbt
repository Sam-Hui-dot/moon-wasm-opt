///|
priv struct BinReader {
  data : Bytes
  mut pos : Int32
  end : Int32
}

///|
fn BinReader::new(data : Bytes) -> BinReader {
  { data, pos: 0, end: data.length(), }
}

///|
fn BinReader::slice(data : Bytes, start : Int32, end : Int32) -> BinReader {
  { data, pos: start, end, }
}

///|
fn BinReader::eof(self : BinReader) -> Bool {
  self.pos >= self.end
}

///|
fn BinReader::remaining(self : BinReader) -> Int32 {
  self.end - self.pos
}

///|
fn BinReader::peek_byte(self : BinReader) -> Byte raise WasmError {
  guard self.pos < self.end else {
    raise InvalidBinary("unexpected EOF at offset \{self.pos}")
  }
  self.data[self.pos]
}

///|
fn BinReader::read_byte(self : BinReader) -> Byte raise WasmError {
  guard self.pos < self.end else {
    raise InvalidBinary("unexpected EOF at offset \{self.pos}")
  }
  let b = self.data[self.pos]
  self.pos += 1
  b
}

///|
fn BinReader::read_bytes(
  self : BinReader,
  len : Int32,
) -> Bytes raise WasmError {
  guard len >= 0 && self.pos + len <= self.end else {
    raise InvalidBinary(
      "truncated slice of \{len} bytes at offset \{self.pos} (end=\{self.end})",
    )
  }
  let start = self.pos
  self.pos += len
  Bytes::makei(len, i => self.data[start + i])
}

///|
fn BinReader::read_u32(self : BinReader) -> UInt32 raise WasmError {
  let mut result = 0U
  let mut shift = 0
  while true {
    guard shift <= 35 else {
      raise InvalidBinary("u32 LEB128 overflow at offset \{self.pos}")
    }
    let b = self.read_byte().to_int().reinterpret_as_uint()
    result = result | ((b & 0x7FU) << shift)
    if (b & 0x80U) == 0U {
      return result
    }
    shift += 7
  }
  result
}

///|
fn BinReader::read_u64(self : BinReader) -> UInt64 raise WasmError {
  let mut result = 0UL
  let mut shift = 0
  while true {
    guard shift <= 70 else {
      raise InvalidBinary("u64 LEB128 overflow at offset \{self.pos}")
    }
    let b = self.read_byte().to_int().to_uint64()
    result = result | ((b & 0x7FUL) << shift)
    if (b & 0x80UL) == 0UL {
      return result
    }
    shift += 7
  }
  result
}

///|
fn BinReader::read_i32(self : BinReader) -> Int32 raise WasmError {
  let mut result = 0U
  let mut shift = 0
  while true {
    guard shift <= 35 else {
      raise InvalidBinary("i32 LEB128 overflow at offset \{self.pos}")
    }
    let b = self.read_byte().to_int().reinterpret_as_uint()
    result = result | ((b & 0x7FU) << shift)
    shift += 7
    if (b & 0x80U) == 0U {
      if shift < 32 && (b & 0x40U) != 0U {
        result = result | (0xFFFF_FFFFU << shift)
      }
      return result.reinterpret_as_int()
    }
  }
  0
}

///|
fn BinReader::read_i64(self : BinReader) -> Int64 raise WasmError {
  let mut result = 0UL
  let mut shift = 0
  while true {
    guard shift <= 70 else {
      raise InvalidBinary("i64 LEB128 overflow at offset \{self.pos}")
    }
    let b = self.read_byte().to_int().to_uint64()
    result = result | ((b & 0x7FUL) << shift)
    shift += 7
    if (b & 0x80UL) == 0UL {
      if shift < 64 && (b & 0x40UL) != 0UL {
        result = result | (0xFFFF_FFFF_FFFF_FFFFUL << shift)
      }
      return result.reinterpret_as_int64()
    }
  }
  0L
}

///|
fn BinReader::read_fixed_u32(self : BinReader) -> UInt32 raise WasmError {
  let b0 = self.read_byte().to_int().reinterpret_as_uint()
  let b1 = self.read_byte().to_int().reinterpret_as_uint()
  let b2 = self.read_byte().to_int().reinterpret_as_uint()
  let b3 = self.read_byte().to_int().reinterpret_as_uint()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn BinReader::read_fixed_u64(self : BinReader) -> UInt64 raise WasmError {
  let lo = self.read_fixed_u32().to_uint64()
  let hi = self.read_fixed_u32().to_uint64()
  lo | (hi << 32)
}

///|
fn decode_utf8(bytes : Bytes) -> String {
  let out = StringBuilder()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int()
    if b0 < 0x80 {
      out.write_char(b0.unsafe_to_char())
      i += 1
    } else if (b0 & 0xE0) == 0xC0 && i + 1 < n {
      let b1 = bytes[i + 1].to_int()
      let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
      out.write_char(cp.unsafe_to_char())
      i += 2
    } else if (b0 & 0xF0) == 0xE0 && i + 2 < n {
      let b1 = bytes[i + 1].to_int()
      let b2 = bytes[i + 2].to_int()
      let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
      out.write_char(cp.unsafe_to_char())
      i += 3
    } else if (b0 & 0xF8) == 0xF0 && i + 3 < n {
      let b1 = bytes[i + 1].to_int()
      let b2 = bytes[i + 2].to_int()
      let b3 = bytes[i + 3].to_int()
      let cp = ((b0 & 0x07) << 18) |
        ((b1 & 0x3F) << 12) |
        ((b2 & 0x3F) << 6) |
        (b3 & 0x3F)
      out.write_char(cp.unsafe_to_char())
      i += 4
    } else {
      out.write_char('\u{FFFD}')
      i += 1
    }
  }
  out.to_string()
}

///|
fn BinReader::read_name(self : BinReader) -> String raise WasmError {
  let len = self.read_u32().reinterpret_as_int()
  guard len >= 0 else {
    raise InvalidBinary("negative string length at offset \{self.pos}")
  }
  decode_utf8(self.read_bytes(len))
}

///|
priv struct BinWriter {
  buf : @buffer.Buffer
}

///|
fn BinWriter::new() -> BinWriter {
  { buf: @buffer.Buffer(), }
}

///|
fn BinWriter::to_bytes(self : BinWriter) -> Bytes {
  self.buf.to_bytes()
}

///|
fn BinWriter::write_byte(self : BinWriter, b : Byte) -> Unit {
  self.buf.write_byte(b)
}

///|
fn BinWriter::write_bytes(self : BinWriter, bs : Bytes) -> Unit {
  self.buf.write_bytesview(bs[:])
}

///|
fn BinWriter::write_u32(self : BinWriter, v : UInt32) -> Unit {
  let mut x = v
  while true {
    let byte = (x & 0x7FU).reinterpret_as_int()
    x = x >> 7
    if x == 0U {
      self.buf.write_byte(byte.to_byte())
      break
    } else {
      self.buf.write_byte((byte | 0x80).to_byte())
    }
  }
}

///|
fn BinWriter::write_u64(self : BinWriter, v : UInt64) -> Unit {
  let mut x = v
  while true {
    let byte = (x & 0x7FUL).to_int()
    x = x >> 7
    if x == 0UL {
      self.buf.write_byte(byte.to_byte())
      break
    } else {
      self.buf.write_byte((byte | 0x80).to_byte())
    }
  }
}

///|
fn BinWriter::write_i32(self : BinWriter, v : Int32) -> Unit {
  let mut x = v
  while true {
    let byte = x & 0x7F
    x = x >> 7
    let done = (x == 0 && (byte & 0x40) == 0) || (x == -1 && (byte & 0x40) != 0)
    if done {
      self.buf.write_byte(byte.to_byte())
      break
    } else {
      self.buf.write_byte((byte | 0x80).to_byte())
    }
  }
}

///|
fn BinWriter::write_i64(self : BinWriter, v : Int64) -> Unit {
  let mut x = v
  while true {
    let byte = (x & 0x7FL).to_int()
    x = x >> 7
    let done = (x == 0L && (byte & 0x40) == 0) ||
      (x == -1L && (byte & 0x40) != 0)
    if done {
      self.buf.write_byte(byte.to_byte())
      break
    } else {
      self.buf.write_byte((byte | 0x80).to_byte())
    }
  }
}

///|
fn BinWriter::write_fixed_u32(self : BinWriter, v : UInt32) -> Unit {
  self.buf.write_byte((v & 0xFFU).reinterpret_as_int().to_byte())
  self.buf.write_byte(((v >> 8) & 0xFFU).reinterpret_as_int().to_byte())
  self.buf.write_byte(((v >> 16) & 0xFFU).reinterpret_as_int().to_byte())
  self.buf.write_byte(((v >> 24) & 0xFFU).reinterpret_as_int().to_byte())
}

///|
fn BinWriter::write_fixed_u64(self : BinWriter, v : UInt64) -> Unit {
  self.write_fixed_u32((v & 0xFFFF_FFFFUL).to_uint())
  self.write_fixed_u32((v >> 32).to_uint())
}

///|
fn encode_utf8(text : String) -> Bytes {
  let b = @buffer.Buffer()
  for ch in text {
    let cp = ch.to_int()
    if cp < 0x80 {
      b.write_byte(cp.to_byte())
    } else if cp < 0x800 {
      b.write_byte((0xC0 | (cp >> 6)).to_byte())
      b.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      b.write_byte((0xE0 | (cp >> 12)).to_byte())
      b.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      b.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else {
      b.write_byte((0xF0 | (cp >> 18)).to_byte())
      b.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      b.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      b.write_byte((0x80 | (cp & 0x3F)).to_byte())
    }
  }
  b.to_bytes()
}

///|
fn BinWriter::write_name(self : BinWriter, text : String) -> Unit {
  let raw = encode_utf8(text)
  self.write_u32(raw.length().reinterpret_as_uint())
  self.write_bytes(raw)
}

///|
fn BinWriter::write_section(
  self : BinWriter,
  sec_id : Byte,
  payload : Bytes,
) -> Unit {
  self.write_byte(sec_id)
  self.write_u32(payload.length().reinterpret_as_uint())
  self.write_bytes(payload)
}
