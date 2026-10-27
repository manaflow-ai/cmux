//! The baked release keys (server.md 4.2 step 2: current and next;
//! decision SV-R1).
//!
//! Release CI sets `CMUX_SERVER_RELEASE_KEYS` at build time to
//! `<id>:<64 hex public key>[,<id>:<hex>]` (the repository variable of the
//! same name). The value is compiled in with `option_env!`; nothing reads it
//! from the runtime environment, so a process environment cannot widen
//! trust. A build without it has no keys and refuses every manifest
//! (exit 7). A malformed value fails the build, so a release never ships
//! with a key silently dropped.

use cmux_server_core::manifest::TrustedKey;

/// The build-time spec; empty when the build had none.
const BAKED_SPEC: &str = match option_env!("CMUX_SERVER_RELEASE_KEYS") {
    Some(spec) => spec,
    None => "",
};

// Checked by the compiler: a malformed build-time spec is a build error.
const _: () = if let Some(reason) = check(BAKED_SPEC) {
    // crash-allow: const evaluation only; a malformed build-time key spec is a compile error, never a runtime panic.
    panic!("{}", reason);
};

const BAD_ENTRY: &str = "CMUX_SERVER_RELEASE_KEYS entry is not <id>:<64 hex>";

/// Parses `<id>:<hex>[,…]`. Ids are `[A-Za-z0-9._-]+` and unique; keys are
/// 64 hex digits. Whitespace around an entry is ignored; an empty spec is
/// no keys. Any malformed entry rejects the whole spec.
pub fn parse(spec: &str) -> Result<Vec<TrustedKey>, &'static str> {
    if let Some(reason) = check(spec) {
        return Err(reason);
    }
    if spec.trim().is_empty() {
        return Ok(Vec::new());
    }
    spec.split(',')
        .map(|entry| {
            let (id, hex) = entry.trim().split_once(':').ok_or(BAD_ENTRY)?;
            let mut public_key = [0u8; 32];
            for (byte, pair) in public_key.iter_mut().zip(hex.as_bytes().chunks_exact(2)) {
                let &[hi, lo] = pair else { return Err(BAD_ENTRY) };
                let (Some(hi), Some(lo)) = (nibble(hi), nibble(lo)) else {
                    return Err(BAD_ENTRY);
                };
                *byte = (hi << 4) | lo;
            }
            Ok(TrustedKey { id: id.to_owned(), public_key })
        })
        .collect()
}

/// The keys baked into this build.
pub fn baked() -> Vec<TrustedKey> {
    // The compiler already rejected a malformed spec; an error here can
    // only trust nothing (fail closed).
    parse(BAKED_SPEC).unwrap_or_default()
}

const fn nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

const fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

const fn is_id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')
}

/// `bytes` without leading and trailing whitespace.
const fn trim(mut bytes: &[u8]) -> &[u8] {
    while let [first, rest @ ..] = bytes
        && is_space(*first)
    {
        bytes = rest;
    }
    while let [rest @ .., last] = bytes
        && is_space(*last)
    {
        bytes = rest;
    }
    bytes
}

/// The bytes before the first `separator` and the bytes after it.
const fn split_once(bytes: &[u8], separator: u8) -> Option<(&[u8], &[u8])> {
    let mut rest = bytes;
    let mut at = 0;
    while let [first, tail @ ..] = rest {
        if *first == separator {
            return match bytes.split_at_checked(at) {
                Some((head, _)) => Some((head, tail)),
                None => None,
            };
        }
        rest = tail;
        at += 1;
    }
    None
}

/// One entry of a spec and the spec after its comma (`None` after the last).
const fn next_entry(spec: &[u8]) -> (&[u8], Option<&[u8]>) {
    match split_once(spec, b',') {
        Some((entry, rest)) => (entry, Some(rest)),
        None => (spec, None),
    }
}

const fn same(mut a: &[u8], mut b: &[u8]) -> bool {
    loop {
        match (a, b) {
            ([], []) => return true,
            ([x, a_rest @ ..], [y, b_rest @ ..]) if *x == *y => {
                a = a_rest;
                b = b_rest;
            }
            _ => return false,
        }
    }
}

/// The id of a trimmed entry, or why the entry is malformed.
const fn check_entry(entry: &[u8]) -> Result<&[u8], &'static str> {
    if entry.is_empty() {
        return Err("CMUX_SERVER_RELEASE_KEYS has an empty entry");
    }
    let Some((id, key)) = split_once(entry, b':') else {
        return Err(BAD_ENTRY);
    };
    if id.is_empty() {
        return Err("CMUX_SERVER_RELEASE_KEYS entry has an empty id");
    }
    let mut rest = id;
    while let [first, tail @ ..] = rest {
        if !is_id_byte(*first) {
            return Err("CMUX_SERVER_RELEASE_KEYS id is not [A-Za-z0-9._-]+");
        }
        rest = tail;
    }
    if key.len() != 64 {
        return Err("CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits");
    }
    rest = key;
    while let [first, tail @ ..] = rest {
        if nibble(*first).is_none() {
            return Err("CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits");
        }
        rest = tail;
    }
    Ok(id)
}

/// Whether a valid entry of `earlier` (entries each ended by a comma) has
/// the id `id`.
const fn has_id(mut earlier: &[u8], id: &[u8]) -> bool {
    while let Some((entry, rest)) = split_once(earlier, b',') {
        if let Some((other, _)) = split_once(trim(entry), b':')
            && same(other, id)
        {
            return true;
        }
        earlier = rest;
    }
    false
}

/// `None` when `spec` is valid, else why not. `const` so the build-time
/// value is checked by the compiler with the same rules [`parse`] uses.
const fn check(spec: &str) -> Option<&'static str> {
    let spec = spec.as_bytes();
    if trim(spec).is_empty() {
        return None;
    }
    let mut rest = spec;
    loop {
        let (entry, next) = next_entry(rest);
        let id = match check_entry(trim(entry)) {
            Ok(id) => id,
            Err(reason) => return Some(reason),
        };
        // Ids are unique: compare with every earlier entry.
        if let Some((earlier, _)) = spec.split_at_checked(spec.len() - rest.len())
            && has_id(earlier, id)
        {
            return Some("CMUX_SERVER_RELEASE_KEYS repeats a key id");
        }
        match next {
            Some(after) => rest = after,
            None => return None,
        }
    }
}
