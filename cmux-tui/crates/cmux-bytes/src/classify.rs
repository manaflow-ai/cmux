//! A file's content kind, from its name and first bytes.

/// What a file holds, as far as compression cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    /// Already compressed (an archive, an image, a video, a git pack): stored as is.
    Compressed,
    /// Source and text, grouped so a dictionary trained on one group helps the rest of it.
    Text(TextGroup),
    /// Anything else (executables, object files, databases): zstd if it shrinks.
    Binary,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum TextGroup {
    Script,
    Json,
    Native,
    Markup,
    Prose,
    Other,
}

const COMPRESSED_EXT: &[&str] = &[
    "gz", "tgz", "zip", "jar", "whl", "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "mp4",
    "mov", "m4v", "m4a", "mkv", "webm", "mp3", "aac", "ogg", "opus", "flac", "zst", "xz", "bz2",
    "7z", "rar", "br", "woff", "woff2", "pack", "lz4", "apk", "ipa", "nupkg", "crx", "xpi", "docx",
    "xlsx", "pptx", "odt", "epub", "dmg", "car", "jxl",
];

/// Magic numbers of compressed formats: (offset, bytes).
const MAGIC: &[(usize, &[u8])] = &[
    (0, &[0x1f, 0x8b]),                   // gzip
    (0, b"PK\x03\x04"),                   // zip family
    (0, &[0x89, b'P', b'N', b'G']),       // png
    (0, &[0xff, 0xd8, 0xff]),             // jpeg
    (0, b"GIF8"),                         // gif
    (0, &[0x28, 0xb5, 0x2f, 0xfd]),       // zstd
    (0, &[0xfd, b'7', b'z', b'X', b'Z']), // xz
    (0, b"BZh"),                          // bzip2
    (0, &[b'7', b'z', 0xbc, 0xaf]),       // 7z
    (0, b"Rar!"),                         // rar
    (8, b"WEBP"),                         // webp (RIFF....WEBP)
    (4, b"ftyp"),                         // mp4, mov, heic, avif
    (0, &[0x1a, 0x45, 0xdf, 0xa3]),       // matroska, webm
    (0, b"OggS"),                         // ogg
    (0, b"fLaC"),                         // flac
    (0, b"PACK"),                         // git pack
    (0, b"wOF2"),                         // woff2
    (0, b"wOFF"),                         // woff
    (0, &[0x04, 0x22, 0x4d, 0x18]),       // lz4 frame
];

/// The kind of a file named `name` whose content starts with `head`.
pub fn classify(name: &str, head: &[u8]) -> Kind {
    if MAGIC.iter().any(|(at, magic)| head.get(*at..at + magic.len()) == Some(magic)) {
        return Kind::Compressed;
    }
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    if COMPRESSED_EXT.contains(&ext.as_str()) {
        return Kind::Compressed;
    }
    let group = match ext.as_str() {
        "js" | "mjs" | "cjs" | "ts" | "tsx" | "jsx" | "py" | "rb" | "sh" | "lua" | "php" => {
            Some(TextGroup::Script)
        }
        "json" | "jsonl" | "lock" | "yaml" | "yml" | "toml" | "map" => Some(TextGroup::Json),
        "rs" | "c" | "h" | "cc" | "cpp" | "hpp" | "m" | "mm" | "swift" | "go" | "java" | "kt"
        | "zig" => Some(TextGroup::Native),
        "html" | "htm" | "css" | "scss" | "svg" | "xml" | "vue" | "svelte" => {
            Some(TextGroup::Markup)
        }
        "md" | "txt" | "rst" | "adoc" => Some(TextGroup::Prose),
        _ => None,
    };
    if let Some(group) = group {
        return Kind::Text(group);
    }
    if looks_text(head) { Kind::Text(TextGroup::Other) } else { Kind::Binary }
}

/// No NUL and mostly printable in the first bytes.
fn looks_text(head: &[u8]) -> bool {
    let head = head.get(..head.len().min(4096)).unwrap_or(head);
    if head.contains(&0) {
        return false;
    }
    let printable = head
        .iter()
        .filter(|b| b.is_ascii_graphic() || b.is_ascii_whitespace() || **b >= 0x80)
        .count();
    head.is_empty() || printable * 10 >= head.len() * 9
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_compressed_by_magic_even_with_a_text_name() {
        assert_eq!(classify("a.txt", &[0x1f, 0x8b, 8, 0]), Kind::Compressed);
        assert_eq!(classify("objects/pack/x.idx", b"PACK\0\0\0\x02"), Kind::Compressed);
        assert_eq!(classify("v", b"\0\0\0\x20ftypisom"), Kind::Compressed);
    }

    #[test]
    fn groups_text() {
        assert_eq!(classify("a.ts", b"export const"), Kind::Text(TextGroup::Script));
        assert_eq!(classify("Cargo.lock", b"[[package]]"), Kind::Text(TextGroup::Json));
        assert_eq!(classify("LICENSE", b"MIT License"), Kind::Text(TextGroup::Other));
        assert_eq!(classify("a.out", b"\x7fELF\x02\x01\x01\0"), Kind::Binary);
    }
}
