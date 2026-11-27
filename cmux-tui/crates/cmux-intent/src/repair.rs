//! `repair`: what an argv a clap `Command` refuses meant. Edits are generated in class order (table
//! alias, synonym, spelling, glued, placement, order, missing verb, close match), each kept only if
//! the whole argv then parses (a trial parse), up to `MAX_EDITS` composed.

use crate::close::{close_matches, shell_join};
use crate::table::Table;
use crate::walk::{self, Opts, Walk, is_number, options, sub_names};
use clap::Command;
use clap::error::{ContextKind, ContextValue, ErrorKind};
use std::collections::VecDeque;

pub const CUTOFF: f64 = 0.75;
pub const MAX_STATES: usize = 40;
pub const MAX_EDITS: usize = 4;
pub const MAX_SHOWN: usize = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub argv: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// The argv parses: nothing to repair.
    Ok,
    /// One form meant: `argv` is it, to run.
    Ran,
    /// Two or three forms could be meant: listed, nothing runs.
    Candidates,
    /// One form meant but it is destructive or outward: its exact form is needed, nothing runs.
    Exact,
    /// Nothing clear was meant.
    None,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Ok => "ok",
            Kind::Ran => "ran",
            Kind::Candidates => "candidates",
            Kind::Exact => "exact",
            Kind::None => "none",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Repair {
    pub outcome: Kind,
    /// The argv to run (Ran), else the argv as given.
    pub argv: Vec<String>,
    pub candidates: Vec<Candidate>,
    /// The refusal that started it.
    pub error: String,
    /// The destructive or outward word (Exact).
    pub word: Option<String>,
}

type Edit = (&'static str, Vec<String>, String);

/// Whether clap's refusal is one the layer reads (never help or version).
pub fn eligible(kind: ErrorKind) -> bool {
    matches!(
        kind,
        ErrorKind::UnknownArgument
            | ErrorKind::InvalidSubcommand
            | ErrorKind::InvalidValue
            | ErrorKind::MissingRequiredArgument
            | ErrorKind::MissingSubcommand
            | ErrorKind::WrongNumberOfValues
            | ErrorKind::TooManyValues
            | ErrorKind::TooFewValues
            | ErrorKind::ValueValidation
            | ErrorKind::ArgumentConflict
            | ErrorKind::NoEquals
    )
}

/// `None` when `cmd` takes `argv` (help and version parse), else clap's refusal.
fn trial(cmd: &mut Command, prog: &str, argv: &[String]) -> Option<clap::Error> {
    let full: Vec<String> = std::iter::once(prog.to_owned()).chain(argv.iter().cloned()).collect();
    match cmd.try_get_matches_from_mut(full) {
        Ok(_) => None,
        // A group named with no subcommand only prints its help: no form that runs.
        Err(e)
            if eligible(e.kind())
                || e.kind() == ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand =>
        {
            Some(e)
        }
        Err(_) => None,
    }
}

pub(crate) fn norm_flag(name: &str) -> Vec<String> {
    let body = name.trim_start_matches('-');
    let mut snake = String::new();
    for c in body.chars() {
        if c.is_uppercase() {
            snake.push('-');
            snake.extend(c.to_lowercase());
        } else {
            snake.push(c);
        }
    }
    let mut out: Vec<String> = Vec::new();
    for cand in
        [body.replace('_', "-"), snake.trim_start_matches('-').to_owned(), body.to_lowercase()]
    {
        for dashes in ["--", "-"] {
            let one = format!("{dashes}{cand}");
            if one != name && !out.contains(&one) {
                out.push(one);
            }
        }
    }
    out
}

fn close(word: &str, known: &[String]) -> Vec<String> {
    close_matches(word, known, MAX_SHOWN, CUTOFF)
}

fn dedup(mut v: Vec<String>) -> Vec<String> {
    let mut seen = Vec::new();
    v.retain(|x| {
        let new = !seen.contains(x);
        seen.push(x.clone());
        new
    });
    v
}

// ---- the edits --------------------------------------------------------------------------------------------

/// Edits for the first flag no parser on the way knows.
fn flag_edits(argv: &[String], walk: &Walk<'_>, tbl: &Table) -> Vec<Edit> {
    let Some(&(i, level)) = walk.unknown.first() else { return Vec::new() };
    let Some(tok) = argv.get(i) else { return Vec::new() };
    let (name, eq, value) = match tok.split_once('=') {
        Some((n, v)) => (n.to_owned(), "=", v.to_owned()),
        None => (tok.clone(), "", String::new()),
    };
    let opts_of = |at: usize| walk.levels.get(at).map(|l| options(l.cmd)).unwrap_or_default();
    let mut out: Vec<Edit> = Vec::new();

    let put = |class: &'static str, new_name: &str, at: usize, out: &mut Vec<Edit>| {
        let takes = opts_of(at).get(new_name).unwrap_or(false);
        let take = if eq.is_empty() && takes && i + 1 < argv.len() { 2 } else { 1 };
        let mut chunk = vec![format!("{new_name}{eq}{value}")];
        chunk.extend(argv.iter().skip(i + 1).take(take - 1).cloned());
        let mut rest: Vec<String> = argv.iter().take(i).cloned().collect();
        rest.extend(argv.iter().skip(i + take).cloned());
        let at_sub = |l: usize| walk.levels.get(l).and_then(|lv| lv.sub).unwrap_or(0);
        let (new, note) = if at == level {
            let mut new: Vec<String> = argv.iter().take(i).cloned().collect();
            new.extend(chunk);
            new.extend(argv.iter().skip(i + take).cloned());
            (new, format!("{new_name} for {name}"))
        } else if at < level {
            // An ancestor's flag: before that level's subcommand word.
            let pos = at_sub(at);
            let mut new: Vec<String> = rest.iter().take(pos).cloned().collect();
            new.extend(chunk);
            new.extend(rest.iter().skip(pos).cloned());
            let word = argv.get(pos).cloned().unwrap_or_default();
            let tail = if new_name == name { String::new() } else { format!(" (for {name})") };
            (new, format!("{new_name} moved before `{word}`{tail}"))
        } else {
            // The chosen subcommand's flag typed before it: after the subcommand word.
            let start = walk.levels.get(at).map_or(0, |lv| lv.start);
            let pos = start.saturating_sub(take);
            let mut new: Vec<String> = rest.iter().take(pos).cloned().collect();
            new.extend(chunk);
            new.extend(rest.iter().skip(pos).cloned());
            let word = argv.get(start.saturating_sub(1)).cloned().unwrap_or_default();
            let tail = if new_name == name { String::new() } else { format!(" (for {name})") };
            (new, format!("{new_name} moved after `{word}`{tail}"))
        };
        out.push((class, new, note));
    };

    // (class, option) NAME may mean among `known`, best class first, one class only.
    let spellings = |known: &Opts| -> Vec<(&'static str, String)> {
        if let Some(n) = norm_flag(&name).into_iter().find(|c| known.has(c)) {
            return vec![("spelling", n)];
        }
        if name.starts_with("--") && name.len() > 2 {
            let pre: Vec<String> =
                known.names().filter(|k| k.starts_with(&name)).map(str::to_owned).collect();
            if let [one] = pre.as_slice() {
                return vec![("spelling", one.clone())];
            }
        }
        let syn: Vec<String> = tbl
            .mates(&name, true)
            .into_iter()
            .filter(|m| known.has(m))
            .map(str::to_owned)
            .collect();
        if !syn.is_empty() {
            return dedup(syn).into_iter().map(|m| ("synonym", m)).collect();
        }
        let same: Vec<String> = known
            .names()
            .filter(|k| k.starts_with("--") == name.starts_with("--"))
            .map(str::to_owned)
            .collect();
        close(&name, &same).into_iter().map(|m| ("close", m)).collect()
    };

    for (class, opt) in spellings(&opts_of(level)) {
        put(class, &opt, level, &mut out);
    }
    if out.is_empty() {
        // A flag another parser on the way owns, as typed or respelled.
        let order: Vec<usize> = (0..level).rev().chain(level + 1..walk.levels.len()).collect();
        for at in order {
            let known = opts_of(at);
            if known.has(&name) {
                put("placement", &name, at, &mut out);
            } else if let Some((class, opt)) = spellings(&known).into_iter().next()
                && class != "close"
            {
                put("placement", &opt, at, &mut out);
            }
            if !out.is_empty() {
                break;
            }
        }
    }
    if out.is_empty()
        && eq.is_empty()
        && level + 1 == walk.levels.len()
        && let Some(lv) = walk.levels.get(level)
    {
        let word = name.trim_start_matches('-');
        if lv.cmd.find_subcommand(word).is_some() {
            // `land --status X`: the flag names the subcommand.
            let mut new: Vec<String> = argv.iter().take(i).cloned().collect();
            new.push(word.to_owned());
            new.extend(argv.iter().skip(i + 1).cloned());
            out.push(("glued", new, format!("subcommand `{word}` for {name}")));
        }
    }
    out
}

/// Edits for a word in a subcommand's place that is no subcommand.
fn sub_edits(argv: &[String], walk: &Walk<'_>, tbl: &Table, prog: &str) -> Vec<Edit> {
    let Some(i) = walk.bad_sub else { return Vec::new() };
    let Some(tok) = argv.get(i).cloned() else { return Vec::new() };
    let Some(level) = walk.levels.last() else { return Vec::new() };
    let cmd = level.cmd;
    let choices = sub_names(cmd, true);
    let mut out: Vec<Edit> = Vec::new();
    let swap =
        |class: &'static str, words: &[String], note: String, take: usize, out: &mut Vec<Edit>| {
            let mut new: Vec<String> = argv.iter().take(i).cloned().collect();
            new.extend(words.iter().cloned());
            new.extend(argv.iter().skip(i + take).cloned());
            out.push((class, new, note));
        };
    let path = walk::typed_path(walk, argv);
    let entry = tbl.cli_entry(prog);
    for rule in entry.map(|e| e.aliases.as_slice()).unwrap_or_default() {
        let (from, to) = (&rule.from, &rule.to);
        if !from.is_empty()
            && rule.under == path
            && argv.get(i..i + from.len()) == Some(from.as_slice())
        {
            swap(
                "table",
                to,
                format!("`{}` for `{}`", to.join(" "), from.join(" ")),
                from.len(),
                &mut out,
            );
        }
    }
    if !out.is_empty() {
        return out;
    }
    // A synonym may name a hidden subcommand: it still parses (`inspect` -> the hidden top-level `info`).
    let all = sub_names(cmd, false);
    let syn: Vec<String> = tbl
        .mates(&tok, false)
        .into_iter()
        .filter(|m| *m != "help" && all.iter().any(|c| c == m))
        .map(str::to_owned)
        .collect();
    for m in dedup(syn) {
        swap("synonym", std::slice::from_ref(&m), format!("`{m}` for `{tok}`"), 1, &mut out);
    }
    if !out.is_empty() {
        return out;
    }
    for sep in ['-', '_', ':', '/', '.'] {
        // `land-status` for `land status`
        let Some((head, tail)) = tok.split_once(sep) else { continue };
        if tail.is_empty() {
            continue;
        }
        let inner =
            |name: &str| cmd.find_subcommand(name).map(|c| sub_names(c, false)).unwrap_or_default();
        if choices.iter().any(|c| c == head) && inner(head).iter().any(|c| c == tail) {
            swap(
                "glued",
                &[head.to_owned(), tail.to_owned()],
                format!("`{head} {tail}` for `{tok}`"),
                1,
                &mut out,
            );
        }
        if choices.iter().any(|c| c == tail) && inner(tail).iter().any(|c| c == head) {
            swap(
                "glued",
                &[tail.to_owned(), head.to_owned()],
                format!("`{tail} {head}` for `{tok}`"),
                1,
                &mut out,
            );
        }
    }
    if !out.is_empty() {
        return out;
    }
    let prefixed: Vec<String> = choices.iter().filter(|c| c.starts_with(&tok)).cloned().collect();
    if let [one] = prefixed.as_slice() {
        swap("spelling", &prefixed, format!("`{one}` for `{tok}`"), 1, &mut out);
        return out;
    }
    for m in close(&tok, &choices) {
        swap("close", std::slice::from_ref(&m), format!("`{m}` for `{tok}`"), 1, &mut out);
    }
    if !out.is_empty() {
        return out;
    }
    // A subcommand word typed later: `REPO status`, `pr status` for `status pr`.
    if let Some((j, word)) = walk
        .positionals
        .iter()
        .filter(|&&j| j > i)
        .find_map(|&j| argv.get(j).filter(|w| choices.contains(w)).map(|w| (j, w)))
    {
        let mut moved: Vec<String> = argv.iter().take(i).cloned().collect();
        moved.push(word.clone());
        moved.extend(argv.iter().skip(i).take(j.saturating_sub(i)).cloned());
        moved.extend(argv.iter().skip(j.saturating_add(1)).cloned());
        out.push(("order", moved, format!("`{word}` moved before `{tok}`")));
    }
    let default = entry.and_then(|e| e.default.as_ref()).and_then(|d| match d {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Object(m) => {
            m.get(&path.join(" ")).and_then(|v| v.as_str()).map(str::to_owned)
        }
        _ => None,
    });
    match default {
        Some(d) if choices.contains(&d) => {
            swap(
                "missing verb",
                std::slice::from_ref(&d),
                format!("`{d}` (the default verb)"),
                0,
                &mut out,
            );
        }
        // A word shaped like a command (letters, `-`, `_`) is a mistyped verb, not the rest a
        // verb takes: `acpmux whoami` never runs `acpmux wait whoami`. The table's default still applies.
        _ if out.is_empty() && !command_shaped(&tok) => {
            for c in cmd.get_subcommands().filter(|c| !c.is_hide_set() && c.get_name() != "help") {
                let word = c.get_name().to_owned();
                let mut full = path.clone();
                full.push(word.clone());
                let reads =
                    tbl.reads.contains(&word) || entry.is_some_and(|e| e.safe.contains(&word));
                if reads && !tbl.exact_path(prog, &full) {
                    swap(
                        "missing verb",
                        std::slice::from_ref(&word),
                        format!("`{word}` (the one verb that takes the rest)"),
                        0,
                        &mut out,
                    );
                }
            }
        }
        _ => {}
    }
    out
}

/// Whether `word` reads as a command name: letters joined by `-` or `_`, no digits, paths or
/// addresses (`whoami`, `send_status`; not `11296`, `lane-1`, `o/r#1`).
fn command_shaped(word: &str) -> bool {
    word.chars().any(|c| c.is_alphabetic())
        && word.chars().all(|c| c.is_alphabetic() || c == '-' || c == '_')
}

fn context_string(e: &clap::Error, kind: ContextKind) -> Option<String> {
    match e.get(kind)? {
        ContextValue::String(s) => Some(s.clone()),
        ContextValue::Strings(v) => v.first().cloned(),
        _ => None,
    }
}

fn permutations(n: usize) -> Vec<Vec<usize>> {
    fn go(left: &mut Vec<usize>, cur: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
        if left.is_empty() {
            out.push(cur.clone());
            return;
        }
        for k in 0..left.len() {
            let x = left.remove(k);
            cur.push(x);
            go(left, cur, out);
            cur.pop();
            left.insert(k, x);
        }
    }
    let mut out = Vec::new();
    go(&mut (0..n).collect(), &mut Vec::new(), &mut out);
    out
}

/// Edits for a refusal the argv's shape does not show: a value outside its choices, positionals out of order.
fn message_edits(argv: &[String], walk: &Walk<'_>, err: &clap::Error, tbl: &Table) -> Vec<Edit> {
    let mut out: Vec<Edit> = Vec::new();
    if err.kind() == ErrorKind::InvalidValue
        && let Some(tok) = context_string(err, ContextKind::InvalidValue)
    {
        let choices: Vec<String> = match err.get(ContextKind::ValidValue) {
            Some(ContextValue::Strings(v)) => v.clone(),
            _ => Vec::new(),
        };
        let at = argv.iter().position(|a| *a == tok || a.ends_with(&format!("={tok}")));
        if let (Some(i), false) = (at, choices.is_empty()) {
            let mut class = "synonym";
            let mut cands: Vec<String> = tbl
                .mates(&tok, false)
                .into_iter()
                .filter(|m| choices.iter().any(|c| c == m))
                .map(str::to_owned)
                .collect();
            if cands.is_empty() {
                class = "spelling";
                let pre: Vec<String> =
                    choices.iter().filter(|c| c.starts_with(&tok)).cloned().collect();
                cands = if pre.len() == 1 { pre } else { Vec::new() };
            }
            if cands.is_empty() {
                class = "close";
                cands = close(&tok, &choices);
            }
            for m in dedup(cands) {
                let mut new = argv.to_vec();
                if let Some(slot) = new.get_mut(i) {
                    *slot = match slot.strip_suffix(tok.as_str()) {
                        Some(head) if head.ends_with('=') => format!("{head}{m}"),
                        _ => m.clone(),
                    };
                }
                out.push((class, new, format!("`{m}` for `{tok}`")));
            }
        }
    }
    if out.is_empty() {
        let start = walk.levels.last().map_or(0, |l| l.start);
        let pos: Vec<usize> = walk.positionals.iter().copied().filter(|&i| i >= start).collect();
        if (2..=4).contains(&pos.len()) {
            for perm in permutations(pos.len()) {
                if perm.iter().enumerate().any(|(a, b)| a != *b) {
                    let mut new = argv.to_vec();
                    for (slot, src) in pos.iter().zip(&perm) {
                        let word = pos.get(*src).and_then(|&p| argv.get(p));
                        if let (Some(dst), Some(word)) = (new.get_mut(*slot), word) {
                            dst.clone_from(word);
                        }
                    }
                    if new != argv {
                        out.push(("order", new, "positionals reordered".to_owned()));
                    }
                }
            }
        }
    }
    out
}

/// The word that makes `argv` destructive or outward (its form must be exact), else None.
fn unsafe_in(root: &Command, argv: &[String], tbl: &Table, prog: &str) -> Option<String> {
    let walk = walk::walk(root, argv);
    let typed = walk::typed_path(&walk, argv);
    let canon = walk::canonical_path(&walk);
    let entry = tbl.cli_entry(prog);
    let exact = entry.map(|e| e.exact.as_slice()).unwrap_or_default();
    for path in [&typed, &canon] {
        for n in (1..=path.len()).rev() {
            let Some(prefix) = path.get(..n) else { continue };
            let head = prefix.join(" ");
            if exact.contains(&head) {
                return Some(head);
            }
        }
    }
    let safe = entry.map(|e| e.safe.as_slice()).unwrap_or_default();
    let mut words: Vec<String> = Vec::new();
    for path in [&typed, &canon] {
        let leaf_read = path.len() > 1 && path.last().is_some_and(|w| tbl.reads.contains(w));
        if !leaf_read {
            words.extend(path.iter().filter(|w| !safe.contains(w)).cloned());
        }
    }
    let end = argv.iter().position(|a| a == "--").unwrap_or(argv.len());
    words.extend(argv.iter().take(end).filter(|t| t.starts_with('-') && !is_number(t)).cloned());
    words.into_iter().find(|w| tbl.unsafe_word(w))
}

fn error_text(e: &clap::Error) -> String {
    e.to_string().lines().next().unwrap_or_default().trim_start_matches("error: ").to_owned()
}

/// What `argv` (the words after the program name), which `cmd` refuses, meant.
pub fn repair(cmd: &Command, prog: &str, argv: &[String], tbl: &Table) -> Repair {
    // `prog` is the CLI's key in the table's `cli` part; the trial parses name the command as it is.
    let mut built = cmd.clone();
    built.build();
    let name = cmd.get_name().to_owned();
    let name = name.as_str();
    let mut trial_cmd = built.clone();
    let argv = argv.to_vec();
    let Some(first) = trial(&mut trial_cmd, name, &argv) else {
        return Repair {
            outcome: Kind::Ok,
            argv,
            candidates: Vec::new(),
            error: String::new(),
            word: None,
        };
    };
    let first_text = error_text(&first);
    let mut seen = vec![argv.clone()];
    let mut queue = VecDeque::from([(argv.clone(), Vec::<String>::new(), first)]);
    let mut parsed: Vec<Candidate> = Vec::new();
    let mut tried = 0;
    while let Some((cur, notes, err)) = queue.pop_front() {
        if tried >= MAX_STATES {
            break;
        }
        if notes.len() >= MAX_EDITS {
            continue;
        }
        let w = walk::walk(&built, &cur);
        let edits = if !w.unknown.is_empty() {
            flag_edits(&cur, &w, tbl)
        } else if w.bad_sub.is_some()
            && matches!(
                err.kind(),
                ErrorKind::InvalidSubcommand
                    | ErrorKind::MissingRequiredArgument
                    | ErrorKind::MissingSubcommand
            )
        {
            sub_edits(&cur, &w, tbl, prog)
        } else {
            message_edits(&cur, &w, &err, tbl)
        };
        let Some(best) = edits.first().map(|e| e.0) else { continue };
        for (class, new, note) in edits {
            if class != best || seen.contains(&new) {
                continue;
            }
            seen.push(new.clone());
            tried += 1;
            let mut notes = notes.clone();
            notes.push(note);
            match trial(&mut trial_cmd, name, &new) {
                None => parsed.push(Candidate { argv: new, notes }),
                Some(again) => queue.push_back((new, notes, again)),
            }
        }
    }
    if parsed.is_empty() {
        return Repair {
            outcome: Kind::None,
            argv,
            candidates: Vec::new(),
            error: first_text,
            word: None,
        };
    }
    let fewest = parsed.iter().map(|p| p.notes.len()).min().unwrap_or(0);
    parsed.retain(|p| p.notes.len() == fewest);
    // Two names of one command (`whoelse`, `who-else`) are one meaning, not a choice: a name the
    // layer supplied is the command's own; a name the person typed (`peer` for `machine`) stays.
    let mut seen: Vec<Vec<String>> = Vec::new();
    parsed.retain_mut(|p| {
        let key = canonical_argv(&built, &p.argv);
        let fresh = !seen.contains(&key);
        seen.push(key.clone());
        for (slot, now) in p.argv.iter_mut().zip(&key) {
            if slot == now || argv.contains(slot) {
                continue;
            }
            for n in &mut p.notes {
                *n = n.replace(&format!("`{slot}`"), &format!("`{now}`"));
            }
            now.clone_into(slot);
        }
        fresh
    });
    parsed.truncate(MAX_SHOWN);
    if let [only] = parsed.as_slice() {
        let word = unsafe_in(&built, &only.argv, tbl, prog)
            .or_else(|| argv.iter().find(|w| w.starts_with('-') && tbl.unsafe_word(w)).cloned())
            .or_else(|| supplied_write(&built, &argv, &only.argv, tbl, prog));
        if let Some(word) = word {
            return Repair {
                outcome: Kind::Exact,
                argv,
                candidates: parsed,
                error: first_text,
                word: Some(word),
            };
        }
        return Repair {
            outcome: Kind::Ran,
            argv: only.argv.clone(),
            candidates: parsed,
            error: first_text,
            word: None,
        };
    }
    if let Some(first_parsed) = parsed.first().cloned()
        && parsed.iter().all(|p| read_only(&built, &p.argv, tbl, prog))
        && !argv.iter().take_while(|a| *a != "--").any(|w| w.starts_with('-') && tbl.unsafe_word(w))
    {
        let also = parsed
            .iter()
            .skip(1)
            .map(|p| {
                format!(
                    "`{}`",
                    shell_join(
                        &std::iter::once(prog.to_owned())
                            .chain(p.argv.iter().cloned())
                            .collect::<Vec<_>>()
                    )
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        let mut best = first_parsed;
        best.notes.push(format!("the best of {} read-only forms; also {also}", parsed.len()));
        return Repair {
            outcome: Kind::Ran,
            argv: best.argv.clone(),
            candidates: vec![best],
            error: first_text,
            word: None,
        };
    }
    Repair { outcome: Kind::Candidates, argv, candidates: parsed, error: first_text, word: None }
}

/// `argv` with each subcommand word as its command's own name (an alias as what it names).
fn canonical_argv(root: &Command, argv: &[String]) -> Vec<String> {
    let walk = walk::walk(root, argv);
    let mut out = argv.to_vec();
    for (k, level) in walk.levels.iter().enumerate() {
        if let (Some(i), Some(next)) = (level.sub, walk.levels.get(k + 1))
            && let Some(slot) = out.get_mut(i)
        {
            next.cmd.get_name().clone_into(slot);
        }
    }
    out
}

fn reading(word: &str, prog: &str, tbl: &Table) -> bool {
    tbl.reads.iter().any(|r| r == word)
        || tbl.cli_entry(prog).is_some_and(|e| e.safe.iter().any(|s| s == word))
}

/// The word the layer would supply that is not a known read, else None. A word it puts in (a subcommand or a
/// choice: `docs pull` -> `docs sync`, `keepupp` -> `keepup`) runs only when it is a read (the table's `reads` or
/// the CLI's `safe`), or sits in a subcommand path that ends in one (`land-status` -> `land status`): a write's
/// verb is never supplied. Flags and reordering supply no new word, and neither does respelling a typed word's
/// separators or case (`who_else` -> `who-else`): the person typed it. Twin of `_supplied_write` in
/// tools/intent.py.
fn supplied_write(
    root: &Command,
    typed: &[String],
    new: &[String],
    tbl: &Table,
    prog: &str,
) -> Option<String> {
    let mut added: Vec<String> =
        new.iter().filter(|t| !t.starts_with('-')).map(|t| bare(t)).collect();
    for t in typed.iter().filter(|t| !t.starts_with('-')) {
        if let Some(i) = added.iter().position(|a| *a == bare(t)) {
            added.remove(i);
        }
    }
    if added.is_empty() {
        return None;
    }
    let w = walk::walk(root, new);
    let subs: Vec<usize> = w.levels.iter().filter_map(|l| l.sub).collect();
    let reads = |i: usize| new.get(i).is_some_and(|w| reading(w, prog, tbl));
    let reads_at = subs.iter().copied().find(|&i| reads(i));
    let leaf_reads = subs.last().is_some_and(|&i| reads(i));
    let ok =
        |i: usize| reads(i) || leaf_reads || reads_at.is_some_and(|r| !subs.contains(&i) || i > r);
    for (i, word) in new.iter().enumerate() {
        if word.starts_with('-') {
            continue;
        }
        if let Some(k) = added.iter().position(|a| *a == bare(word)) {
            added.remove(k);
            if !ok(i) {
                return Some(word.clone());
            }
        }
    }
    None
}

/// `word` without its separators or case: `who_else`, `who-else` and `WhoElse` are one typed word.
fn bare(word: &str) -> String {
    word.chars().filter(|c| *c != '-' && *c != '_').flat_map(char::to_lowercase).collect()
}

/// Whether `argv` runs a subcommand that only reads: its last subcommand word is in `reads` or the CLI's
/// `safe`, it is not exact, and it holds no unsafe word. A CLI with no subcommand is never read-only.
fn read_only(root: &Command, argv: &[String], tbl: &Table, prog: &str) -> bool {
    let walk = walk::walk(root, argv);
    let path = walk::typed_path(&walk, argv);
    let Some(last) = path.last() else { return false };
    if tbl.exact_path(prog, &path) || unsafe_in(root, argv, tbl, prog).is_some() {
        return false;
    }
    tbl.reads.contains(last) || tbl.cli_entry(prog).is_some_and(|e| e.safe.contains(last))
}
