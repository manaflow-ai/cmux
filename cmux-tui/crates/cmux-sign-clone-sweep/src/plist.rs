//! Reads one string of an `Info.plist`'s top-level dictionary, XML or binary
//! (`bplist00`). Enough for `CFBundleIdentifier` and `CFBundleExecutable`; no
//! dependency, every read bounds-checked, nothing panics on any input.

/// The string value of `key` in the plist `data`'s top-level dictionary.
pub fn plist_string(data: &[u8], key: &str) -> Option<String> {
    if data.starts_with(b"bplist00") {
        return binary_string(data, key);
    }
    let text = std::str::from_utf8(data).ok()?;
    let (_, after_key) = text.split_once(&format!("<key>{key}</key>"))?;
    let value = after_key.trim_start().strip_prefix("<string>")?;
    let (value, _) = value.split_once("</string>")?;
    Some(value.trim().to_owned())
}

/// A big-endian unsigned integer of `size` bytes at `offset`.
fn read_uint(data: &[u8], offset: usize, size: usize) -> Option<u64> {
    if size == 0 || size > 8 {
        return None;
    }
    let bytes = data.get(offset..offset.checked_add(size)?)?;
    Some(bytes.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
}

/// A big-endian unsigned integer as a `usize`.
fn read_usize(data: &[u8], offset: usize, size: usize) -> Option<usize> {
    usize::try_from(read_uint(data, offset, size)?).ok()
}

/// The binary plist reader: the trailer, the offset table, the top dictionary.
fn binary_string(data: &[u8], key: &str) -> Option<String> {
    let trailer = data.len().checked_sub(32)?;
    let offset_size = usize::from(*data.get(trailer + 6)?);
    let ref_size = usize::from(*data.get(trailer + 7)?);
    let objects = read_usize(data, trailer + 8, 8)?;
    let top = read_usize(data, trailer + 16, 8)?;
    let table = read_usize(data, trailer + 24, 8)?;
    let object_offset = |index: usize| -> Option<usize> {
        if index >= objects {
            return None;
        }
        read_usize(data, table.checked_add(index.checked_mul(offset_size)?)?, offset_size)
    };
    // A marker's count: its low nibble, or the integer object after it when 0xF.
    let count = |at: usize| -> Option<(usize, usize)> {
        let marker = *data.get(at)?;
        if marker & 0x0F != 0x0F {
            return Some((usize::from(marker & 0x0F), at.checked_add(1)?));
        }
        let int_marker = *data.get(at.checked_add(1)?)?;
        if int_marker >> 4 != 0x1 || int_marker & 0x0F > 3 {
            return None;
        }
        let size = 1usize << (int_marker & 0x0F);
        let start = at.checked_add(2)?;
        Some((read_usize(data, start, size)?, start.checked_add(size)?))
    };
    let string_at = |index: usize| -> Option<String> {
        let at = object_offset(index)?;
        let marker = *data.get(at)?;
        let (len, start) = count(at)?;
        match marker >> 4 {
            0x5 => {
                let bytes = data.get(start..start.checked_add(len)?)?;
                std::str::from_utf8(bytes).ok().map(str::to_owned)
            }
            0x6 => {
                let bytes = data.get(start..start.checked_add(len.checked_mul(2)?)?)?;
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|pair| match pair {
                        [high, low] => u16::from_be_bytes([*high, *low]),
                        _ => 0,
                    })
                    .collect();
                String::from_utf16(&units).ok()
            }
            _ => None,
        }
    };
    let dict = object_offset(top)?;
    if *data.get(dict)? >> 4 != 0xD {
        return None;
    }
    let (entries, keys) = count(dict)?;
    let values = keys.checked_add(entries.checked_mul(ref_size)?)?;
    for i in 0..entries {
        let at = i.checked_mul(ref_size)?;
        let key_ref = read_usize(data, keys.checked_add(at)?, ref_size)?;
        if string_at(key_ref).as_deref() == Some(key) {
            return string_at(read_usize(data, values.checked_add(at)?, ref_size)?);
        }
    }
    None
}
