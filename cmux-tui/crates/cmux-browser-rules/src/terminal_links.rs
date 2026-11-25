//! Where a Cmd-clicked terminal link goes (cx-do47).
//!
//! Ported 1:1 from the app's Swift (`CmuxNextBrowser`): `TerminalLinkTarget` and
//! `TerminalLinkResolver` (Links/TerminalLinkResolver.swift). Swift keeps Ghostty's link match
//! and the opening; these are the rules, and the file system reads behind them.
//!
//! Resolves the text Ghostty matched under a Cmd-click. Programs print paths in prose:
//! `is ready: ~/Desktop/reply.md.`, `"build-fleet/ORG-BACKUP.md",`, `src/app.ts:3:5`. The
//! surrounding quotes and trailing punctuation go, as does a `:line:col`; a relative path resolves
//! against the terminal's directory, then the git root above it. Only a path that exists is a
//! link. Text without a scheme is a web link only when its host is localhost, an IP address with a
//! port, or a name under a real top-level domain, so `build-fleet/x.md` never opens
//! https://build-fleet/x.md.
//!
//! URLs travel as strings. A web URL is the text as typed (with `http://` or `https://` put in
//! front of a scheme-less host); the app's `URL(string:)` makes it the `URL` Swift's resolver gave,
//! percent-encoding what Foundation encodes. A file URL is `URL(fileURLWithPath:isDirectory:)`'s
//! `absoluteString`.

use crate::address;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

/// Where a Cmd-clicked terminal link goes (cx-do47).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TerminalLinkTarget {
    /// A URL with a scheme, or a web host typed without one (`localhost:3000/docs`, `docs.rs/serde`).
    Url {
        #[serde(rename = "_0")]
        url: String,
    },
    /// A file or folder that exists.
    File {
        #[serde(rename = "_0")]
        url: String,
        #[serde(rename = "isDirectory")]
        is_directory: bool,
    },
}

/// The `:line` or `:line:col` after a printed path.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Location {
    pub line: i64,
    pub column: Option<i64>,
}

/// What a resolve reads besides the text: the terminal's directory and the facts of this Mac.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TerminalLinkContext {
    /// The shell's directory: a path, or a `file://` URL from OSC 7.
    pub cwd: Option<String>,
    /// False where local files never open (a Cloud workspace's terminal): only web links resolve.
    /// Absent means true.
    pub allows_local_files: Option<bool>,
    /// Host names OSC 7 emitted by a shell on this Mac may use (`localhost`, the kernel host
    /// name and its `.local`). Absent means `localhost` alone.
    pub local_host_names: Option<Vec<String>>,
    /// This user's home folder, for `~`. Absent means `$HOME`.
    pub home: Option<String>,
}

/// The target of `text`, or `None` when it is no link (a path that exists nowhere, a bogus host).
/// Reads the file system: call it off the main thread.
pub fn resolve(text: &str, context: &TerminalLinkContext) -> Option<TerminalLinkTarget> {
    resolve_with(text, context, address::is_top_level_domain)
}

/// [`resolve`] with the top-level domain test given (tests pass their own).
pub fn resolve_with(
    text: &str,
    context: &TerminalLinkContext,
    is_top_level_domain: impl Fn(&str) -> bool,
) -> Option<TerminalLinkTarget> {
    let trimmed = trim(text);
    if !safe_terminal_text(&trimmed) {
        return None;
    }
    let allows_local_files = context.allows_local_files.unwrap_or(true);
    let host_names: HashSet<String> = match &context.local_host_names {
        Some(names) => names.iter().cloned().collect(),
        None => local_file_host_names(),
    };
    let home = context.home.clone().or_else(|| std::env::var("HOME").ok());
    let home = home.as_deref();
    if has_scheme(&trimmed)
        && let Some(url) = Url::parse(&trimmed)
    {
        if url.is_file() {
            if !allows_local_files || !safe_terminal_url(&trimmed) || !local_file(&url, &host_names)
            {
                return None;
            }
            return existing(&url.path(), home);
        }
        if trimmed.chars().any(char::is_whitespace)
            || !safe_terminal_url(&trimmed)
            || !web_url(&url)
        {
            return None;
        }
        return Some(TerminalLinkTarget::Url { url: trimmed });
    }
    if !allows_local_files {
        return safe_web_url(&trimmed, &is_top_level_domain)
            .map(|url| TerminalLinkTarget::Url { url });
    }
    let path = without_location(&trimmed);
    for candidate in candidates(path, context.cwd.as_deref(), &host_names, home) {
        if let Some(target) = existing(&candidate, home) {
            return Some(target);
        }
    }
    safe_web_url(&trimmed, &is_top_level_domain).map(|url| TerminalLinkTarget::Url { url })
}

/// The paths `text` may name on another machine (#25581, a Cloud workspace's terminal), best
/// first: an absolute path as printed, else the path under `cwd` (the shell's folder there, a
/// `file://` URL of any host). Empty for a URL, `~` (that machine's home is not known here) or
/// text that is no path. Reads nothing: the machine says which exists.
pub fn remote_candidates(text: &str, cwd: Option<&str>) -> Vec<String> {
    let trimmed = trim(text);
    if !safe_terminal_text(&trimmed) || has_scheme(&trimmed) {
        return Vec::new();
    }
    let path = without_location(&trimmed);
    if path.is_empty() || path.starts_with('~') || path.contains('\0') {
        return Vec::new();
    }
    if path.starts_with('/') {
        return vec![lexical(path)];
    }
    let folder = match cwd {
        Some(cwd) if cwd.starts_with('/') => Some(cwd.to_owned()),
        Some(cwd) => Url::parse(cwd)
            .filter(Url::is_file)
            .map(|url| url.path())
            .filter(|path| path.starts_with('/')),
        None => None,
    };
    let Some(folder) = folder else { return Vec::new() };
    vec![lexical(&format!("{folder}/{path}"))]
}

/// An absolute path of another machine, tidied as text: empty and `.` components dropped, `..`
/// removes the component before it (never above `/`), no trailing `/`. Nothing of this Mac is
/// read: `NSString.standardizingPath` resolves `..` through this Mac's symlinks and drops
/// `/private` when that path exists here, which is this Mac's disk, not the VM's.
fn lexical(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/').filter(|part| !part.is_empty()) {
        match part {
            "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}

const OPENERS: &[char] = &['"', '\'', '`', '“', '‘', '<', '[', '{', '('];
const CLOSERS: &[char] = &['"', '\'', '`', '”', '’', '>', ']', '}', '.', ',', ';', ':', '!', '?'];

/// `text` without surrounding quotes and brackets and trailing punctuation; a closing
/// parenthesis stays when it closes one in the text (`wiki/Foo_(bar)`).
pub fn trim(text: &str) -> String {
    let mut value = text.trim();
    while let Some(first) = value.chars().next() {
        if !OPENERS.contains(&first) {
            break;
        }
        value = &value[first.len_utf8()..];
    }
    while let Some(last) = value.chars().next_back() {
        let unbalanced = last == ')'
            && value.chars().filter(|&c| c == '(').count()
                < value.chars().filter(|&c| c == ')').count();
        if !(CLOSERS.contains(&last) || unbalanced) {
            break;
        }
        value = &value[..value.len() - last.len_utf8()];
    }
    value.to_owned()
}

/// `mailto:`, `https://`; not `localhost:3000` or `app.ts:3` (a port or a line).
fn has_scheme(text: &str) -> bool {
    let (Some(colon), Some(first)) = (text.find(':'), text.chars().next()) else {
        return false;
    };
    if !first.is_ascii_alphabetic() {
        return false;
    }
    let scheme = &text[..colon];
    if scheme.chars().count() <= 1
        || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
    {
        return false;
    }
    text[colon + 1..].chars().next().is_some_and(|c| !c.is_numeric())
}

/// The trailing `:digits` of `value` once (`max_digits` bounds them), and what stays before it.
fn strip_number(value: &str, max_digits: Option<usize>) -> Option<(&str, &str)> {
    let colon = value.rfind(':')?;
    if colon == 0 {
        return None;
    }
    let digits = &value[colon + 1..];
    if digits.is_empty()
        || max_digits.is_some_and(|max| digits.chars().count() >= max)
        || !digits.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    Some((&value[..colon], digits))
}

/// The `:line` or `:line:col` after a printed path (`src/app.ts:3:5` is line 3, column 5),
/// as surrounding quotes and punctuation are trimmed; `None` without one, or for a URL.
pub fn location(text: &str) -> Option<Location> {
    let trimmed = trim(text);
    if has_scheme(&trimmed) {
        return None;
    }
    let mut numbers: Vec<i64> = Vec::new();
    let mut value = trimmed.as_str();
    for _ in 0..2 {
        let Some((rest, digits)) = strip_number(value, Some(10)) else { break };
        let Ok(number) = digits.parse::<i64>() else { break };
        numbers.insert(0, number);
        value = rest;
    }
    let line = *numbers.first()?;
    if line <= 0 {
        return None;
    }
    Some(Location { line, column: numbers.get(1).copied() })
}

/// `path` without a trailing `:line` or `:line:col`.
fn without_location(path: &str) -> &str {
    let mut value = path;
    for _ in 0..2 {
        let Some((rest, _)) = strip_number(value, None) else { break };
        value = rest;
    }
    value
}

/// Absolute paths as they are; `~` expanded; a relative path under `cwd`, then under the git
/// root above it.
fn candidates(
    path: &str,
    cwd: Option<&str>,
    host_names: &HashSet<String>,
    home: Option<&str>,
) -> Vec<String> {
    if path.starts_with('~') {
        return vec![expanding_tilde(path, home)];
    }
    if path.starts_with('/') {
        return vec![path.to_owned()];
    }
    let Some(cwd) = cwd.and_then(|cwd| directory(cwd, host_names, home)) else {
        return Vec::new();
    };
    let mut bases = vec![cwd.clone()];
    if let Some(root) = git_root(&cwd)
        && root != cwd
    {
        bases.push(root);
    }
    bases.iter().map(|base| appending_path_component(base, path)).collect()
}

/// The shell's directory as a path (a `file://` URL from OSC 7 too).
fn directory(cwd: &str, host_names: &HashSet<String>, home: Option<&str>) -> Option<String> {
    if cwd.starts_with('/') {
        return Some(standardizing(cwd, home));
    }
    let url = Url::parse(cwd)?;
    let path = url.path();
    if !local_file(&url, host_names) || path.is_empty() {
        return None;
    }
    Some(standardizing(&path, home))
}

/// File URLs from a terminal must name this Mac, never an arbitrary authority.
fn local_file(url: &Url, host_names: &HashSet<String>) -> bool {
    if !url.is_file()
        || url.user.is_some()
        || url.password.is_some()
        || url.port.is_some()
        || url.query.is_some()
        || url.fragment.is_some()
    {
        return false;
    }
    match url.host().map(|host| host.to_lowercase()) {
        Some(host) if !host.is_empty() => host_names.contains(&host),
        _ => true,
    }
}

/// Host names OSC 7 emitted by a shell on this Mac may use, when the app names none: the app
/// sends `localhost`, the kernel host name and its `.local`.
fn local_file_host_names() -> HashSet<String> {
    HashSet::from(["localhost".to_owned()])
}

/// Explicit terminal URLs are web-only and never carry credentials.
fn web_url(url: &Url) -> bool {
    let scheme = url.scheme.to_lowercase();
    (scheme == "http" || scheme == "https")
        && url.host().is_some_and(|host| !host.is_empty())
        && url.user.is_none()
        && url.password.is_none()
}

/// Reject invisible or control characters before URL parsing can escape them.
fn safe_terminal_text(text: &str) -> bool {
    !text.is_empty()
        && !text
            .chars()
            .any(|scalar| is_control_character(scalar) || invisible_format(u32::from(scalar)))
}

/// Percent escapes must not smuggle controls or invisible formatting past the raw check.
fn safe_terminal_url(url: &str) -> bool {
    match removing_percent_encoding(url) {
        Some(decoded) => safe_terminal_text(&decoded),
        None => false,
    }
}

fn invisible_format(value: u32) -> bool {
    value == 0x00AD
        || value == 0x061C
        || value == 0x180E
        || (0x200B..=0x200F).contains(&value)
        || (0x202A..=0x202E).contains(&value)
        || (0x2060..=0x2064).contains(&value)
        || (0x2066..=0x206F).contains(&value)
        || value == 0xFEFF
        || (0xFFF9..=0xFFFB).contains(&value)
}

/// `CharacterSet.controlCharacters`: Unicode general categories Cc and Cf.
fn is_control_character(scalar: char) -> bool {
    const FORMAT: &[(u32, u32)] = &[
        (0x00AD, 0x00AD),
        (0x0600, 0x0605),
        (0x061C, 0x061C),
        (0x06DD, 0x06DD),
        (0x070F, 0x070F),
        (0x0890, 0x0891),
        (0x08E2, 0x08E2),
        (0x180E, 0x180E),
        (0x200B, 0x200F),
        (0x202A, 0x202E),
        (0x2060, 0x2064),
        (0x2066, 0x206F),
        (0xFEFF, 0xFEFF),
        (0xFFF9, 0xFFFB),
        (0x110BD, 0x110BD),
        (0x110CD, 0x110CD),
        (0x13430, 0x1343F),
        (0x1BCA0, 0x1BCA3),
        (0x1D173, 0x1D17A),
        (0xE0001, 0xE0001),
        (0xE0020, 0xE007F),
    ];
    let value = u32::from(scalar);
    scalar.is_control() || FORMAT.iter().any(|&(low, high)| (low..=high).contains(&value))
}

/// The nearest folder at or above `directory` holding `.git`.
fn git_root(directory: &str) -> Option<String> {
    let mut folder = directory.to_owned();
    for _ in 0..path_components(directory) {
        if Path::new(&appending_path_component(&folder, ".git")).exists() {
            return Some(folder);
        }
        folder = deleting_last_path_component(&folder);
    }
    None
}

fn existing(path: &str, home: Option<&str>) -> Option<TerminalLinkTarget> {
    let standardized = standardizing(path, home);
    // Only an absolute path names a file: a relative one would read this process's folder.
    if !standardized.starts_with('/') {
        return None;
    }
    let metadata = std::fs::metadata(&standardized).ok()?;
    let is_directory = metadata.is_dir();
    Some(TerminalLinkTarget::File { url: file_url(&standardized, is_directory), is_directory })
}

/// `text` as a web URL when its host can be one: localhost (http), an IPv4 address with a
/// port (http), or a dotted name whose last label is a top-level domain (https). A bare
/// name with no path or port (`README.md`, `notes.sh`) is a file name, not a host.
fn web_url_text(text: &str, is_top_level_domain: &impl Fn(&str) -> bool) -> Option<String> {
    if text.chars().any(char::is_whitespace) {
        return None;
    }
    let authority = &text[..text.find(['/', '?', '#']).unwrap_or(text.len())];
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = match authority.rfind(':') {
        Some(colon) => {
            let digits = &authority[colon + 1..];
            if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            (&authority[..colon], Some(digits))
        }
        None => (authority, None),
    };
    let name = host.to_lowercase();
    if name == "localhost" || name.ends_with(".localhost") {
        return Some(format!("http://{text}"));
    }
    let labels: Vec<&str> = name.split('.').collect();
    if labels.len() == 4 && labels.iter().all(|label| label.parse::<u8>().is_ok()) {
        return port.map(|_| format!("http://{text}"));
    }
    if !(authority.len() < text.len() || port.is_some() || name.starts_with("www.")) {
        return None;
    }
    let last = labels.last()?;
    if labels.len() < 2
        || !labels.iter().all(|label| {
            !label.is_empty() && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
        || !is_top_level_domain(last)
    {
        return None;
    }
    Some(format!("https://{text}"))
}

fn safe_web_url(text: &str, is_top_level_domain: &impl Fn(&str) -> bool) -> Option<String> {
    web_url_text(text, is_top_level_domain).filter(|url| safe_terminal_url(url))
}

// What the Swift read from Foundation, in Rust: `URL(string:)`'s parts, `NSString`'s path
// methods, `removingPercentEncoding` and `URL(fileURLWithPath:)`.

/// A URL's parts as `URL(string:)` gives them (RFC 3986). Foundation percent-encodes what it
/// may not hold rather than refusing it, so nearly any text parses: an authority with a port that
/// is not digits does not.
struct Url<'a> {
    scheme: &'a str,
    /// The authority after `//`; `None` without one.
    host: Option<&'a str>,
    user: Option<&'a str>,
    password: Option<&'a str>,
    port: Option<&'a str>,
    path: &'a str,
    query: Option<&'a str>,
    fragment: Option<&'a str>,
}

impl<'a> Url<'a> {
    fn parse(text: &'a str) -> Option<Self> {
        let colon = text.find(':')?;
        let scheme = &text[..colon];
        let mut chars = scheme.chars();
        if !chars.next().is_some_and(|c| c.is_ascii_alphabetic())
            || !chars.all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
        {
            return None;
        }
        let mut rest = &text[colon + 1..];
        let fragment = rest.find('#').map(|hash| {
            let fragment = &rest[hash + 1..];
            rest = &rest[..hash];
            fragment
        });
        let query = rest.find('?').map(|mark| {
            let query = &rest[mark + 1..];
            rest = &rest[..mark];
            query
        });
        let (mut host, mut user, mut password, mut port) = (None, None, None, None);
        if let Some(after) = rest.strip_prefix("//") {
            let end = after.find('/').unwrap_or(after.len());
            let authority = &after[..end];
            rest = &after[end..];
            let host_port = match authority.rfind('@') {
                Some(at) => {
                    let userinfo = &authority[..at];
                    match userinfo.find(':') {
                        Some(split) => {
                            user = Some(&userinfo[..split]);
                            password = Some(&userinfo[split + 1..]);
                        }
                        None => user = Some(userinfo),
                    }
                    &authority[at + 1..]
                }
                None => authority,
            };
            let port_colon = if host_port.starts_with('[') {
                let close = host_port.find(']')?;
                match &host_port[close + 1..] {
                    "" => None,
                    after if after.starts_with(':') => Some(close + 1),
                    _ => return None,
                }
            } else {
                host_port.rfind(':')
            };
            let host_text = match port_colon {
                Some(split) => {
                    let digits = &host_port[split + 1..];
                    if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
                        return None;
                    }
                    port = Some(digits).filter(|digits| !digits.is_empty());
                    &host_port[..split]
                }
                None => host_port,
            };
            host = Some(host_text);
        }
        Some(Self { scheme, host, user, password, port, path: rest, query, fragment })
    }

    fn is_file(&self) -> bool {
        self.scheme.eq_ignore_ascii_case("file")
    }

    /// `URL.host`: decoded, without an IPv6 literal's brackets.
    fn host(&self) -> Option<String> {
        let host = self.host?;
        let host = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
        Some(lenient_decode(host).unwrap_or_else(|| host.to_owned()))
    }

    /// `URL.path`: decoded, without a trailing `/`.
    fn path(&self) -> String {
        let path = lenient_decode(self.path).unwrap_or_else(|| self.path.to_owned());
        match path.strip_suffix('/') {
            Some(trimmed) if !trimmed.is_empty() => trimmed.to_owned(),
            _ => path,
        }
    }
}

/// Decodes every `%XX`; a `%` not followed by two hex digits stays (Foundation had encoded it as
/// `%25`). `None` when the bytes are not UTF-8.
fn lenient_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) = (hex(bytes[index + 1]), hex(bytes[index + 2]))
        {
            out.push((high << 4) | low);
            index += 3;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(out).ok()
}

fn hex(byte: u8) -> Option<u8> {
    (byte as char).to_digit(16).map(|digit| digit as u8)
}

/// `removingPercentEncoding` of the `absoluteString` Foundation made of `text`.
fn removing_percent_encoding(text: &str) -> Option<String> {
    lenient_decode(text)
}

/// `NSString.expandingTildeInPath` for this user: `~` and `~/…` under `home`. Another user's
/// `~name` stays as written (no link: only an absolute path names a file).
fn expanding_tilde(path: &str, home: Option<&str>) -> String {
    let Some(home) = home else { return path.to_owned() };
    let home = home.trim_end_matches('/');
    match path.strip_prefix('~') {
        Some("") => {
            if home.is_empty() {
                "/".to_owned()
            } else {
                home.to_owned()
            }
        }
        Some(rest) if rest.starts_with('/') => format!("{home}{rest}"),
        _ => path.to_owned(),
    }
}

/// `NSString.standardizingPath`: `~` expanded, empty and `.` components dropped, `..` the real
/// parent (through this Mac's symlinks) where the folder exists, no trailing `/`, and an initial
/// `/private` dropped when the shorter path exists. A relative path keeps its `..`.
fn standardizing(path: &str, home: Option<&str>) -> String {
    let expanded = expanding_tilde(path, home);
    if !expanded.starts_with('/') {
        let parts: Vec<&str> =
            expanded.split('/').filter(|part| !part.is_empty() && *part != ".").collect();
        return parts.join("/");
    }
    let mut parts: Vec<String> = Vec::new();
    for part in expanded.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                let folder = format!("/{}", parts.join("/"));
                if let Ok(real) = std::fs::canonicalize(&folder)
                    && let Some(real) = real.to_str()
                {
                    parts = real.split('/').filter(|p| !p.is_empty()).map(str::to_owned).collect();
                }
                parts.pop();
            }
            _ => parts.push(part.to_owned()),
        }
    }
    let standardized = format!("/{}", parts.join("/"));
    if let Some(shorter) = standardized.strip_prefix("/private")
        && shorter.starts_with('/')
        && Path::new(shorter).exists()
    {
        return shorter.to_owned();
    }
    standardized
}

/// `NSString.pathComponents`' count (`/` is one).
fn path_components(path: &str) -> usize {
    usize::from(path.starts_with('/')) + path.split('/').filter(|part| !part.is_empty()).count()
}

/// `NSString.appendingPathComponent`.
fn appending_path_component(base: &str, component: &str) -> String {
    let component = component.trim_end_matches('/');
    if base.is_empty() {
        component.to_owned()
    } else if base.ends_with('/') {
        format!("{base}{component}")
    } else {
        format!("{base}/{component}")
    }
}

/// `NSString.deletingLastPathComponent` of a standardized path (`/a` is `/`, `/` stays).
fn deleting_last_path_component(path: &str) -> String {
    match path.trim_end_matches('/').rfind('/') {
        Some(0) | None => "/".to_owned(),
        Some(slash) => path[..slash].to_owned(),
    }
}

/// `URL(fileURLWithPath:isDirectory:).absoluteString`: `file://`, the path with every byte
/// outside `CharacterSet.urlPathAllowed` percent-encoded, and a folder's trailing `/`.
fn file_url(path: &str, is_directory: bool) -> String {
    let mut url = String::from("file://");
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"!$&'()*+,-./:=@_~".contains(&byte) {
            url.push(byte as char);
        } else {
            const HEX: &[u8; 16] = b"0123456789ABCDEF";
            url.push('%');
            url.push(HEX[usize::from(byte >> 4)] as char);
            url.push(HEX[usize::from(byte & 0xF)] as char);
        }
    }
    if is_directory && !url.ends_with('/') {
        url.push('/');
    }
    url
}
