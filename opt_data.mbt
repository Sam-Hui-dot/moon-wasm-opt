///|
fn imported_mem_count(mod : WasmModule) -> UInt32 {
  let mut count = 0U
  for imp in mod.imports {
    match imp.desc {
      Mem(_) => count += 1U
      _ => ()
    }
  }
  count
}

///|
fn instrs_have_data_refs(instrs : Array[Instr]) -> Bool {
  for ins in instrs {
    match ins {
      MemoryInit(_, _)
      | DataDrop(_)
      | ArrayNewData(_, _)
      | ArrayInitData(_, _) => return true
      Block(_, b) | Loop(_, b) | TryTable(_, _, b) =>
        if instrs_have_data_refs(b) {
          return true
        }
      If(_, t, e) =>
        if instrs_have_data_refs(t) || instrs_have_data_refs(e) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn module_has_data_refs(mod : WasmModule) -> Bool {
  for fb in mod.codes {
    if instrs_have_data_refs(fb.body) {
      return true
    }
  }
  false
}

///|
fn parse_const_mem_offset(offset : Array[Instr]?) -> (Bool, UInt64)? {
  match offset {
    Some(expr) =>
      if expr.length() == 1 {
        match expr[0] {
          I32Const(v) => Some((false, v.reinterpret_as_uint().to_uint64()))
          I64Const(v) => Some((true, v.reinterpret_as_uint64()))
          _ => None
        }
      } else {
        None
      }
    None => None
  }
}

///|
fn make_const_mem_offset(is_i64 : Bool, off : UInt64) -> Array[Instr] {
  if is_i64 {
    [I64Const(off.reinterpret_as_int64())]
  } else {
    [I32Const(off.to_uint().reinterpret_as_int())]
  }
}

///|
fn slice_bytes(src : Bytes, start : Int32, end : Int32) -> Bytes {
  let len = end - start
  if len <= 0 {
    b""
  } else {
    Bytes::makei(len, i => src[start + i])
  }
}

///|
fn encode_data_segment_size(ds : DataSegment) -> Int32 {
  let w = BinWriter::new()
  w.write_u32(ds.flags)
  if ds.flags == 2U {
    w.write_u32(ds.mem_idx)
  }
  match ds.offset {
    Some(expr) => write_expr(w, expr)
    None => ()
  }
  w.write_u32(ds.data.length().reinterpret_as_uint())
  w.write_bytes(ds.data)
  w.to_bytes().length()
}

///|
fn split_active_zero_runs(
  flags : UInt32,
  mem_idx : UInt32,
  is_i64 : Bool,
  base_off : UInt64,
  data : Bytes,
  min_zero_run : Int32,
) -> Array[DataSegment] {
  let n = data.length()
  let pieces : Array[DataSegment] = []
  let mut seg_start = 0
  let mut i = 0
  while i < n {
    if data[i] == b'\x00' {
      let z_start = i
      while i < n && data[i] == b'\x00' {
        i += 1
      }
      let z_len = i - z_start
      if z_len >= min_zero_run {
        if z_start > seg_start {
          pieces.push({
            flags,
            mem_idx,
            offset: Some(
              make_const_mem_offset(is_i64, base_off + seg_start.to_uint64()),
            ),
            data: slice_bytes(data, seg_start, z_start),
          })
        }
        seg_start = i
      }
    } else {
      i += 1
    }
  }
  if seg_start < n {
    pieces.push({
      flags,
      mem_idx,
      offset: Some(
        make_const_mem_offset(is_i64, base_off + seg_start.to_uint64()),
      ),
      data: slice_bytes(data, seg_start, n),
    })
  }
  pieces
}

///|
/// Pass 10: Trim leading/trailing zero padding and split long internal zero runs in active Data segments.
/// Strictly preserves passive segments, imported memories, overlapping active writes, and out-of-bounds trap semantics.
pub fn pass_opt_data(
  mod : WasmModule,
  allow_split~ : Bool = true,
) -> WasmModule {
  if mod.datas.is_empty() {
    return mod
  }
  let imp_mems = imported_mem_count(mod)
  let has_refs = module_has_data_refs(mod)

  // Track seen active ranges per memory: None means dynamic/unknown offset (blocks trimming subsequent segments on that mem)
  let seen_ranges : Map[UInt32, Array[(UInt64, UInt64)?]] = Map([])
  let new_datas : Array[DataSegment] = []
  let mut changed = false

  for ds in mod.datas {
    // Passive segment (flags == 1): never alter
    if ds.flags == 1U || (ds.flags != 0U && ds.flags != 2U) {
      new_datas.push(ds)
      continue
    }
    let midx = if ds.flags == 0U { 0U } else { ds.mem_idx }
    let ranges = match seen_ranges.get(midx) {
      Some(r) => r
      None => {
        let r : Array[(UInt64, UInt64)?] = []
        seen_ranges[midx] = r
        r
      }
    }

    // Must target a module-defined memory (imported memory could be pre-populated with non-zero bytes)
    if midx < imp_mems {
      ranges.push(None)
      new_datas.push(ds)
      continue
    }
    let def_mem_i = (midx - imp_mems).reinterpret_as_int()
    if def_mem_i < 0 || def_mem_i >= mod.memories.length() {
      ranges.push(None)
      new_datas.push(ds)
      continue
    }
    let mem_lim = mod.memories[def_mem_i]

    match parse_const_mem_offset(ds.offset) {
      None => {
        ranges.push(None)
        new_datas.push(ds)
      }
      Some((is_i64, start)) => {
        let orig_len = ds.data.length()
        let orig_len_u64 = orig_len.to_uint64()
        let end = start + orig_len_u64
        let overflow = end < start || (!is_i64 && end > 0xFFFF_FFFFUL)
        // Only trim if proven strictly in-bounds of initial memory (preserves OOB instantiation traps)
        let max_safe_pages = 65536UL
        let proven_in_bounds = !overflow &&
          mem_lim.min <= max_safe_pages &&
          end <= mem_lim.min * 65536UL

        // Check overlap with any earlier active segment on the same memory
        let mut overlaps_earlier = false
        for prev in ranges {
          match prev {
            None => {
              overlaps_earlier = true
              break
            }
            Some((ps, pe)) =>
              if ps < end && start < pe {
                overlaps_earlier = true
                break
              }
          }
        }
        ranges.push(Some((start, end)))

        if !proven_in_bounds || overlaps_earlier {
          new_datas.push(ds)
          continue
        }

        // Trim leading and trailing zero bytes
        let mut lead = 0
        while lead < orig_len && ds.data[lead] == b'\x00' {
          lead += 1
        }
        let mut tail = orig_len
        while tail > lead && ds.data[tail - 1] == b'\x00' {
          tail -= 1
        }

        if lead >= tail {
          // Entire segment is zero bytes
          if !has_refs {
            changed = true
            continue
          } else if orig_len > 0 {
            changed = true
            new_datas.push({
              flags: ds.flags,
              mem_idx: ds.mem_idx,
              offset: ds.offset,
              data: b"",
            })
            continue
          } else {
            new_datas.push(ds)
            continue
          }
        }

        let trimmed_off = start + lead.to_uint64()
        let trimmed_data = if lead > 0 || tail < orig_len {
          slice_bytes(ds.data, lead, tail)
        } else {
          ds.data
        }
        let trimmed_seg : DataSegment = {
          flags: ds.flags,
          mem_idx: ds.mem_idx,
          offset: Some(make_const_mem_offset(is_i64, trimmed_off)),
          data: trimmed_data,
        }

        // Optionally split internal zero runs >= 16 bytes when no data segment indices are referenced
        if allow_split && !has_refs && trimmed_data.length() >= 32 {
          let split_segs = split_active_zero_runs(
            ds.flags,
            ds.mem_idx,
            is_i64,
            trimmed_off,
            trimmed_data,
            16,
          )
          if split_segs.length() > 1 {
            let unsplit_sz = encode_data_segment_size(trimmed_seg)
            let mut split_sz = 0
            for sp in split_segs {
              split_sz += encode_data_segment_size(sp)
            }
            if split_sz < unsplit_sz {
              changed = true
              for sp in split_segs {
                new_datas.push(sp)
              }
              continue
            }
          }
        }

        if lead > 0 || tail < orig_len {
          changed = true
          new_datas.push(trimmed_seg)
        } else {
          new_datas.push(ds)
        }
      }
    }
  }

  let new_has_dc = if !has_refs && mod.has_data_count {
    changed = true
    false
  } else {
    mod.has_data_count
  }

  if !changed {
    mod
  } else {
    { ..mod, datas: new_datas, has_data_count: new_has_dc, }
  }
}
