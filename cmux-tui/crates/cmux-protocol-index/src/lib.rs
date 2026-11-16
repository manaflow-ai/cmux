//! The wire protocol index (`docs/protocols/index.json`): every protocol two
//! codebases must agree on, with its owner, spec, version and the shared
//! vectors each side's tests read.
//!
//! [`check`] holds the index to the tree: every path exists, the version is
//! the one its source names, and a protocol listed as shared has tests in two
//! languages that each name its vectors. A protocol without that names its
//! gap. [`render`] writes the README a person reads; the crate's tests fail
//! when either drifts.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::Path;

use serde::Deserialize;

/// The index, relative to the repository root.
pub const INDEX_PATH: &str = "docs/protocols/index.json";
/// The README rendered from the index, relative to the repository root.
pub const README_PATH: &str = "docs/protocols/README.md";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Index {
    pub about: String,
    pub protocols: Vec<Protocol>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Protocol {
    pub name: String,
    /// The crate or package whose change moves the protocol.
    pub owner: String,
    pub spec: String,
    pub version: Version,
    /// Files or directories of vectors, relative to the repository root.
    pub vectors: Vec<String>,
    pub sides: Vec<Side>,
    /// Why fewer than two languages test against shared vectors.
    #[serde(default)]
    pub gap: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Version {
    pub value: String,
    /// The file that states the version, and the text in it that does.
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub contains: Option<String>,
    /// Why there is no version in the source (an unversioned protocol).
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Side {
    pub lang: String,
    pub test: String,
    /// Text the test file holds because it loads the vectors (their file
    /// name, or the constant it reads them through).
    #[serde(default)]
    pub reads: Option<String>,
    pub run: String,
    #[serde(default)]
    pub note: Option<String>,
}

/// What [`check`] reads of the tree, so a test can hand it a fake one.
pub trait Tree {
    /// Whether `path`, relative to the repository root, is a file or directory.
    fn exists(&self, path: &str) -> bool;
    /// The text of the file at `path`, or None when it cannot be read.
    fn read(&self, path: &str) -> Option<String>;
}

/// The checkout on disk, rooted at the repository root.
pub struct Disk<'a>(pub &'a Path);

impl Tree for Disk<'_> {
    fn exists(&self, path: &str) -> bool {
        self.0.join(path).exists()
    }

    fn read(&self, path: &str) -> Option<String> {
        std::fs::read_to_string(self.0.join(path)).ok()
    }
}

pub fn parse(text: &str) -> Result<Index, serde_json::Error> {
    serde_json::from_str(text)
}

impl Protocol {
    /// The languages whose tests name the shared vectors.
    pub fn tested_languages(&self) -> BTreeSet<&str> {
        if self.vectors.is_empty() {
            return BTreeSet::new();
        }
        self.sides
            .iter()
            .filter(|side| side.reads.is_some())
            .map(|side| side.lang.as_str())
            .collect()
    }

    /// Two languages test against the same vectors.
    pub fn is_shared(&self) -> bool {
        self.tested_languages().len() >= 2
    }
}

/// Every way the index disagrees with the tree, one line each; empty when it agrees.
pub fn check(index: &Index, tree: &impl Tree) -> Vec<String> {
    let mut problems = Vec::new();
    let mut names = BTreeSet::new();
    for protocol in &index.protocols {
        let name = protocol.name.as_str();
        if !names.insert(name) {
            problems.push(format!("{name}: listed twice"));
        }
        let mut must_exist = |what: &str, path: &str| {
            if !tree.exists(path) {
                problems.push(format!("{name}: {what} {path} does not exist"));
            }
        };
        must_exist("owner", &protocol.owner);
        must_exist("spec", &protocol.spec);
        for vectors in &protocol.vectors {
            must_exist("vectors", vectors);
        }
        for side in &protocol.sides {
            must_exist("test", &side.test);
        }
        check_version(name, &protocol.version, tree, &mut problems);
        for side in &protocol.sides {
            let Some(reads) = side.reads.as_deref() else { continue };
            if protocol.vectors.is_empty() {
                problems.push(format!(
                    "{name}: {} names `{reads}` but the protocol lists no vectors",
                    side.test
                ));
            } else if tree.read(&side.test).is_some_and(|text| !text.contains(reads)) {
                problems.push(format!(
                    "{name}: {} does not contain `{reads}`, so it does not read the vectors",
                    side.test
                ));
            }
        }
        match (protocol.is_shared(), protocol.gap.is_some()) {
            (true, true) => problems.push(format!("{name}: two languages test its vectors; drop the gap")),
            (false, false) => problems.push(format!(
                "{name}: fewer than two languages test shared vectors; add the other side's test or name the gap"
            )),
            _ => {}
        }
    }
    problems
}

fn check_version(name: &str, version: &Version, tree: &impl Tree, problems: &mut Vec<String>) {
    match (version.source.as_deref(), version.contains.as_deref()) {
        (Some(source), Some(contains)) => match tree.read(source) {
            Some(text) if text.contains(contains) => {}
            Some(_) => problems.push(format!(
                "{name}: {source} no longer contains `{contains}`; update version {} in the index",
                version.value
            )),
            None => problems.push(format!("{name}: version source {source} cannot be read")),
        },
        (None, None) if version.note.is_some() => {}
        (None, None) => {
            problems.push(format!("{name}: version {} names no source and no note", version.value))
        }
        _ => problems.push(format!("{name}: version needs both `source` and `contains`")),
    }
}

/// `docs/protocols/README.md`, written from the index.
pub fn render(index: &Index) -> String {
    let link = |path: &str| format!("[`{path}`](../../{path})");
    let mut out = String::new();
    out.push_str("# Wire protocols\n\n");
    out.push_str(
        "<!-- Generated from index.json by cmux-tui/crates/cmux-protocol-index. Edit index.json, then run\n\
         `UPDATE_PROTOCOL_INDEX=1 cargo test -p cmux-protocol-index` from cmux-tui/. -->\n\n",
    );
    out.push_str(&index.about);
    out.push_str("\n\n## Shared vectors, tested on both sides\n\n");
    out.push_str("| Protocol | Owner | Spec | Version | Vectors | Tests |\n");
    out.push_str("| --- | --- | --- | --- | --- | --- |\n");
    for protocol in index.protocols.iter().filter(|protocol| protocol.is_shared()) {
        let vectors: Vec<String> = protocol.vectors.iter().map(|path| link(path)).collect();
        let sides: Vec<String> = protocol
            .sides
            .iter()
            .map(|side| {
                let note =
                    side.note.as_deref().map(|note| format!(" ({note})")).unwrap_or_default();
                format!("{}: `{}`{note}", side.lang, side.run)
            })
            .collect();
        let _ = writeln!(
            out,
            "| {} | {} | {} | {} | {} | {} |",
            protocol.name,
            link(&protocol.owner),
            link(&protocol.spec),
            version_cell(&protocol.version),
            vectors.join("<br>"),
            sides.join("<br>"),
        );
    }
    out.push_str("\n## Not shared yet\n\n");
    out.push_str("| Protocol | Owner | Spec | Version | Gap |\n");
    out.push_str("| --- | --- | --- | --- | --- |\n");
    for protocol in index.protocols.iter().filter(|protocol| !protocol.is_shared()) {
        let _ = writeln!(
            out,
            "| {} | {} | {} | {} | {} |",
            protocol.name,
            link(&protocol.owner),
            link(&protocol.spec),
            version_cell(&protocol.version),
            protocol.gap.as_deref().unwrap_or_default(),
        );
    }
    out.push_str(
        "\n## Adding a protocol\n\n\
         Add an entry to `index.json`: its owner, spec, version (the file and text that state it) and its vectors.\n\
         A shared protocol lists a test in each language with the text (`reads`) that shows the test loads the\n\
         vectors; one that is not shared yet names its gap. `cargo test -p cmux-protocol-index` fails when a path,\n\
         a version or a test's read of the vectors drifts from the tree.\n",
    );
    out
}

fn version_cell(version: &Version) -> String {
    match &version.note {
        Some(note) => format!("{} ({note})", version.value),
        None => version.value.clone(),
    }
}

#[cfg(test)]
mod tests;
