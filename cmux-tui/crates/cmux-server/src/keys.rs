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
    const BAD: &str = "CMUX_SERVER_RELEASE_KEYS entry is not <id>:<64 hex>";
    spec.split(',')
        .map(|entry| {
            let (id, hex) = entry.trim().split_once(':').ok_or(BAD)?;
            let mut public_key = [0u8; 32];
            for (i, pair) in hex.as_bytes().chunks(2).enumerate() {
                let (Some(hi), Some(lo)) = (nibble(pair[0]), nibble(pair[1])) else {
                    return Err(BAD);
                };
                public_key[i] = (hi << 4) | lo;
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

/// One entry of `spec` that starts at `start`: the trimmed `[begin, end)`
/// and the index after its comma (`spec.len() + 1` after the last entry).
const fn entry(spec: &[u8], start: usize) -> (usize, usize, usize) {
    let mut stop = start;
    while stop < spec.len() && spec[stop] != b',' {
        stop += 1;
    }
    let (mut begin, mut end) = (start, stop);
    while begin < end && is_space(spec[begin]) {
        begin += 1;
    }
    while end > begin && is_space(spec[end - 1]) {
        end -= 1;
    }
    (begin, end, stop + 1)
}

/// The first `:` in `[begin, end)`.
const fn colon(spec: &[u8], begin: usize, end: usize) -> Option<usize> {
    let mut i = begin;
    while i < end {
        if spec[i] == b':' {
            return Some(i);
        }
        i += 1;
    }
    None
}

const fn same(spec: &[u8], a: usize, a_end: usize, b: usize, b_end: usize) -> bool {
    if a_end - a != b_end - b {
        return false;
    }
    let mut i = 0;
    while i < a_end - a {
        if spec[a + i] != spec[b + i] {
            return false;
        }
        i += 1;
    }
    true
}

/// `None` when `spec` is valid, else why not. `const` so the build-time
/// value is checked by the compiler with the same rules [`parse`] uses.
const fn check(spec: &str) -> Option<&'static str> {
    let spec = spec.as_bytes();
    let mut only_space = true;
    let mut i = 0;
    while i < spec.len() {
        if !is_space(spec[i]) {
            only_space = false;
        }
        i += 1;
    }
    if only_space {
        return None;
    }
    let mut start = 0;
    while start <= spec.len() {
        let (begin, end, next) = entry(spec, start);
        if begin == end {
            return Some("CMUX_SERVER_RELEASE_KEYS has an empty entry");
        }
        let Some(sep) = colon(spec, begin, end) else {
            return Some("CMUX_SERVER_RELEASE_KEYS entry is not <id>:<64 hex>");
        };
        if sep == begin {
            return Some("CMUX_SERVER_RELEASE_KEYS entry has an empty id");
        }
        let mut j = begin;
        while j < sep {
            if !is_id_byte(spec[j]) {
                return Some("CMUX_SERVER_RELEASE_KEYS id is not [A-Za-z0-9._-]+");
            }
            j += 1;
        }
        if end - sep - 1 != 64 {
            return Some("CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits");
        }
        j = sep + 1;
        while j < end {
            if nibble(spec[j]).is_none() {
                return Some("CMUX_SERVER_RELEASE_KEYS key is not 64 hex digits");
            }
            j += 1;
        }
        // Ids are unique: compare with every earlier entry.
        let mut earlier = 0;
        while earlier < start {
            let (b, e, n) = entry(spec, earlier);
            if let Some(c) = colon(spec, b, e)
                && same(spec, b, c, begin, sep)
            {
                return Some("CMUX_SERVER_RELEASE_KEYS repeats a key id");
            }
            earlier = n;
        }
        start = next;
    }
    None
}
