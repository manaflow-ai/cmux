//! `cmux ext new NAME`: a working extension folder from templates embedded
//! in the binary (manifest v2, `src/main.ts`, its built `dist/main.js`, a
//! README with the loop, and the API types). It passes `cmux ext dev --once`
//! as written (`ext::tests`).

use std::path::{Path, PathBuf};

/// The kinds `--kind` takes. `widget` (the new tab page's
/// `cmux.newtab.widget/1`) joins once the validator knows that interface.
pub(super) const KINDS: &[&str] = &["section"];

const SECTION: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/section/cmux-app.json")),
    ("src/main.ts", include_str!("templates/section/src/main.ts")),
    ("dist/main.js", include_str!("templates/section/dist/main.js")),
    ("README.md", include_str!("templates/section/README.md")),
];

/// The types `src/main.ts` references: the generated app global, the same
/// file `cmux script types` starts with.
const TYPES: &str = include_str!("../../../../cmux-app-host/generated/cmux-app.d.ts");

/// Whether `name` makes a valid id `local/<name>` (the manifest schema's
/// name part) other than the customize folder's.
pub(super) fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    let first_ok = chars.next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    first_ok
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && name != "customize"
}

/// `my-prs` -> `My prs`.
fn title(name: &str) -> String {
    let words = name.replace('-', " ");
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

/// The files of a new `kind` extension called `name`, by relative path.
pub(super) fn files(name: &str, kind: &str) -> Option<Vec<(&'static str, String)>> {
    let templates = match kind {
        "section" => SECTION,
        _ => return None,
    };
    let title = title(name);
    let mut out: Vec<(&'static str, String)> = templates
        .iter()
        .map(|(path, text)| (*path, text.replace("{{NAME}}", name).replace("{{TITLE}}", &title)))
        .collect();
    out.push(("cmux-app.d.ts", TYPES.to_string()));
    Some(out)
}

/// Writes a new extension into `dir`, which must not exist yet (or be
/// empty); returns the files written.
pub(super) fn scaffold(dir: &Path, name: &str, kind: &str) -> Result<Vec<PathBuf>, String> {
    let files = files(name, kind).ok_or_else(|| {
        format!("--kind {kind} is not one cmux ext new makes; it makes {}", KINDS.join(", "))
    })?;
    if std::fs::read_dir(dir).is_ok_and(|mut entries| entries.next().is_some()) {
        return Err(format!("{} already exists and is not empty", dir.display()));
    }
    let mut written = Vec::new();
    for (rel, text) in files {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        std::fs::write(&path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        written.push(path);
    }
    Ok(written)
}
