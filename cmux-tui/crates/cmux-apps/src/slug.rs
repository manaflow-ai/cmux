//! App slugs: `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$` with no `--`, as the platform's hostname
//! `a-<slug>--<team8>` needs.

const MAX: usize = 40;

/// `name` lower-cased, every run of other characters one `-`, trimmed, at most 40 bytes.
/// `None` when nothing is left.
pub fn slugify(name: &str) -> Option<String> {
    unimplemented!("red: slugify")
}

/// Whether `slug` is already a valid slug.
pub fn is_slug(slug: &str) -> bool {
    slugify(slug).as_deref() == Some(slug)
}
