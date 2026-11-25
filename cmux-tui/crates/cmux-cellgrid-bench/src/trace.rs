//! The trace `scripts/record.py` writes: `CGTRACE1`, u16 cols, u16 rows, then
//! records of u64 t_ns, u8 kind (0 output, 1 key), u32 len and the bytes.

use std::io::{Error, ErrorKind, Result};

pub struct Record {
    pub t_ns: u64,
    pub key: bool,
    pub data: Vec<u8>,
}

pub struct Trace {
    pub cols: u16,
    pub rows: u16,
    pub records: Vec<Record>,
}

pub fn load(path: &str) -> Result<Trace> {
    let b = std::fs::read(path)?;
    let bad = |m: &str| Error::new(ErrorKind::InvalidData, format!("{path}: {m}"));
    if b.len() < 12 || &b[..8] != b"CGTRACE1" {
        return Err(bad("not a CGTRACE1 trace"));
    }
    let u16_at = |i: usize| u16::from_le_bytes([b[i], b[i + 1]]);
    let (cols, rows) = (u16_at(8), u16_at(10));
    let mut records = Vec::new();
    let mut i = 12;
    while i < b.len() {
        if i + 13 > b.len() {
            return Err(bad("truncated record header"));
        }
        let t_ns = u64::from_le_bytes(b[i..i + 8].try_into().map_err(|_| bad("header"))?);
        let key = b[i + 8] == 1;
        let len =
            u32::from_le_bytes(b[i + 9..i + 13].try_into().map_err(|_| bad("header"))?) as usize;
        i += 13;
        let data = b.get(i..i + len).ok_or_else(|| bad("truncated record"))?.to_vec();
        i += len;
        records.push(Record { t_ns, key, data });
    }
    Ok(Trace { cols, rows, records })
}
