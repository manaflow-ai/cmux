//! The identity of a problem: FNV-1a 64 over its source, message template and top frame.

/// 16 lowercase hex digits of FNV-1a 64 over `source \u{1f} template \u{1f} top_frame`.
pub fn fingerprint(source: &str, template: &str, top_frame: Option<&str>) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let text = format!("{source}\u{1f}{template}\u{1f}{}", top_frame.unwrap_or(""));
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}
