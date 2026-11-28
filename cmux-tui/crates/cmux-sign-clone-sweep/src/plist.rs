//! Reads one string of an `Info.plist`'s top-level dictionary, XML or binary
//! (`bplist00`). Enough for `CFBundleIdentifier` and `CFBundleExecutable`; no
//! dependency, every read bounds-checked, nothing panics on any input. Only the
//! top-level dictionary answers, in both forms.

/// The string value of `key` in the plist `data`'s top-level dictionary.
pub fn plist_string(data: &[u8], key: &str) -> Option<String> {
    if data.starts_with(b"bplist00") {
        return binary_string(data, key);
    }
    xml_string(std::str::from_utf8(data).ok()?, key)
}

/// One XML token: an element's start, end or empty form (by name), or text.
#[derive(Debug, PartialEq, Eq)]
enum Token<'a> {
    Open(&'a str),
    Close(&'a str),
    Empty(&'a str),
    Text(&'a str),
}

/// The document's tokens, without the XML declaration, a DOCTYPE, comments and
/// whitespace-only text; `None` when it is not well formed enough to read.
fn tokens(mut rest: &str) -> Option<Vec<Token<'_>>> {
    let mut found = Vec::new();
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix("<!--") {
            rest = after.split_once("-->")?.1;
        } else if let Some(after) = rest.strip_prefix("<?") {
            rest = after.split_once("?>")?.1;
        } else if let Some(after) = rest.strip_prefix("<!") {
            let (inside, next) = after.split_once('>')?;
            // An internal DTD subset could define entities: not an Info.plist.
            if inside.contains('[') {
                return None;
            }
            rest = next;
        } else if let Some(after) = rest.strip_prefix("</") {
            let (name, next) = after.split_once('>')?;
            found.push(Token::Close(name.trim()));
            rest = next;
        } else if let Some(after) = rest.strip_prefix('<') {
            let (inside, next) = after.split_once('>')?;
            let (inside, empty) = match inside.strip_suffix('/') {
                Some(inside) => (inside, true),
                None => (inside, false),
            };
            let name = inside.split_whitespace().next()?;
            found.push(if empty { Token::Empty(name) } else { Token::Open(name) });
            rest = next;
        } else {
            let end = rest.find('<').unwrap_or(rest.len());
            let (text, next) = rest.split_at(end);
            if !text.trim().is_empty() {
                found.push(Token::Text(text));
            }
            rest = next;
        }
    }
    Some(found)
}

/// Text with the five predefined entities decoded; `None` for any other `&`.
fn unescape(text: &str) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some((before, after)) = rest.split_once('&') {
        out.push_str(before);
        let (entity, next) = after.split_once(';')?;
        out.push(match entity {
            "amp" => '&',
            "lt" => '<',
            "gt" => '>',
            "quot" => '"',
            "apos" => '\'',
            _ => return None,
        });
        rest = next;
    }
    out.push_str(rest);
    Some(out)
}

/// Text up to the end of `name`: `Some("")` when there is none.
fn text_until<'a>(tokens: &mut impl Iterator<Item = Token<'a>>, name: &str) -> Option<&'a str> {
    match tokens.next()? {
        Token::Close(close) if close == name => Some(""),
        Token::Text(text) => match tokens.next()? {
            Token::Close(close) if close == name => Some(text),
            _ => None,
        },
        _ => None,
    }
}

/// One value after a key: `Some(Some(text))` for a string, `Some(None)` for
/// any other well-formed value (skipped whole, nested ones included).
fn value<'a>(tokens: &mut impl Iterator<Item = Token<'a>>) -> Option<Option<String>> {
    match tokens.next()? {
        Token::Open("string") => Some(Some(unescape(text_until(tokens, "string")?.trim())?)),
        Token::Empty("string") => Some(Some(String::new())),
        Token::Empty(_) => Some(None),
        Token::Open(name) => {
            let mut open = vec![name];
            while let Some(top) = open.last().copied() {
                match tokens.next()? {
                    Token::Open(inner) => open.push(inner),
                    Token::Close(close) if close == top => {
                        open.pop();
                    }
                    Token::Close(_) => return None,
                    Token::Empty(_) | Token::Text(_) => {}
                }
            }
            Some(None)
        }
        _ => None,
    }
}

/// The XML reader: `<plist>` holding one `<dict>`, read key by key at the top
/// level only, so a key in a nested dictionary, an array or a comment never
/// answers. A malformed document or a key given twice answers `None`.
fn xml_string(text: &str, key: &str) -> Option<String> {
    let mut tokens = tokens(text)?.into_iter();
    if tokens.next()? != Token::Open("plist") || tokens.next()? != Token::Open("dict") {
        return None;
    }
    let mut found: Option<Option<String>> = None;
    loop {
        match tokens.next()? {
            Token::Close("dict") => break,
            Token::Open("key") => {
                let name = text_until(&mut tokens, "key")?;
                let item = value(&mut tokens)?;
                if unescape(name.trim())? == key {
                    if found.is_some() {
                        return None;
                    }
                    found = Some(item);
                }
            }
            _ => return None,
        }
    }
    if tokens.next()? != Token::Close("plist") || tokens.next().is_some() {
        return None;
    }
    found.flatten()
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
    let offset_size = usize::from(*data.get(trailer.checked_add(6)?)?);
    let ref_size = usize::from(*data.get(trailer.checked_add(7)?)?);
    let objects = read_usize(data, trailer.checked_add(8)?, 8)?;
    let top = read_usize(data, trailer.checked_add(16)?, 8)?;
    let table = read_usize(data, trailer.checked_add(24)?, 8)?;
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
