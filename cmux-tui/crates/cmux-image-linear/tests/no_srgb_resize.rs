//! The source detector for the class: no Rust in cmux-tui or Native scales an image with
//! the `image` crate or `fast_image_resize`, which average 8-bit sRGB code values (a black
//! and white checkerboard comes out 128, not 188). Downscale with `cmux_image_linear`.
//! A line that truly needs one (an upscale, a non-colour channel) says why with
//! `// gamma: allow <why>`, on that line or the one above.

use std::path::{Path, PathBuf};

const NEEDLES: [&str; 6] = [
    "imageops::",
    ".thumbnail(",
    ".thumbnail_exact(",
    ".resize_exact(",
    ".resize_to_fill(",
    "fast_image_resize",
];

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if name == "target" || name == "node_modules" || name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_image_is_scaled_in_srgb() {
    // affected-reads: cmux-tui Native
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let this = Path::new(file!()).file_name().unwrap();
    let mut files = Vec::new();
    for top in ["cmux-tui", "Native"] {
        rust_files(&root.join(top), &mut files);
    }
    assert!(!files.is_empty(), "no Rust found under {}", root.display());
    let mut found = Vec::new();
    for file in files {
        if file.file_name() == Some(this) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&file) else { continue };
        let lines: Vec<&str> = text.lines().collect();
        for (n, line) in lines.iter().enumerate() {
            let allowed = |l: &str| l.contains("gamma: allow");
            let above = n.checked_sub(1).and_then(|p| lines.get(p)).copied().unwrap_or("");
            if NEEDLES.iter().any(|needle| line.contains(needle))
                && !allowed(line)
                && !allowed(above)
            {
                found.push(format!("{}:{}: {}", file.display(), n + 1, line.trim()));
            }
        }
    }
    assert!(found.is_empty(), "scaled in sRGB; use cmux_image_linear:\n{}", found.join("\n"));
}
