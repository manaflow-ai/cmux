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
//! `Mutex<()>` fails too, unless an allowance of the shape names that slot combination and why
//! the check refuses it by design (a name the file binds two ways is a serializer only when every
//! way is; another file's type is unresolved). An allowance fails when it names no combination of
//! its shape, when its reason does not fit its combination, or when the check refuses no Mutex
//! there (review of cmux#41826 F1). The meta-tests at the end hand the judging a stub check to
//! show an allowance hides nothing past its combination.
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
/// Why the check refuses a HOOK_TEST rustc takes as a `Mutex<()>`, by design.
#[derive(Clone, Copy)]
enum Reason {
    /// The file binds `Lock` two ways, one of them an RwLock, and a name bound two ways
    /// serializes only when every way does (reviews of cmux#41693 F1 and cmux#41707 F1): it fits
    /// a combination whose slots hold different cells.
    TwoWays,
    /// The Mutex rustc reads is in another file, which the check does not read: it fits a
    /// combination that puts a Mutex in that file's slot.
    OtherFile(&'static str),
}

impl Reason {
    fn text(self) -> String {
        match self {
            Reason::TwoWays => "the file binds `Lock` two ways, one of them an RwLock".to_string(),
            Reason::OtherFile(slot) => format!("{slot}'s Mutex is in another file"),
        }
    }

    fn fits(self, case: &Case<'_>) -> bool {
        match self {
            Reason::TwoWays => {
                case.cells.iter().any(|(_, a)| case.cells.iter().any(|(_, b)| a != b))
            }
            Reason::OtherFile(slot) => cell_of(case, slot) == "Mutex",
        }
    }
}

/// One slot combination of a shape (`@X@=RwLock,@Y@=Mutex`, as a case's label writes it) where
/// the check refuses a HOOK_TEST rustc takes as a `Mutex<()>`, and why (review of cmux#41826 F1:
/// an allowance once covered every combination of its shape).
struct Allowance {
    combo: &'static str,
    reason: Reason,
}

struct Shape {
    name: &'static str,
    /// The review finding it comes from.
    from: &'static str,
    /// The crate's files, from its folder: `src/lib.rs` first. `@HOOK@` is the marked hook,
    /// `@CHECK@` the type check, `@X@` and `@Y@` the slots.
    files: &'static [(&'static str, &'static str)],
    /// The combinations where the check refuses a HOOK_TEST rustc takes as a `Mutex<()>`: each
    /// must be one, and its reason must fit it.
    allowed: &'static [Allowance],
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
        allowed: &[],
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
        allowed: &[],
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
        allowed: &[],
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
        allowed: &[
            Allowance { combo: "@X@=Mutex,@Y@=Mutex", reason: Reason::OtherFile("@Y@") },
            Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::OtherFile("@Y@") },
        ],
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
        allowed: &[],
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
        allowed: &[],
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
        allowed: &[Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::TwoWays }],
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
        allowed: &[],
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
        allowed: &[],
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
        allowed: &[
            Allowance { combo: "@X@=Mutex,@Y@=Mutex", reason: Reason::OtherFile("@Y@") },
            Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::OtherFile("@Y@") },
        ],
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
        allowed: &[Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::TwoWays }],
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
        allowed: &[Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::TwoWays }],
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
        allowed: &[Allowance { combo: "@X@=RwLock,@Y@=Mutex", reason: Reason::TwoWays }],
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
        allowed: &[Allowance { combo: "@X@=Mutex,@Y@=RwLock", reason: Reason::TwoWays }],
    },
];

/// One generated crate: a shape with a cell put in each slot it uses.
struct Case<'a> {
    shape: &'a Shape,
    cells: Vec<(&'static str, &'static str)>,
}

impl Case<'_> {
    /// Its slot combination: `@X@=RwLock,@Y@=Mutex`.
    fn combo(&self) -> String {
        let cells: Vec<String> =
            self.cells.iter().map(|(slot, cell)| format!("{slot}={cell}")).collect();
        cells.join(",")
    }

    fn label(&self) -> String {
        format!("{}[{}] ({})", self.shape.name, self.combo(), self.shape.from)
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

/// One generated crate's two answers: rustc's (or why it gave none) and the check's.
struct Outcome<'a> {
    case: &'a Case<'a>,
    /// Whether rustc takes HOOK_TEST as a `Mutex<()>`, or why the shape is broken.
    truth: Result<bool, String>,
    /// Whether the check takes it as a serializer.
    verdict: bool,
    /// The crate's files, for a failure.
    shown: String,
}

/// Every way `outcomes` disagree with rustc, and every refusal allowance of their shapes that
/// names no crate of its shape, whose reason does not fit its combination, or that no crate used
/// (the check refuses no Mutex there).
fn disagreements(outcomes: &[Outcome<'_>]) -> Vec<String> {
    let mut failed: Vec<String> = Vec::new();
    let mut used: Vec<(&str, String)> = Vec::new();
    for Outcome { case, truth, verdict, shown } in outcomes {
        let truth = match truth {
            Ok(truth) => *truth,
            Err(why) => {
                failed.push(format!("{}: {why}\n{shown}", case.label()));
                continue;
            }
        };
        match (truth, *verdict) {
            (true, true) | (false, false) => {}
            (false, true) => failed.push(format!(
                "{}: the check takes HOOK_TEST as a Mutex<()> serializer; rustc says it is none \
                 (E0308)\n{shown}",
                case.label()
            )),
            (true, false) if case.shape.allowed.iter().any(|a| a.combo == case.combo()) => {
                used.push((case.shape.name, case.combo()));
            }
            (true, false) => failed.push(format!(
                "{}: the check refuses HOOK_TEST; rustc takes it as a Mutex<()>, and no allowance \
                 names this combination\n{shown}",
                case.label()
            )),
        }
    }
    let mut shapes: Vec<&Shape> = Vec::new();
    for outcome in outcomes {
        if !shapes.iter().any(|s| s.name == outcome.case.shape.name) {
            shapes.push(outcome.case.shape);
        }
    }
    for shape in shapes {
        for allowance in shape.allowed {
            let at = format!("{}[{}] ({})", shape.name, allowance.combo, shape.from);
            let case = outcomes
                .iter()
                .map(|o| o.case)
                .find(|c| c.shape.name == shape.name && c.combo() == allowance.combo);
            let Some(case) = case else {
                failed.push(format!("{at}: an allowance names no combination of the shape"));
                continue;
            };
            if !allowance.reason.fits(case) {
                failed.push(format!(
                    "{at}: the allowance's reason ({}) does not fit this combination",
                    allowance.reason.text()
                ));
            }
            if !used.iter().any(|(name, combo)| *name == shape.name && combo == allowance.combo) {
                failed.push(format!(
                    "{at}: allowed ({}), but the check does not refuse a Mutex rustc accepts \
                     here: drop the allowance",
                    allowance.reason.text()
                ));
            }
        }
    }
    failed
}

#[test]
fn the_check_takes_hook_test_as_a_mutex_exactly_when_rustc_does() {
    let root: PathBuf =
        std::env::temp_dir().join(format!("cmux-source-scan-differential-{}", std::process::id()));
    let cases = cases();
    assert!(cases.len() >= 2 * SHAPES.len(), "the corpus generated {} crates", cases.len());
    let mut outcomes: Vec<Outcome<'_>> = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let dir = root.join(index.to_string());
        let files = case.files();
        write_crate(&dir, &files);
        let shown: String = files.iter().map(|(rel, text)| format!("--- {rel}\n{text}")).collect();
        let truth = rustc_says_mutex(&dir);
        let verdict = truth.is_ok() && check_says_mutex(&dir);
        outcomes.push(Outcome { case, truth, verdict, shown });
    }
    let _ = std::fs::remove_dir_all(&root);
    let failed = disagreements(&outcomes);
    assert!(
        failed.is_empty(),
        "{} of {} generated crates disagree with rustc:\n\n{}",
        failed.len(),
        cases.len(),
        failed.join("\n\n")
    );
}

/// The cell a case puts in `slot`.
fn cell_of(case: &Case<'_>, slot: &str) -> &'static str {
    case.cells.iter().find(|(s, _)| *s == slot).map_or("", |(_, cell)| *cell)
}

/// What the harness says when the check answers `verdict` for each crate of shape `name`, rustc
/// answering `truth` (no rustc runs: the meta-tests judge the harness, not the check).
fn judged_with(
    name: &str,
    truth: impl Fn(&Case<'_>) -> bool,
    verdict: impl Fn(&Case<'_>) -> bool,
) -> Vec<String> {
    let cases: Vec<Case<'static>> = cases().into_iter().filter(|c| c.shape.name == name).collect();
    assert!(!cases.is_empty(), "no shape named {name}");
    let outcomes: Vec<Outcome<'_>> = cases
        .iter()
        .map(|case| Outcome {
            case,
            truth: Ok(truth(case)),
            verdict: verdict(case),
            shown: String::new(),
        })
        .collect();
    disagreements(&outcomes)
}

/// Review of cmux#41826 F1: an allowance covered every slot combination of its shape, so a
/// check that refused a combination outside the allowance's reason passed. In
/// body_rebinding_in_the_file rustc reads `Lock` from `mutexes` (`@Y@`); the allowance is for
/// `@X@=RwLock,@Y@=Mutex` (the file binds `Lock` two ways and one is an RwLock). A check that also
/// refuses `@X@=Mutex,@Y@=Mutex`, where both bindings are Mutexes, must be named.
#[test]
fn an_allowance_does_not_hide_a_refusal_outside_its_combination() {
    let failed = judged_with(
        "body_rebinding_in_the_file",
        |case| cell_of(case, "@Y@") == "Mutex",
        // The check refuses every crate: both RwLock ones (rightly), the allowed one and the
        // all-Mutex one.
        |_| false,
    );
    assert!(
        failed.iter().any(|f| f.contains("body_rebinding_in_the_file[@X@=Mutex,@Y@=Mutex]")),
        "a refusal of the all-Mutex crate went unnamed: {failed:#?}"
    );
}

/// The same review: a check that regressed to refusing every crate of a shape with an allowance
/// must fail, not pass under it.
#[test]
fn an_allowance_does_not_hide_a_shape_refused_whole() {
    let failed = judged_with(
        "block_rebinding_stays_in_its_block",
        |case| cell_of(case, "@X@") == "Mutex",
        |_| false,
    );
    assert!(
        failed
            .iter()
            .any(|f| f.contains("block_rebinding_stays_in_its_block[@X@=Mutex,@Y@=Mutex]")),
        "a check refusing the whole shape went unnamed: {failed:#?}"
    );
}

/// The same review: an allowance must name a combination of its shape and fit its reason. A
/// shape that allows its all-Mutex crate "two ways" (both bindings are Mutexes, so its reason
/// does not hold) and a combination it has no slot for must both be named.
#[test]
fn an_allowance_must_fit_its_reason_and_name_a_combination() {
    const MISFIT: Shape = Shape {
        name: "misfit",
        from: "a meta-test",
        files: &[("src/lib.rs", "@X@ @Y@")],
        allowed: &[
            Allowance { combo: "@X@=Mutex,@Y@=Mutex", reason: Reason::TwoWays },
            Allowance { combo: "@X@=Mutex,@Z@=Mutex", reason: Reason::TwoWays },
        ],
    };
    let case = Case { shape: &MISFIT, cells: vec![("@X@", "Mutex"), ("@Y@", "Mutex")] };
    let outcomes = [Outcome { case: &case, truth: Ok(true), verdict: false, shown: String::new() }];
    let failed = disagreements(&outcomes);
    assert!(
        failed.iter().any(|f| f.contains("misfit[@X@=Mutex,@Y@=Mutex]")
            && f.contains("does not fit this combination")),
        "a reason that does not fit went unnamed: {failed:#?}"
    );
    assert!(
        failed.iter().any(
            |f| f.contains("misfit[@X@=Mutex,@Z@=Mutex]") && f.contains("names no combination")
        ),
        "an allowance of no combination went unnamed: {failed:#?}"
    );
}
