//! Reading an argv against a clap `Command` tree: which subcommand each word chose, which flag no
//! parser on the way knows, which word sits in a subcommand's place and is none.

use clap::{Arg, Command};
use std::collections::HashMap;

/// A flag a command reads: its spelling and whether it takes a value.
#[derive(Debug, Default)]
pub struct Opts {
    pub items: Vec<(String, bool)>,
    index: HashMap<String, usize>,
}

impl Opts {
    pub fn get(&self, name: &str) -> Option<bool> {
        self.index.get(name).and_then(|i| self.items.get(*i)).map(|(_, v)| *v)
    }
    pub fn has(&self, name: &str) -> bool {
        self.index.contains_key(name)
    }
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.items.iter().map(|(n, _)| n.as_str())
    }
    fn put(&mut self, name: String, takes: bool) {
        if !self.index.contains_key(&name) {
            self.index.insert(name.clone(), self.items.len());
            self.items.push((name, takes));
        }
    }
}

fn takes_value(arg: &Arg) -> bool {
    arg.get_action().takes_values()
}

/// Every flag spelling of `cmd` (a built command: help, version and the parents' globals are in).
pub fn options(cmd: &Command) -> Opts {
    let mut out = Opts::default();
    for arg in cmd.get_arguments() {
        let takes = takes_value(arg);
        if let Some(long) = arg.get_long() {
            out.put(format!("--{long}"), takes);
        }
        if let Some(all) = arg.get_all_aliases() {
            for a in all {
                out.put(format!("--{a}"), takes);
            }
        }
        if let Some(short) = arg.get_short() {
            out.put(format!("-{short}"), takes);
        }
        if let Some(all) = arg.get_all_short_aliases() {
            for c in all {
                out.put(format!("-{c}"), takes);
            }
        }
    }
    out
}

/// The flag `name` reads as: exact, or a short flag with its value or group glued on (`-n5`).
pub fn lookup(name: &str, known: &Opts) -> Option<bool> {
    if let Some(takes) = known.get(name) {
        return Some(takes);
    }
    if !name.starts_with("--") && name.chars().count() > 2 {
        let head: String = name.chars().take(2).collect();
        return known.get(&head);
    }
    None
}

/// The words `cmd` takes in a subcommand's place: names and aliases; `visible_only` drops the hidden
/// ones and `help`.
pub fn sub_names(cmd: &Command, visible_only: bool) -> Vec<String> {
    let mut out = Vec::new();
    for sub in cmd.get_subcommands() {
        if visible_only && (sub.is_hide_set() || sub.get_name() == "help") {
            continue;
        }
        out.push(sub.get_name().to_owned());
        out.extend(sub.get_all_aliases().map(str::to_owned));
    }
    out
}

pub fn is_number(tok: &str) -> bool {
    tok.parse::<f64>().is_ok()
}

pub struct Level<'a> {
    pub cmd: &'a Command,
    /// The index just after this level's subcommand word (0 for the root).
    pub start: usize,
    /// The index of the subcommand word chosen at this level; None at the last.
    pub sub: Option<usize>,
}

pub struct Walk<'a> {
    pub levels: Vec<Level<'a>>,
    /// A word in a subcommand's place that is none.
    pub bad_sub: Option<usize>,
    /// (index, level) of flags no parser on the way knows there.
    pub unknown: Vec<(usize, usize)>,
    pub positionals: Vec<usize>,
}

pub fn walk<'a>(root: &'a Command, argv: &[String]) -> Walk<'a> {
    let mut levels = vec![Level { cmd: root, start: 0, sub: None }];
    let (mut unknown, mut positionals, mut bad_sub) = (Vec::new(), Vec::new(), None);
    let mut cur = root;
    let mut known = options(cur);
    let mut room = cur.get_positionals().count();
    let mut i = 0;
    while i < argv.len() {
        let Some(tok) = argv.get(i) else { break };
        if tok == "--" {
            positionals.extend(i + 1..argv.len());
            break;
        }
        if tok.starts_with('-') && tok.len() > 1 && !is_number(tok) {
            let (name, eq) = tok.split_once('=').map_or((tok.as_str(), false), |(n, _)| (n, true));
            match lookup(name, &known) {
                None if bad_sub.is_some() => {} // whose flag it is cannot be read yet
                None => unknown.push((i, levels.len() - 1)),
                Some(takes) => {
                    if !eq && takes && (name.chars().count() <= 2 || name.starts_with("--")) {
                        i += 1;
                    }
                }
            }
            i += 1;
            continue;
        }
        let has_subs = cur.get_subcommands().next().is_some();
        if has_subs && bad_sub.is_none() {
            if let Some(next) = cur.find_subcommand(tok) {
                if let Some(level) = levels.last_mut() {
                    level.sub = Some(i);
                }
                cur = next;
                known = options(cur);
                room = cur.get_positionals().count();
                levels.push(Level { cmd: cur, start: i + 1, sub: None });
            } else if room > 0 {
                room -= 1;
                positionals.push(i);
            } else if cur.is_allow_external_subcommands_set() {
                positionals.push(i);
            } else {
                bad_sub = Some(i);
                positionals.push(i);
            }
        } else {
            positionals.push(i);
        }
        i += 1;
    }
    Walk { levels, bad_sub, unknown, positionals }
}

/// The subcommand words typed on the way (the last level has none).
pub fn typed_path(walk: &Walk<'_>, argv: &[String]) -> Vec<String> {
    walk.levels.iter().filter_map(|l| l.sub.and_then(|s| argv.get(s)).cloned()).collect()
}

/// The canonical subcommand names on the way.
pub fn canonical_path(walk: &Walk<'_>) -> Vec<String> {
    walk.levels.iter().skip(1).map(|l| l.cmd.get_name().to_owned()).collect()
}
