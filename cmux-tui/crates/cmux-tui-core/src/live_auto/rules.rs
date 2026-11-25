//! What a save is, by the rules `scripts/cmux-next/live_apply.py` uses: one
//! copy of them, `scripts/cmux-next/live-apply-rules.json` in the watched
//! checkout, which both read. A file's kind is the same verdict
//! `live_apply.py classify` gives it (`no-app`, `web-live`, `strings`,
//! `daemon`, `swift-live`, `rebuild`, `ios-only`); its change class is the
//! first class of `.github/change-classes.json` whose paths match it
//! (fnmatch: `*` also crosses `/`); and a path the app FFI archive is built
//! from (`live_apply.py --ffi-closure`, `cmux_next_route.app_ffi_inputs`)
//! is marked too.

use std::path::Path;

use regex::Regex;
use serde::Deserialize;

/// The rules file, relative to the checkout.
pub const RULES_FILE: &str = "scripts/cmux-next/live-apply-rules.json";
/// The change classes, relative to the checkout.
pub const CLASSES_FILE: &str = ".github/change-classes.json";

/// `live_apply.py`'s verdicts, heaviest first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Kind {
    Rebuild,
    SwiftLive,
    Daemon,
    WebLive,
    Strings,
    IosOnly,
    NoApp,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rebuild => "rebuild",
            Self::SwiftLive => "swift-live",
            Self::Daemon => "daemon",
            Self::WebLive => "web-live",
            Self::Strings => "strings",
            Self::IosOnly => "ios-only",
            Self::NoApp => "no-app",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "rebuild" => Self::Rebuild,
            "swift-live" => Self::SwiftLive,
            "daemon" => Self::Daemon,
            "web-live" => Self::WebLive,
            "strings" => Self::Strings,
            "ios-only" => Self::IosOnly,
            "no-app" => Self::NoApp,
            _ => return None,
        })
    }
}

/// A saved file as git sees it against the checkout's HEAD.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Added,
    Modified,
    Deleted,
}

/// One file's verdict: its kind, and why it needs a build when it does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub kind: Kind,
    pub reasons: Vec<String>,
}

#[derive(Deserialize)]
struct RulesFile {
    order: Vec<String>,
    noapp_path: String,
    noapp_ext: String,
    web: String,
    strings: String,
    rust: String,
    ios: String,
    rebuild_file: String,
    native_source: String,
    native_exempt: String,
    comment: String,
    stored: String,
    func: String,
    type_decl: String,
    static_let: String,
    file_let: String,
    entry: String,
    live_module: String,
    live_package: String,
    swift_module: String,
    case: String,
}

#[derive(Deserialize)]
struct ClassesFile {
    classes: Vec<ClassEntry>,
}

#[derive(Deserialize)]
struct ClassEntry {
    name: String,
    paths: Vec<String>,
    swap: String,
}

/// One `.github/change-classes.json` class.
#[derive(Debug)]
pub struct ChangeClass {
    pub name: String,
    pub swap: String,
    paths: Vec<Regex>,
}

/// The paths the app FFI archive is built from: under an input, under no
/// excluded folder (`app_ffi_pin.is_input`).
#[derive(Clone, Debug, Default)]
pub struct FfiClosure {
    pub inputs: Vec<String>,
    pub excluded: Vec<String>,
}

impl FfiClosure {
    pub fn contains(&self, path: &str) -> bool {
        let under = |prefix: &String| {
            let prefix = prefix.trim_end_matches('/');
            path == prefix || path.strip_prefix(prefix).is_some_and(|rest| rest.starts_with('/'))
        };
        self.inputs.iter().any(under) && !self.excluded.iter().any(under)
    }
}

#[derive(Debug)]
pub struct Rules {
    order: Vec<Kind>,
    noapp_path: Regex,
    noapp_ext: Regex,
    web: Regex,
    strings: Regex,
    rust: Regex,
    ios: Regex,
    rebuild_file: Regex,
    native_source: Regex,
    native_exempt: Regex,
    // Swift diff-line rules, anchored at the line's start (Python `re.match`).
    comment: Regex,
    stored: Regex,
    func: Regex,
    type_decl: Regex,
    static_let: Regex,
    file_let: Regex,
    entry: Regex,
    case: Regex,
    live_module: Regex,
    live_package: Regex,
    swift_module: Regex,
    whitespace: Regex,
    classes: Vec<ChangeClass>,
    pub ffi: FfiClosure,
}

fn compile(name: &str, pattern: &str) -> Result<Regex, String> {
    Regex::new(pattern).map_err(|error| format!("{RULES_FILE} {name}: {error}"))
}

fn anchored(name: &str, pattern: &str) -> Result<Regex, String> {
    compile(name, &format!("^(?:{pattern})"))
}

/// fnmatch as Python's: `*` is any run of characters (`/` too), `?` one.
fn fnmatch(pattern: &str) -> Result<Regex, String> {
    let mut out = String::from("^");
    for ch in pattern.chars() {
        match ch {
            '*' => out.push_str(".*"),
            '?' => out.push('.'),
            other => out.push_str(&regex::escape(&other.to_string())),
        }
    }
    out.push('$');
    Regex::new(&out).map_err(|error| format!("{CLASSES_FILE} {pattern}: {error}"))
}

impl Rules {
    /// The rules from their files' text. `classes` is optional: a checkout
    /// without change classes still routes, with no class named.
    pub fn parse(rules: &str, classes: Option<&str>, ffi: FfiClosure) -> Result<Self, String> {
        let file: RulesFile =
            serde_json::from_str(rules).map_err(|error| format!("{RULES_FILE}: {error}"))?;
        let order = file
            .order
            .iter()
            .map(|name| {
                Kind::parse(name)
                    .ok_or_else(|| format!("{RULES_FILE} order: unknown verdict {name}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let classes = match classes {
            Some(text) => {
                let parsed: ClassesFile = serde_json::from_str(text)
                    .map_err(|error| format!("{CLASSES_FILE}: {error}"))?;
                parsed
                    .classes
                    .into_iter()
                    .map(|class| {
                        Ok(ChangeClass {
                            paths: class
                                .paths
                                .iter()
                                .map(|p| fnmatch(p))
                                .collect::<Result<_, String>>()?,
                            name: class.name,
                            swap: class.swap,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()?
            }
            None => Vec::new(),
        };
        Ok(Self {
            order,
            noapp_path: compile("noapp_path", &file.noapp_path)?,
            noapp_ext: compile("noapp_ext", &file.noapp_ext)?,
            web: compile("web", &file.web)?,
            strings: compile("strings", &file.strings)?,
            rust: compile("rust", &file.rust)?,
            ios: compile("ios", &file.ios)?,
            rebuild_file: compile("rebuild_file", &file.rebuild_file)?,
            native_source: compile("native_source", &file.native_source)?,
            native_exempt: compile("native_exempt", &file.native_exempt)?,
            comment: anchored("comment", &file.comment)?,
            stored: anchored("stored", &file.stored)?,
            func: anchored("func", &file.func)?,
            type_decl: anchored("type_decl", &file.type_decl)?,
            static_let: anchored("static_let", &file.static_let)?,
            file_let: anchored("file_let", &file.file_let)?,
            entry: anchored("entry", &file.entry)?,
            case: anchored("case", &file.case)?,
            live_module: anchored("live_module", &file.live_module)?,
            live_package: compile("live_package", &file.live_package)?,
            swift_module: compile("swift_module", &file.swift_module)?,
            whitespace: compile("whitespace", r"\s+")?,
            classes,
            ffi,
        })
    }

    /// The rules of the checkout at `root`, as its own files say them.
    pub fn load(root: &Path, ffi: FfiClosure) -> Result<Self, String> {
        let rules = std::fs::read_to_string(root.join(RULES_FILE))
            .map_err(|error| format!("{}: {error}", root.join(RULES_FILE).display()))?;
        let classes = std::fs::read_to_string(root.join(CLASSES_FILE)).ok();
        Self::parse(&rules, classes.as_deref(), ffi)
    }

    /// The heaviest of `kinds`, by the rules' order.
    pub fn heaviest(&self, kinds: impl IntoIterator<Item = Kind>) -> Kind {
        let kinds: Vec<Kind> = kinds.into_iter().collect();
        self.order.iter().copied().find(|kind| kinds.contains(kind)).unwrap_or(Kind::NoApp)
    }

    /// The first change class whose paths match `path`.
    pub fn change_class(&self, path: &str) -> Option<&ChangeClass> {
        self.classes.iter().find(|class| class.paths.iter().any(|rx| rx.is_match(path)))
    }

    fn rebuild_file(&self, path: &str) -> bool {
        self.rebuild_file.is_match(path)
            || (self.native_source.is_match(path) && !self.native_exempt.is_match(path))
    }

    /// One file's verdict, as `live_apply.classify` gives it. `diff` is the
    /// file's `-U0` diff lines (`+` or `-`, text); only Swift reads it.
    pub fn classify(&self, status: Status, path: &str, diff: &[(char, String)]) -> Verdict {
        let plain = |kind| Verdict { kind, reasons: Vec::new() };
        if self.ios.is_match(path) {
            return plain(Kind::IosOnly);
        }
        if self.noapp_path.is_match(path) {
            return plain(Kind::NoApp);
        }
        if self.web.is_match(path) {
            return plain(Kind::WebLive);
        }
        if self.strings.is_match(path) {
            return plain(Kind::Strings);
        }
        if self.rebuild_file(path) {
            return Verdict { kind: Kind::Rebuild, reasons: vec!["resource or manifest".into()] };
        }
        if self.rust.is_match(path) {
            return plain(Kind::Daemon);
        }
        if self.noapp_ext.is_match(path) {
            return plain(Kind::NoApp);
        }
        if !path.ends_with(".swift") {
            // A deleted file of no known kind: the running app keeps what it
            // had, and nothing that ships reads it any more.
            if status == Status::Deleted {
                return plain(Kind::NoApp);
            }
            return Verdict { kind: Kind::Rebuild, reasons: vec!["other app file".into()] };
        }
        // A deleted file's code stays in the running binary, and nothing calls it any more.
        let mut why = if status == Status::Deleted {
            Vec::new()
        } else {
            self.swift_reasons(diff, status == Status::Added)
        };
        let base = path.rsplit('/').next().unwrap_or(path);
        if status == Status::Added && base == "main.swift" {
            why = vec!["new entry point".into()];
        }
        let module = self.swift_module.captures(path).and_then(|c| c.get(1)).map(|m| m.as_str());
        let live = module.is_some_and(|m| self.live_module.is_match(m))
            && self.live_package.is_match(path);
        if status != Status::Deleted && why.is_empty() && !live {
            why = vec![format!("outside the live code modules ({})", module.unwrap_or(path))];
        }
        if why.is_empty() {
            plain(Kind::SwiftLive)
        } else {
            Verdict { kind: Kind::Rebuild, reasons: why }
        }
    }

    /// Why a Swift change needs a rebuild (`live_apply.swift_reasons`);
    /// empty when it only changes function bodies.
    pub fn swift_reasons(&self, lines: &[(char, String)], added_file: bool) -> Vec<String> {
        if added_file {
            let entry = lines.iter().any(|(sign, text)| *sign == '+' && self.entry.is_match(text));
            return if entry { vec!["new entry point".into()] } else { Vec::new() };
        }
        let mut reasons = std::collections::BTreeSet::new();
        let (mut removed, mut added) = (Vec::new(), Vec::new());
        for (sign, line) in lines {
            let body = line.trim_end();
            if body.trim().is_empty() || self.comment.is_match(body) {
                continue;
            }
            let indent = body.len() - body.trim_start_matches(' ').len();
            if self.entry.is_match(body) && *sign == '+' {
                reasons.insert("new entry point");
            } else if self.type_decl.is_match(body) {
                reasons.insert("type or conformance");
            } else if (self.static_let.is_match(body) && indent <= 4)
                || (self.file_let.is_match(body) && indent == 0)
            {
                // A constant of no instance: the patch carries it (live_apply.py's STATIC_LET).
                continue;
            } else if self.stored.is_match(body) && indent <= 4 && !body.ends_with('{') {
                reasons.insert("stored property");
            } else if self.case.is_match(body) && indent == 4 {
                reasons.insert("enum case");
            } else if self.func.is_match(body) {
                let sig = body.trim().trim_end_matches('{').trim();
                let sig = self.whitespace.replace_all(sig, " ").into_owned();
                if *sign == '-' { removed.push(sig) } else { added.push(sig) }
            }
        }
        if removed.iter().any(|sig| !added.contains(sig)) {
            reasons.insert("signature");
        }
        reasons.into_iter().map(String::from).collect()
    }
}
