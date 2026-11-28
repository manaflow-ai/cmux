//! ACP select options may contain groups; option values are opaque protocol ids.
use serde_json::Value;

pub fn choices(option: &Value) -> Vec<(String, String)> {
    fn collect(option: &Value, out: &mut Vec<(String, String)>) {
        if let Some(id) = option.get("value").and_then(Value::as_str) {
            out.push((
                id.to_owned(),
                option.get("name").and_then(Value::as_str).unwrap_or(id).to_owned(),
            ));
        }
        if let Some(children) = option.get("options").and_then(Value::as_array) {
            for child in children {
                collect(child, out);
            }
        }
    }
    let mut out = Vec::new();
    collect(option, &mut out);
    out
}

/// Preserve exact ids. DSH also permits the friendly provider/model spelling
/// or a bare model name, but only if that name identifies one advertised route.
pub fn resolve(option: &Value, requested: &str) -> Result<String, String> {
    let options = choices(option);
    if options.iter().any(|(id, _)| id == requested) {
        return Ok(requested.to_owned());
    }
    let matches: Vec<_> = options
        .iter()
        .filter(|(id, _)| {
            let Ok(parts) = serde_json::from_str::<Vec<String>>(id) else { return false };
            parts.len() == 2
                && (parts[1] == requested || format!("{}/{}", parts[0], parts[1]) == requested)
        })
        .collect();
    match matches.as_slice() {
        [(id, _)] => Ok(id.clone()),
        [] => Ok(requested.to_owned()), // The agent owns validation for other selectors.
        _ => Err(format!(
            "model {requested:?} matches multiple provider routes; use an exact advertised model id"
        )),
    }
}

// ---------------------------------------------------------------- model aliases
//
// Leo, 2026-11-22: "you guys need to be able to hot patch these and reroute and auto-reroute to
// proper names. there's not much confusion possible here". Claude Code takes `claude-fable-5-2`
// (or `fable`) and refuses `fable-5.2` (`[claude-code:unrecognized_model]`); 16 lanes started on
// that spelling died on their first turn. Every entry point that takes a model for a Claude Code
// or Codex harness reads it through [`canonical_model`] (`hub/model_alias.rs`), and a turn that
// fails on its model is retried once under the canonical id (`hub/auto_resume/model_reroute.rs`).
//
// The rule agrees with leo-workspace `tools/model_aliases.py`: a name is folded (trimmed,
// lowercased, a leading `anthropic/`, `claude/`, `openai/` or `codex/` dropped, runs of space,
// `_` and `-` as one `-`), then looked up under each of its keys (digit.digit as digit-digit and
// back, a letter joined to a digit split, `fable5` as `fable-5`, with and without `claude-`)
// against the keys of every model id and alias the harness's catalog entry lists, then against
// derived spellings (`astra-6.2`, `gpt-6.2`, bare `claude`), then a family word alone, which goes
// to the family's newest model (`astra` -> `gpt-6.2-astra`). One id: that id. A key two ids
// share (`gpt-6.2`: astra or sol; bare `claude`): ambiguous, the only refusal. None: the name passes through unchanged,
// and the harness decides. A trailing `[1m]`-style suffix is kept as given. A name the catalog
// lists exactly (an id, or an alias such as `opus` that the harness takes itself) is never
// rewritten.

/// The harness heads a model name may carry (`claude/fable-5.2`).
const HEADS: [&str; 4] = ["anthropic/", "claude/", "openai/", "codex/"];

/// The catalog harnesses whose model names are folded: Claude Code's and Codex's. Another
/// harness's names (a gateway's `provider/model` routes) pass through as given.
pub const ALIASED_HARNESSES: [&str; 2] = ["claude", "codex"];

/// A model name as its harness's catalog spells it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Canonical {
    /// The canonical id (with the given suffix), or the name as given when the catalog does not
    /// know it.
    pub model: String,
    /// The name as given (trimmed).
    pub given: String,
    /// The catalog knows the name (as an id, an alias or a fold of one).
    pub known: bool,
}

impl Canonical {
    /// The name was rewritten.
    pub fn changed(&self) -> bool {
        self.known && self.model != self.given
    }

    /// The one line an entry point logs on a rewrite.
    pub fn line(&self) -> String {
        format!("model {} -> {}", self.given, self.model)
    }

    fn unchanged(given: &str) -> Self {
        Canonical { model: given.to_owned(), given: given.to_owned(), known: false }
    }
}

/// A name that reaches more than one catalog id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ambiguous {
    pub given: String,
    pub choices: Vec<String>,
}

impl std::fmt::Display for Ambiguous {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "model {} is ambiguous: one of {}", self.given, self.choices.join(", "))
    }
}

/// One spelling for every way of writing a name: trimmed, lowercased, no harness head, runs of
/// space, `_` and `-` as one `-`, no `-` at either end.
pub fn fold(name: &str) -> String {
    let mut text = name.trim().to_lowercase();
    if let Some(rest) = HEADS.iter().find_map(|h| text.strip_prefix(*h)) {
        text = rest.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_whitespace() || c == '_' || c == '-' {
            if !out.ends_with('-') {
                out.push('-');
            }
        } else {
            out.push(c);
        }
    }
    out.trim_matches('-').to_owned()
}

/// `text` with each `from` between two digits as `to` (`5.2` -> `5-2`, or back).
fn between_digits(text: &str, from: char, to: char) -> String {
    let mut out = String::with_capacity(text.len());
    let mut prev: Option<char> = None;
    let mut rest = text.chars().peekable();
    while let Some(c) = rest.next() {
        let flanked = prev.is_some_and(|p| p.is_ascii_digit())
            && rest.peek().is_some_and(char::is_ascii_digit);
        out.push(if c == from && flanked { to } else { c });
        prev = Some(c);
    }
    out
}

/// `text` with a `-` between a letter and the digit after it (`fable5-2` -> `fable-5-2`).
fn split_letter_digit(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    for c in text.chars() {
        if c.is_ascii_digit() && out.chars().last().is_some_and(|p| p.is_ascii_lowercase()) {
            out.push('-');
        }
        out.push(c);
    }
    out
}

/// Every key `text` is looked up under, folded first: as written, digit.digit as digit-digit,
/// a letter joined to a digit split, and that with digit-digit as digit.digit (Codex ids keep
/// their dots); each with and without `claude-`, and a `codex-` head read as `gpt-`.
pub fn keys(text: &str) -> Vec<String> {
    let folded = fold(text);
    let dashed = between_digits(&folded, '.', '-');
    let split = split_letter_digit(&dashed);
    let dotted = between_digits(&split, '-', '.');
    let mut out: Vec<String> = Vec::new();
    for key in [folded, dashed, split, dotted] {
        let bare = key.strip_prefix("claude-").map(str::to_owned);
        let gpt = key.strip_prefix("codex-").map(|rest| format!("gpt-{rest}"));
        for k in std::iter::once(key).chain(bare).chain(gpt) {
            if !k.is_empty() && !out.contains(&k) {
                out.push(k);
            }
        }
    }
    out
}

/// `name` without a trailing `[...]` suffix, and the suffix (`sonnet[1m]` -> `sonnet`, `[1m]`).
fn split_suffix(name: &str) -> (&str, &str) {
    if name.ends_with(']')
        && let Some(at) = name.rfind('[')
        && let (Some(base), Some(suffix)) = (name.get(..at), name.get(at..))
    {
        return (base.trim_end(), suffix);
    }
    (name, "")
}

/// An id's parts: its head (`claude`, `gpt`), its family words (`fable`, `astra`; none for
/// `gpt-5.6`) and its version (`[5, 2]` for `claude-fable-5-2` and `gpt-6.2-astra`).
struct IdParts {
    head: String,
    words: Vec<String>,
    version: Vec<u32>,
}

fn id_parts(id: &str) -> Option<IdParts> {
    let folded = between_digits(&fold(id), '.', '-');
    let mut tokens = folded.split('-');
    let head = tokens.next()?.to_owned();
    let (mut words, mut version) = (Vec::new(), Vec::new());
    for token in tokens {
        match token.parse::<u32>() {
            Ok(n) => version.push(n),
            Err(_) if token.chars().all(|c| c.is_ascii_lowercase()) => words.push(token.to_owned()),
            Err(_) => return None,
        }
    }
    Some(IdParts { head, words, version })
}

/// The derived spellings an id answers to beside its own: family then version (`astra-6.2`),
/// head then version (`gpt-6.2`, which `gpt-6.2-sol` and `gpt-6.2-astra` share), and the bare
/// head (`claude`, every Claude id's).
fn derived_spellings(parts: &IdParts) -> Vec<String> {
    let version: Vec<String> = parts.version.iter().map(u32::to_string).collect();
    let version = version.join(".");
    let mut out = vec![parts.head.clone()];
    if !version.is_empty() {
        out.push(format!("{}-{version}", parts.head));
        if !parts.words.is_empty() {
            out.push(format!("{}-{version}", parts.words.join("-")));
        }
    }
    out
}

/// One tier of lookup: every key and the ids it reaches.
#[derive(Default)]
struct Tier<'a>(std::collections::BTreeMap<String, Vec<&'a str>>);

impl<'a> Tier<'a> {
    fn add(&mut self, spelling: &str, id: &'a str) {
        for key in keys(spelling) {
            let ids = self.0.entry(key).or_default();
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }

    /// The ids the first of `wanted` this tier knows reaches.
    fn find(&self, wanted: &[String]) -> Option<&Vec<&'a str>> {
        wanted.iter().find_map(|k| self.0.get(k))
    }
}

/// `name` as the models `(id, aliases)` spell it ([`canonical_model`] for one catalog harness).
///
/// Three tiers, first hit wins: the ids and aliases themselves (`fable5.2`, `GPT 5.6`); then
/// their derived spellings (`Astra 6.2`, `gpt-6.2`, `claude`); then a family word alone, which
/// goes to that family's newest model (`astra` -> `gpt-6.2-astra`, `sol` -> `gpt-6.2-sol`). In
/// the first two tiers a key two ids share is ambiguous; in the third, only two newest of equal
/// version are.
pub fn canonical_among<'a, I>(models: I, name: &str) -> Result<Canonical, Ambiguous>
where
    I: IntoIterator<Item = (&'a str, &'a [String])>,
{
    let given = name.trim();
    let (base, suffix) = split_suffix(given);
    if base.is_empty() {
        return Ok(Canonical::unchanged(given));
    }
    let (mut listed, mut derived) = (Tier::default(), Tier::default());
    let mut families: std::collections::BTreeMap<String, Vec<(Vec<u32>, &'a str)>> =
        Default::default();
    let mut exact = false;
    for (id, aliases) in models {
        for spelling in std::iter::once(id).chain(aliases.iter().map(String::as_str)) {
            exact |= spelling == base;
            listed.add(spelling, id);
        }
        if let Some(parts) = id_parts(id) {
            for spelling in derived_spellings(&parts) {
                derived.add(&spelling, id);
            }
            if !parts.words.is_empty() {
                families.entry(parts.words.join("-")).or_default().push((parts.version, id));
            }
        }
    }
    // The catalog lists it as written: the harness takes it.
    if exact {
        return Ok(Canonical { model: given.to_owned(), given: given.to_owned(), known: true });
    }
    let found = |id: &str| Canonical {
        model: format!("{id}{suffix}"),
        given: given.to_owned(),
        known: true,
    };
    let ambiguous = |ids: &[&str]| {
        let mut choices: Vec<String> = ids.iter().map(|s| (*s).to_owned()).collect();
        choices.sort();
        Ambiguous { given: given.to_owned(), choices }
    };
    let wanted = keys(base);
    for tier in [&listed, &derived] {
        if let Some(id) = wanted.iter().find_map(|k| match tier.0.get(k).map(Vec::as_slice) {
            Some([id]) => Some(*id),
            _ => None,
        }) {
            return Ok(found(id));
        }
        if let Some(ids) = tier.find(&wanted) {
            return Err(ambiguous(ids));
        }
    }
    if let Some(members) = wanted.iter().find_map(|k| families.get(k)) {
        let newest = members.iter().map(|(v, _)| v).max().cloned().unwrap_or_default();
        let top: Vec<&str> =
            members.iter().filter(|(v, _)| *v == newest).map(|(_, id)| *id).collect();
        return match top.as_slice() {
            [id] => Ok(found(id)),
            _ => Err(ambiguous(&top)),
        };
    }
    Ok(Canonical::unchanged(given))
}

/// Whether the catalog harness `entry`'s model names are folded ([`ALIASED_HARNESSES`]).
pub fn folds_names(entry: &crate::catalog::CatalogHarness) -> bool {
    ALIASED_HARNESSES.iter().any(|h| entry.id == *h || entry.families.iter().any(|f| f == h))
}

/// `name` as the catalog harness `entry` spells it: its canonical id when one id or alias folds
/// to it, the name unchanged when none does or `entry` is not Claude Code's or Codex's, and
/// [`Ambiguous`] when it folds to more than one. This host's hot patch
/// ([`crate::model_hot_patch`], `$ACPMUX_HOME/model-aliases.json`) is read first and wins.
pub fn canonical_model(
    entry: &crate::catalog::CatalogHarness,
    name: &str,
) -> Result<Canonical, Ambiguous> {
    canonical_patched(entry, name, crate::model_hot_patch::lookup)
}

/// [`canonical_model`] with the hot patch `patch` (harness keys, name -> id).
pub(crate) fn canonical_patched<'e>(
    entry: &'e crate::catalog::CatalogHarness,
    name: &str,
    patch: impl FnOnce(Vec<&'e str>, &str) -> Option<String>,
) -> Result<Canonical, Ambiguous> {
    let given = name.trim();
    let (base, suffix) = split_suffix(given);
    let keys = std::iter::once(entry.id.as_str())
        .chain(entry.families.iter().map(String::as_str))
        .collect();
    if !base.is_empty()
        && let Some(to) = patch(keys, base)
    {
        return Ok(Canonical {
            model: format!("{to}{suffix}"),
            given: given.to_owned(),
            known: true,
        });
    }
    if !folds_names(entry) {
        return Ok(Canonical::unchanged(name.trim()));
    }
    canonical_among(
        entry.models.iter().map(|m| (m.id.as_str(), m.aliases.as_deref().unwrap_or(&[]))),
        name,
    )
}

/// The catalog harness `harness` (an id, else a family) in the copy bundled with this binary,
/// for a reader with no daemon (the CLI, the Claude Code translator).
pub fn bundled_harness(harness: &str) -> Option<crate::catalog::CatalogHarness> {
    static BUNDLED: std::sync::LazyLock<Option<crate::catalog::Catalog>> =
        std::sync::LazyLock::new(|| {
            crate::catalog::schema::parse(crate::catalog::BUNDLED.inflate().as_bytes()).ok()
        });
    let catalog = BUNDLED.as_ref()?;
    catalog
        .harnesses
        .iter()
        .find(|h| h.id == harness)
        .or_else(|| catalog.harnesses.iter().find(|h| h.families.iter().any(|f| f == harness)))
        .cloned()
}

/// Whether an agent's turn error says it does not know the model it was asked to run: Claude
/// Code's `[claude-code:unrecognized_model]` / "There's an issue with the selected model (X). It
/// may not exist or you may not have access to it", an API's `model_not_found` / "model not
/// found" / a 404 `not_found_error` naming the model, "invalid model", "unknown model", Codex's
/// "The model `X` does not exist" or "model is not supported". A model at capacity is not one.
pub fn is_model_error(error: &str) -> bool {
    let m = error.to_lowercase();
    if m.contains("at capacity") || m.contains("overloaded") {
        return false;
    }
    m.contains("unrecognized_model")
        || m.contains("issue with the selected model")
        || m.contains("may not exist or you may not have access")
        || m.contains("model_not_found")
        || m.contains("model not found")
        || m.contains("invalid model")
        || m.contains("unknown model")
        || m.contains("invalid_model")
        || (m.contains("model") && m.contains("does not exist"))
        || (m.contains("model") && m.contains("is not supported"))
        || (m.contains("model") && m.contains("not_found_error"))
        || (m.contains("model") && crate::turn_errors::has_status(&m, "404"))
}

/// The model a model error names: Claude Code's "the selected model (fable-5.2)", an API's
/// `{"model":"fable-5.2"}`, Codex's "The model `fable-5.2`".
pub fn model_named_in(error: &str) -> Option<String> {
    let after = |marker: &str, end: &[char]| {
        let at = error.find(marker)? + marker.len();
        let rest = error.get(at..)?;
        let stop = rest.find(|c: char| end.contains(&c)).unwrap_or(rest.len());
        let name = rest.get(..stop)?.trim();
        (!name.is_empty()).then(|| name.to_owned())
    };
    after("selected model (", &[')', ' '])
        .or_else(|| after("\"model\":\"", &['"']))
        .or_else(|| after("\"model\": \"", &['"']))
        .or_else(|| after("model `", &['`']))
}

#[cfg(test)]
#[path = "model_catalog_tests.rs"]
mod alias_tests;
