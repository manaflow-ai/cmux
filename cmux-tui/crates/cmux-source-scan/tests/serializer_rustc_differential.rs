//! The test-hooks check's serializer verdict, judged against rustc (review of cmux#41813: "Make
//! that a standing differential test: a generated corpus of import and rebinding shapes, each
//! built with rustc (E0308 or ok) and compared with the scanner's verdict. Every disagreement
//! fails.").
//!
//! Each shape is a small crate whose `static HOOK_TEST` a `test-hook-allow: serialized by
//! HOOK_TEST` marker names. Its slots (`@X@`, `@Y@`) take `Mutex` and `RwLock` in every
//! combination, so each shape is built once per way its names can resolve. For each crate:
//!   - rustc type-checks `let _: &::std::sync::Mutex<()> = &HOOK_TEST;`, written beside the
//!     static: it compiles when HOOK_TEST is a `Mutex<()>` and fails with E0308 when it is not
//!     (any other error is a broken shape, and fails);
//!   - the check judges the crate's tree (`judge_tree`), and takes HOOK_TEST as a serializer when
//!     it names no "no `static HOOK_TEST: Mutex<()>`" finding.
//!
//! Accepting a HOOK_TEST rustc says is no `Mutex<()>` always fails. Refusing one rustc says is a
//! `Mutex<()>` fails too, unless the shape says why the check refuses it by design (a name the
//! file binds two ways is a serializer only when every way is; another file's type is unresolved),
//! and a shape that says so must show it in at least one of its crates.
//!
//! It needs rustc, which every `cargo test` has: `$RUSTC`, else `rustc` on the PATH.

use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_source_scan::test_hooks::judge_tree;

const SLOTS: [&str; 2] = ["@X@", "@Y@"];
const CELLS: [&str; 2] = ["Mutex", "RwLock"];
const HOOK: &str = "// test-hook-allow: serialized by HOOK_TEST, which every test that sets it holds\n\
static SWAP_HOOK: ::std::sync::Mutex<Option<fn()>> = ::std::sync::Mutex::new(None);\n";
const CHECK: &str = "let _: &::std::sync::Mutex<()> = &HOOK_TEST;";
const REFUSED: &str = "no `static HOOK_TEST: Mutex<()>`";
/// The reason the check refuses a serializer whose name the file binds two ways.
const TWO_WAYS: &str = "the file binds `Lock` two ways, and a name bound two ways serializes only \
                        when every way does (reviews of cmux#41693 F1 and cmux#41707 F1)";
/// The reason the check refuses a serializer whose type sits in another file.
const OTHER_FILE: &str = "the type is another file's, which the check does not read";

struct Shape {
    name: &'static str,
    /// The review finding it comes from.
    from: &'static str,
    /// The crate's files, from its folder: `src/lib.rs` first. `@HOOK@` is the marked hook,
    /// `@CHECK@` the type check, `@X@` and `@Y@` the slots.
    files: &'static [(&'static str, &'static str)],
    /// Why the check refuses some HOOK_TEST rustc takes as a `Mutex<()>`, or None.
    may_refuse_valid: Option<&'static str>,
}

const SHAPES: &[Shape] = &[
    Shape {
        name: "absolute_import_skips_a_body_binding",
        from: "cmux#41813 F1",
        files: &[(
            "src/lib.rs",
            "extern crate std as abs;
mod mutexes {
    pub mod sync {
        pub type RwLock = std::sync::@X@<()>;
    }
}
@HOOK@
mod tests {
    fn local() {
        use super::mutexes as abs;
        use ::abs::sync::RwLock;
        static HOOK_TEST: RwLock<()> = RwLock::new(());
        @CHECK@
    }
}
",
        )],
        may_refuse_valid: None,
    },
    Shape {
        name: "absolute_type_path_skips_a_module_binding",
        from: "cmux#41813 F1 (the static's own type)",
        files: &[(
            "src/lib.rs",
            "mod fake {
    pub mod sync {
        pub type Mutex<T> = std::sync::@X@<T>;
    }
}
use self::fake as std;
@HOOK@
static HOOK_TEST: ::std::sync::Mutex<()> = ::std::sync::Mutex::new(());
fn check() {
    @CHECK@
}
",
        )],
        may_refuse_valid: None,
    },
    Shape {
        name: "body_import_of_its_own_name",
        from: "cmux#41813 F2",
        files: &[(
            "src/lib.rs",
            "type Lock = std::sync::@X@<()>;
@HOOK@
fn local() {
    use Lock;
    static HOOK_TEST: Lock = Lock::new(());
    @CHECK@
}
",
        )],
        may_refuse_valid: None,
    },
    Shape {
        name: "crate_import_beside_an_own_definition",
        from: "cmux#41728 F1",
        files: &[
            ("src/lib.rs", "mod other;\nmod watches;\n"),
            ("src/other.rs", "pub type Lock = std::sync::@Y@<()>;\n"),
            (
                "src/watches.rs",
                "type Lock = std::sync::@X@<()>;
@HOOK@
mod tests {
    use crate::other::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
}
",
            ),
        ],
        may_refuse_valid: Some(OTHER_FILE),
    },
    Shape {
        name: "crate_import_of_the_own_definition",
        from: "cmux#41728 F1",
        files: &[
            ("src/lib.rs", "mod watches;\n"),
            (
                "src/watches.rs",
                "type Lock = std::sync::@X@<()>;
@HOOK@
mod tests {
    use crate::watches::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
}
",
            ),
        ],
        may_refuse_valid: None,
    },
    Shape {
        name: "bare_import_through_a_glob",
        from: "cmux#41754 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
@HOOK@
mod tests {
    use super::*;
    use helpers::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
}
",
        )],
        may_refuse_valid: None,
    },
    Shape {
        name: "own_module_shadows_the_glob",
        from: "cmux#41754 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
@HOOK@
mod tests {
    use super::*;
    mod helpers {
        pub type Lock = std::sync::@Y@<()>;
    }
    use helpers::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
}
",
        )],
        may_refuse_valid: Some(TWO_WAYS),
    },
    Shape {
        name: "chained_path_modules",
        from: "cmux#41761 F1",
        files: &[
            ("src/lib.rs", "#[path = \"actual.rs\"]\nmod model;\n"),
            ("src/actual.rs", "#[path = \"leaf.rs\"]\npub mod child;\n"),
            (
                "src/leaf.rs",
                "type Lock = std::sync::@X@<()>;
@HOOK@
mod tests {
    use crate::model::child::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
}
",
            ),
        ],
        may_refuse_valid: None,
    },
    Shape {
        name: "block_local_import_is_no_module_name",
        from: "cmux#41769 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
@HOOK@
mod tests {
    use super::*;
    use helpers::Lock;
    static HOOK_TEST: Lock = Lock::new(());
    fn check() {
        @CHECK@
    }
    fn local() {
        use super::helpers as helpers;
    }
}
",
        )],
        may_refuse_valid: None,
    },
    Shape {
        name: "body_rebinding_to_another_file",
        from: "cmux#41792 F1",
        files: &[
            ("src/lib.rs", "mod other;\nmod watches;\n"),
            ("src/other.rs", "pub mod helpers {\n    pub type Lock = std::sync::@Y@<()>;\n}\n"),
            (
                "src/watches.rs",
                "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
@HOOK@
mod tests {
    use super::*;
    fn local() {
        use crate::other::helpers as helpers;
        use helpers::Lock;
        static HOOK_TEST: Lock = Lock::new(());
        @CHECK@
    }
}
",
            ),
        ],
        may_refuse_valid: Some(OTHER_FILE),
    },
    Shape {
        name: "body_rebinding_in_the_file",
        from: "cmux#41792 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
mod mutexes {
    pub type Lock = std::sync::@Y@<()>;
}
@HOOK@
mod tests {
    use super::*;
    fn local() {
        use super::mutexes as helpers;
        use helpers::Lock;
        static HOOK_TEST: Lock = Lock::new(());
        @CHECK@
    }
}
",
        )],
        may_refuse_valid: Some(TWO_WAYS),
    },
    Shape {
        name: "body_rebinding_written_after_its_use",
        from: "cmux#41792 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
mod mutexes {
    pub type Lock = std::sync::@Y@<()>;
}
@HOOK@
mod tests {
    use super::*;
    fn local() {
        use helpers::Lock;
        use super::mutexes as helpers;
        static HOOK_TEST: Lock = Lock::new(());
        @CHECK@
    }
}
",
        )],
        may_refuse_valid: Some(TWO_WAYS),
    },
    Shape {
        name: "body_rebinding_reaches_an_inner_block",
        from: "cmux#41792 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
mod mutexes {
    pub type Lock = std::sync::@Y@<()>;
}
@HOOK@
mod tests {
    use super::*;
    fn local() {
        use super::mutexes as helpers;
        {
            use helpers::Lock;
            static HOOK_TEST: Lock = Lock::new(());
            @CHECK@
        }
    }
}
",
        )],
        may_refuse_valid: Some(TWO_WAYS),
    },
    Shape {
        name: "block_rebinding_stays_in_its_block",
        from: "cmux#41792 F1",
        files: &[(
            "src/lib.rs",
            "mod helpers {
    pub type Lock = std::sync::@X@<()>;
}
mod mutexes {
    pub type Lock = std::sync::@Y@<()>;
}
@HOOK@
mod tests {
    use super::*;
    fn local() {
        {
            use super::mutexes as helpers;
        }
        {
            use helpers::Lock;
            static HOOK_TEST: Lock = Lock::new(());
            @CHECK@
        }
    }
}
",
        )],
        may_refuse_valid: Some(TWO_WAYS),
    },
];

/// One generated crate: a shape with a cell put in each slot it uses.
struct Case<'a> {
    shape: &'a Shape,
    cells: Vec<(&'static str, &'static str)>,
}

impl Case<'_> {
    fn label(&self) -> String {
        let cells: Vec<String> =
            self.cells.iter().map(|(slot, cell)| format!("{slot}={cell}")).collect();
        format!("{}[{}] ({})", self.shape.name, cells.join(","), self.shape.from)
    }

    fn expand(&self, text: &str) -> String {
        let mut out = text.replace("@HOOK@", HOOK.trim_end()).replace("@CHECK@", CHECK);
        for (slot, cell) in &self.cells {
            out = out.replace(slot, cell);
        }
        out
    }

    fn files(&self) -> Vec<(&'static str, String)> {
        self.shape.files.iter().map(|(rel, text)| (*rel, self.expand(text))).collect()
    }
}

/// Every crate of every shape: each slot a shape uses takes each cell.
fn cases() -> Vec<Case<'static>> {
    let mut out = Vec::new();
    for shape in SHAPES {
        let used: Vec<&'static str> = SLOTS
            .into_iter()
            .filter(|slot| shape.files.iter().any(|(_, text)| text.contains(slot)))
            .collect();
        let mut combos: Vec<Vec<(&'static str, &'static str)>> = vec![Vec::new()];
        for slot in used {
            combos = combos
                .into_iter()
                .flat_map(|combo| {
                    CELLS.into_iter().map(move |cell| {
                        let mut next = combo.clone();
                        next.push((slot, cell));
                        next
                    })
                })
                .collect();
        }
        out.extend(combos.into_iter().map(|cells| Case { shape, cells }));
    }
    out
}

/// Whether HOOK_TEST is a `Mutex<()>`, as rustc says: Ok(true) when the crate compiles,
/// Ok(false) when its only errors are E0308, Err otherwise.
fn rustc_says_mutex(dir: &Path) -> Result<bool, String> {
    let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
    let output = Command::new(&rustc)
        .args(["--edition", "2024", "--crate-type", "lib", "--crate-name", "shape"])
        .args(["--emit", "metadata", "-A", "warnings", "--error-format", "short", "--out-dir"])
        .arg(dir.join("out"))
        .arg(dir.join("src/lib.rs"))
        .output()
        .map_err(|e| {
            format!("cannot run {rustc:?} ({e}); this test needs the toolchain cargo uses")
        })?;
    if output.status.success() {
        return Ok(true);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let errors: Vec<&str> = stderr
        .lines()
        .filter(|line| line.contains("error"))
        .filter(|line| !line.starts_with("error: aborting due to"))
        .filter(|line| !line.starts_with("For more information"))
        .collect();
    if !errors.is_empty() && errors.iter().all(|line| line.contains("error[E0308]")) {
        Ok(false)
    } else {
        Err(format!("rustc failed with more than E0308, so the shape is broken:\n{stderr}"))
    }
}

/// Whether the check takes HOOK_TEST as a `Mutex<()>` serializer in the crate at `dir`.
fn check_says_mutex(dir: &Path) -> bool {
    !judge_tree(dir).iter().any(|finding| finding.why.contains(REFUSED))
}

fn write_crate(dir: &Path, files: &[(&str, String)]) {
    let _ = std::fs::remove_dir_all(dir);
    for (rel, text) in files {
        let path = dir.join(rel);
        std::fs::create_dir_all(path.parent().expect("a file has a folder"))
            .expect("make the folder");
        std::fs::write(&path, text).expect("write the file");
    }
}

#[test]
fn the_check_takes_hook_test_as_a_mutex_exactly_when_rustc_does() {
    let root: PathBuf =
        std::env::temp_dir().join(format!("cmux-source-scan-differential-{}", std::process::id()));
    let cases = cases();
    assert!(cases.len() >= 2 * SHAPES.len(), "the corpus generated {} crates", cases.len());
    let mut failed: Vec<String> = Vec::new();
    let mut allowance_used: Vec<&str> = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let dir = root.join(index.to_string());
        let files = case.files();
        write_crate(&dir, &files);
        let shown = || {
            files
                .iter()
                .map(|(rel, text)| format!("--- {rel}\n{text}"))
                .collect::<Vec<_>>()
                .join("")
        };
        let truth = match rustc_says_mutex(&dir) {
            Ok(truth) => truth,
            Err(why) => {
                failed.push(format!("{}: {why}\n{}", case.label(), shown()));
                continue;
            }
        };
        let verdict = check_says_mutex(&dir);
        match (truth, verdict) {
            (true, true) | (false, false) => {}
            (false, true) => failed.push(format!(
                "{}: the check takes HOOK_TEST as a Mutex<()> serializer; rustc says it is none \
                 (E0308)\n{}",
                case.label(),
                shown()
            )),
            (true, false) => match case.shape.may_refuse_valid {
                Some(_) => allowance_used.push(case.shape.name),
                None => failed.push(format!(
                    "{}: the check refuses HOOK_TEST; rustc takes it as a Mutex<()>\n{}",
                    case.label(),
                    shown()
                )),
            },
        }
    }
    let _ = std::fs::remove_dir_all(&root);
    for shape in SHAPES.iter().filter(|s| s.may_refuse_valid.is_some()) {
        if !allowance_used.contains(&shape.name) {
            failed.push(format!(
                "{} ({}): the shape says the check refuses a valid serializer ({}), but it refused \
                 none: drop its may_refuse_valid",
                shape.name,
                shape.from,
                shape.may_refuse_valid.unwrap_or_default()
            ));
        }
    }
    assert!(
        failed.is_empty(),
        "{} of {} generated crates disagree with rustc:\n\n{}",
        failed.len(),
        cases.len(),
        failed.join("\n\n")
    );
}
