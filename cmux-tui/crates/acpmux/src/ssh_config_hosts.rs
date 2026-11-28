//! The concrete hosts of `~/.ssh/config` and the files it includes, with each one's `HostName`,
//! read the way ssh reads them (moved from cmux-tui's machine_runtime.rs so the daemon's
//! `_acpmux/machine_candidates` and `cmux device list` read the same list).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

const SSH_CONFIG_MAX_DEPTH: usize = 16;
const SSH_CONFIG_MAX_FILES: usize = 256;
const SSH_CONFIG_MAX_HOSTS: usize = 4096;

/// The concrete `Host` names of `~/.ssh/config` and the files it includes,
/// in file order (no patterns, no negations).
pub fn ssh_config_hosts() -> Vec<String> {
    ssh_config_targets().into_iter().map(|host| host.alias).collect()
}

/// One concrete `Host` of the ssh config and the `HostName` its own
/// `Host` blocks give it (`%h` replaced by the alias; the first one wins,
/// as ssh takes it, an `Include` read where it stands and inside the block
/// it is in). Wildcard blocks and `Match` are not read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SshConfigHost {
    pub alias: String,
    pub host_name: Option<String>,
}

/// [`ssh_config_hosts`] with each host's `HostName`.
pub fn ssh_config_targets() -> Vec<SshConfigHost> {
    let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) else {
        return Vec::new();
    };
    let home = PathBuf::from(home);
    let ssh_root = home.join(".ssh");
    ssh_config_targets_from_path(&ssh_root.join("config"), &ssh_root, &home)
}

#[cfg(test)]
fn ssh_config_hosts_from_path(config: &Path, ssh_root: &Path, home: &Path) -> Vec<String> {
    ssh_config_targets_from_path(config, ssh_root, home).into_iter().map(|h| h.alias).collect()
}

fn ssh_config_targets_from_path(config: &Path, ssh_root: &Path, home: &Path) -> Vec<SshConfigHost> {
    let mut discovery = SshConfigDiscovery {
        ssh_root,
        home,
        visited: HashSet::new(),
        seen_hosts: HashSet::new(),
        hosts: Vec::new(),
    };
    discovery.visit(config, 0);
    let mut names = HostNames {
        ssh_root,
        home,
        read: 0,
        chain: Vec::new(),
        seen: 0,
        names: HashMap::new(),
        every: None,
    };
    names.read(config, &mut None, None);
    let (every, mut host_names) = (names.every, names.names);
    discovery
        .hosts
        .into_iter()
        .map(|alias| {
            // ssh takes the first HostName that holds for the host, in the
            // order the lines are read (an Include where it stands).
            let key = alias.to_ascii_lowercase();
            let own = host_names.remove(&key);
            let host_name = match (&every, own) {
                (Some((at, name)), own) if own.as_ref().is_none_or(|(o, _)| at < o) => {
                    Some(name.replace("%h", &key))
                }
                (_, own) => own.map(|(_, name)| name),
            };
            SshConfigHost { alias, host_name }
        })
        .collect()
}

struct SshConfigDiscovery<'a> {
    ssh_root: &'a Path,
    home: &'a Path,
    visited: HashSet<PathBuf>,
    seen_hosts: HashSet<String>,
    hosts: Vec<String>,
}

impl SshConfigDiscovery<'_> {
    fn visit(&mut self, path: &Path, depth: usize) {
        if depth > SSH_CONFIG_MAX_DEPTH
            || self.visited.len() >= SSH_CONFIG_MAX_FILES
            || self.hosts.len() >= SSH_CONFIG_MAX_HOSTS
        {
            return;
        }
        let identity = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if !self.visited.insert(identity) {
            return;
        }
        let Ok(contents) = fs::read_to_string(path) else { return };
        let mut includes = Vec::new();
        for (keyword, values) in contents.lines().filter_map(ssh_config_line) {
            match keyword.as_str() {
                "host" => {
                    for host in values {
                        if self.hosts.len() >= SSH_CONFIG_MAX_HOSTS {
                            return;
                        }
                        if is_concrete_ssh_host(&host)
                            && self.seen_hosts.insert(host.to_ascii_lowercase())
                        {
                            self.hosts.push(host);
                        }
                    }
                }
                "include" => includes.extend(values),
                _ => {}
            }
        }
        // The root file is the user's curated catalog. Included files are
        // often generated inventories, so list direct aliases first while
        // still following every include for discovery and de-duplication.
        for pattern in includes {
            for included in expand_ssh_include(&pattern, self.ssh_root, self.home) {
                self.visit(&included, depth.saturating_add(1));
            }
        }
    }
}

/// Each concrete alias's first `HostName`, read the way ssh reads it: an
/// `Include` where it stands, and only for the hosts of the `Host` block
/// around it (a `Host` line in the included file narrows that, for the rest
/// of that file).
struct HostNames<'a> {
    ssh_root: &'a Path,
    home: &'a Path,
    /// Files read so far, against [`SSH_CONFIG_MAX_FILES`].
    read: usize,
    /// The include chain being read, so a cycle stops.
    chain: Vec<PathBuf>,
    /// `HostName` lines read so far, so the first one for a host wins.
    seen: usize,
    /// By lowercased alias: where its first `HostName` was read, and it.
    names: HashMap<String, (usize, String)>,
    /// The first `HostName` before any `Host` line, which ssh gives every
    /// host (`%h` not yet replaced), and where it was read.
    every: Option<(usize, String)>,
}

impl HostNames<'_> {
    /// `block`: the concrete aliases of the `Host` block being read (none in
    /// a `Match` block, or one whose names are all patterns; `None` before
    /// the first `Host` line, where a line holds for every host). `gate`: the
    /// hosts an enclosing `Include` holds for (`None`: every host).
    fn read(&mut self, path: &Path, block: &mut Option<Vec<String>>, gate: Option<&[String]>) {
        if self.chain.len() > SSH_CONFIG_MAX_DEPTH || self.read >= SSH_CONFIG_MAX_FILES {
            return;
        }
        let identity = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if self.chain.contains(&identity) {
            return;
        }
        let Ok(contents) = fs::read_to_string(path) else { return };
        self.read += 1;
        self.chain.push(identity);
        for (keyword, values) in contents.lines().filter_map(ssh_config_line) {
            match keyword.as_str() {
                "host" => {
                    // A negated pattern (`!lab`, `!*.corp`) keeps the block
                    // from every host it matches, as ssh reads it.
                    let negated: Vec<String> = values
                        .iter()
                        .filter_map(|v| v.strip_prefix('!'))
                        .map(str::to_ascii_lowercase)
                        .collect();
                    *block = Some(
                        values
                            .into_iter()
                            .filter(|h| is_concrete_ssh_host(h))
                            .map(|h| h.to_ascii_lowercase())
                            .filter(|h| !negated.iter().any(|n| ssh_pattern_matches(n, h)))
                            .filter(|h| gate.is_none_or(|g| g.contains(h)))
                            .collect(),
                    );
                }
                "match" => *block = Some(Vec::new()),
                "hostname" => {
                    let Some(name) = values.into_iter().next() else { continue };
                    self.seen += 1;
                    let at = self.seen;
                    let Some(aliases) = block.as_ref() else {
                        // Before any Host line, outside any Include gate:
                        // every host's (an Include's gate is its block).
                        if gate.is_none() {
                            self.every.get_or_insert((at, name));
                        }
                        continue;
                    };
                    for alias in aliases {
                        self.names
                            .entry(alias.clone())
                            .or_insert_with(|| (at, name.replace("%h", alias)));
                    }
                }
                "include" => {
                    // The included lines hold for the block's hosts only.
                    let inner_gate = block.clone().or_else(|| gate.map(<[String]>::to_vec));
                    for pattern in values {
                        for included in expand_ssh_include(&pattern, self.ssh_root, self.home) {
                            let mut inner = block.clone();
                            self.read(&included, &mut inner, inner_gate.as_deref());
                        }
                    }
                }
                _ => {}
            }
        }
        self.chain.pop();
    }
}

/// An `Include` argument's files: `~` is the home, a relative path is under
/// `~/.ssh`, and globs expand.
fn expand_ssh_include(pattern: &str, ssh_root: &Path, home: &Path) -> Vec<PathBuf> {
    let path = if pattern == "~" {
        home.to_path_buf()
    } else if let Some(relative) = pattern.strip_prefix("~/") {
        home.join(relative)
    } else {
        let path = PathBuf::from(pattern);
        if path.is_absolute() { path } else { ssh_root.join(path) }
    };
    let Some(pattern) = path.to_str() else { return Vec::new() };
    let Ok(paths) = glob::glob(pattern) else { return Vec::new() };
    paths.filter_map(Result::ok).take(SSH_CONFIG_MAX_FILES).collect()
}

/// A config line's lowercased keyword and its values. The keyword may end
/// in `=`, with or without spaces around it (`HostName=x`, `HostName = x`,
/// `HostName =x`), as ssh reads it.
fn ssh_config_line(line: &str) -> Option<(String, Vec<String>)> {
    let mut words = ssh_config_words(line).into_iter();
    let first = words.next()?;
    let (keyword, mut values) = match first.split_once('=') {
        Some((keyword, value)) => (keyword.to_owned(), vec![value.to_owned()]),
        None => {
            // `Keyword = value` or `Keyword =value`.
            let mut values: Vec<String> = Vec::new();
            if let Some(next) = words.next() {
                values.push(next.strip_prefix('=').map(str::to_owned).unwrap_or(next));
            }
            (first, values)
        }
    };
    values.extend(words);
    values.retain(|v| !v.is_empty());
    Some((keyword.to_ascii_lowercase(), values))
}

/// Whether `host` matches ssh's `pattern` (`*` any run, `?` one character),
/// both lowercased.
fn ssh_pattern_matches(pattern: &str, host: &str) -> bool {
    let (p, h): (Vec<char>, Vec<char>) = (pattern.chars().collect(), host.chars().collect());
    // The classic two-pointer wildcard match, backtracking to the last `*`.
    let (mut i, mut j, mut star, mut mark) = (0, 0, None, 0);
    while let Some(&host_char) = h.get(j) {
        let pattern_char = p.get(i).copied();
        if pattern_char.is_some_and(|c| c == '?' || c == host_char) {
            i += 1;
            j += 1;
        } else if pattern_char == Some('*') {
            star = Some(i);
            mark = j;
            i += 1;
        } else if let Some(s) = star {
            i = s + 1;
            mark += 1;
            j = mark;
        } else {
            return false;
        }
    }
    p.get(i..).unwrap_or_default().iter().all(|&c| c == '*')
}

fn is_concrete_ssh_host(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with('-')
        && !host.chars().any(|character| matches!(character, '*' | '?' | '!' | '[' | ']'))
}

/// OpenSSH's config grammar only needs shell-like quoting for the directives
/// read here. Comments start outside quotes; backslashes quote one character.
fn ssh_config_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        if let Some(delimiter) = quote {
            if character == delimiter {
                quote = None;
            } else {
                current.push(character);
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            '#' => break,
            character if character.is_whitespace() => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(character),
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

#[cfg(test)]
#[path = "ssh_config_hosts_tests.rs"]
mod tests;
