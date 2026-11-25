//! App slugs: `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` with no `--`, as the platform's hostname
//! `a-<slug>--<team8>` needs.

const MAX: usize = 40;

/// `name` lower-cased, every run of other characters one `-`, trimmed, at most 40 bytes.
/// `None` when nothing is left.
pub fn slugify(name: &str) -> Option<String> {
    let mut out = String::new();
    for c in name.chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.truncate(MAX);
    let out = out.trim_end_matches('-').to_owned();
    (!out.is_empty()).then_some(out)
}

/// Whether `slug` is already a valid slug.
pub fn is_slug(slug: &str) -> bool {
    slugify(slug).as_deref() == Some(slug)
}
