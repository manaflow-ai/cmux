//! The order a folder's files fill in the background: what an agent reads
//! first goes first. The manifest always leads; faulted reads jump the queue
//! ([`crate::lanes`]); this orders the rest.

/// A file the fill will send.
#[derive(Clone, Debug)]
pub struct Entry {
    pub path: String,
    pub size: u64,
    /// Seconds since the file was last modified, when known.
    pub age_secs: Option<u64>,
}

/// Lower is hotter.
pub fn heat(e: &Entry) -> u32 {
    let p = e.path.as_str();
    let name = p.rsplit('/').next().unwrap_or(p);
    let depth = p.matches('/').count() as u32;
    // What an agent opens on its first turn: the instructions, the manifests, the readme.
    const FIRST: &[&str] = &[
        "AGENTS.md",
        "CLAUDE.md",
        "README.md",
        "package.json",
        "Cargo.toml",
        "pyproject.toml",
        "go.mod",
        "Makefile",
        "tsconfig.json",
        ".gitignore",
        "Package.swift",
    ];
    if FIRST.contains(&name) {
        return depth.min(3);
    }
    let cold_dir = [
        "node_modules/",
        "target/",
        "dist/",
        "build/",
        ".git/objects/",
        "vendor/",
        ".next/",
        "DerivedData/",
    ]
    .iter()
    .any(|d| p.starts_with(d) || p.contains(&format!("/{d}")));
    let mut h = 10 + depth * 2;
    if cold_dir {
        h += 1000;
    }
    match e.age_secs {
        Some(a) if a < 3600 => h = h.saturating_sub(8),
        Some(a) if a < 86_400 * 7 => h = h.saturating_sub(4),
        _ => {}
    }
    // Big files later: a 200 MB asset should not hold up a thousand source files.
    h + (64 - e.size.max(1).leading_zeros()).saturating_sub(14) * 5
}

/// `entries` sorted hottest first, path as the tie-break so the order is stable.
pub fn fill_order(entries: &mut [Entry]) {
    entries.sort_by(|a, b| heat(a).cmp(&heat(b)).then_with(|| a.path.cmp(&b.path)));
}

#[cfg(test)]
#[path = "order_tests.rs"]
mod tests;
