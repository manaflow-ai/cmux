//! What cmux does with a URL or file macOS hands it (it is the default
//! browser, the `ssh:` or `x-man-page:` handler, the opener of a file type,
//! or the target of the Finder service "New cmux Tab Here"), moved out of the
//! app's Swift `ExternalOpenRouter`. Pure: the app parses the URL with
//! Foundation (so the parts are the ones macOS read), looks at the file
//! (a folder, executable, a picture), and acts on the route.

use serde::{Deserialize, Serialize};

/// A URL's parts as Foundation read them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Link {
    /// `url.absoluteString`.
    pub absolute: String,
    pub scheme: Option<String>,
    /// `url.host(percentEncoded: false)` (an IPv6 host without brackets).
    pub host: Option<String>,
    /// `url.user(percentEncoded: false)`.
    pub user: Option<String>,
    /// The URL carries a password.
    pub password: bool,
    /// The URL carries a query.
    pub query: bool,
    /// The URL carries a fragment.
    pub fragment: bool,
    pub port: Option<i64>,
    /// `url.path(percentEncoded: true)`.
    pub path_encoded: String,
    /// `url.path(percentEncoded: false)`.
    pub path: String,
    /// `url.pathComponents`.
    pub path_components: Vec<String>,
    /// The app's sign-in callback matcher accepted it.
    pub auth_callback: bool,
}

/// A file URL's file, as the app found it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct File {
    /// The file's path.
    pub path: String,
    /// Its folder (`deletingLastPathComponent`).
    pub folder: String,
    /// Its extension, lowercased (`pathExtension`).
    pub ext: String,
    pub is_directory: bool,
    pub is_executable: bool,
    /// Its type conforms to `public.image`.
    pub is_image: bool,
}

/// How the link came to cmux.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    /// macOS opened it (`route`).
    #[default]
    Open,
    /// A web link from inside cmux (a feed item): only `http(s)` and this
    /// build's links, never a file or a terminal command.
    WebLink,
    /// A web page continued from another device (Handoff); the app checks
    /// the activity type.
    Continuing,
}

/// What a route asks for.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Request {
    pub link: Link,
    /// For a `file:` link: what the app found at its path.
    pub file: Option<File>,
    /// This build's URL scheme; none routes no links.
    pub link_scheme: Option<String>,
    pub mode: Mode,
}

/// Where an `ssh://[user@]host[:port]` link connects, as parsed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshTarget {
    pub user: Option<String>,
    /// The host as the link names it, percent-decoded, without brackets.
    pub host: String,
    pub port: Option<i64>,
}

/// An SSH target's strings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshStrings {
    /// `user@host:port` as parsed, what the confirmation names.
    pub display: String,
    /// The host as trust is keyed.
    pub trust_key: String,
    /// The command typed into the new terminal.
    pub command: String,
}

/// Where the link goes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Route {
    /// A browser tab for the link itself.
    BrowserTab,
    /// A browser tab for the file at the request's path (a web page, SVG,
    /// a saved page).
    BrowserFile,
    /// A terminal tab started in `cwd`, then `command` typed into its shell.
    Terminal {
        cwd: Option<String>,
        command: Option<String>,
    },
    /// An `ssh://` link: a terminal that runs its command after the app's
    /// confirmation.
    Ssh {
        target: SshTarget,
    },
    /// A picture: it goes into an agent chat's composer.
    AttachImage,
    /// Any other file: the shared file opener.
    File,
    /// A link in this build's scheme: the `link.open` action.
    DeepLink,
    /// A chat share link: the daemon checks it.
    ShareLink,
    Unsupported,
}

/// The sign-in callback's target, as host or path.
pub const AUTH_CALLBACK_TARGET: &str = "auth-callback";
/// The guest page's open-in-app link: `<scheme>://share?link=<page>#<secret>`.
pub const SHARE_LINK_TARGET: &str = "share";

/// Script extensions and the shell that runs a script without its execute bit.
pub const SCRIPT_SHELLS: [(&str, &str); 7] = [
    ("command", "sh"),
    ("tool", "sh"),
    ("sh", "sh"),
    ("zsh", "zsh"),
    ("bash", "bash"),
    ("csh", "csh"),
    ("pl", "perl"),
];

/// Files a browser opens as a page: web pages, SVG and saved pages.
pub const PAGE_EXTENSIONS: [&str; 10] =
    ["html", "htm", "xhtml", "xht", "shtml", "webarchive", "svg", "svgz", "mhtml", "mht"];

/// Routes a link (Swift `ExternalOpenRouter.route`, `routeWebLink` and
/// `route(continuing:webpageURL:)`).
pub fn route(request: &Request) -> Route {
    match request.mode {
        Mode::Open => open(request),
        Mode::WebLink => match open(request) {
            Route::BrowserTab if !scheme_is(&request.link, "file") => Route::BrowserTab,
            Route::DeepLink => Route::DeepLink,
            Route::ShareLink => Route::ShareLink,
            _ => Route::Unsupported,
        },
        Mode::Continuing => continuing(&request.link),
    }
}

fn lowercase_scheme(link: &Link) -> Option<String> {
    link.scheme.as_deref().map(str::to_lowercase)
}

fn scheme_is(link: &Link, scheme: &str) -> bool {
    lowercase_scheme(link).as_deref() == Some(scheme)
}

fn open(request: &Request) -> Route {
    let link = &request.link;
    if let (Some(own), Some(scheme)) = (request.link_scheme.as_deref(), link.scheme.as_deref())
        && own.to_lowercase() == scheme.to_lowercase()
    {
        // The sign-in callback shares the scheme; it stays auth's, in every
        // form auth accepts.
        if link.auth_callback {
            return Route::Unsupported;
        }
        if link.host.as_deref().map(str::to_lowercase).as_deref() == Some(SHARE_LINK_TARGET) {
            return Route::ShareLink;
        }
        return Route::DeepLink;
    }
    match lowercase_scheme(link).as_deref() {
        Some("https") if is_share_page_path(&link.path_encoded) => Route::ShareLink,
        Some("https") if is_screen_link(link) => Route::DeepLink,
        Some("http" | "https") => Route::BrowserTab,
        Some("file") => request.file.as_ref().map_or(Route::Unsupported, route_file),
        Some("ssh") => ssh(link),
        Some("x-man-page") => man_page(link),
        _ => Route::Unsupported,
    }
}

fn continuing(link: &Link) -> Route {
    match lowercase_scheme(link).as_deref() {
        Some("https") if is_share_page_path(&link.path_encoded) => Route::ShareLink,
        Some("http" | "https") if is_screen_link(link) => Route::DeepLink,
        Some("http" | "https") => Route::BrowserTab,
        _ => Route::Unsupported,
    }
}

/// A run's screen link's web form (`https://cmux.com/deeplink/screen?...`):
/// `link.open` opens that device's Screen Sharing tab.
pub fn is_screen_link(link: &Link) -> bool {
    let host = link.host.as_deref().map(str::to_lowercase);
    if !scheme_is(link, "https") || !matches!(host.as_deref(), Some("cmux.com" | "www.cmux.com")) {
        return false;
    }
    let mut path = link.path.as_str();
    while path.chars().count() > 1 && path.ends_with('/') {
        path = path.strip_suffix('/').unwrap_or(path);
    }
    path == "/deeplink/screen"
}

/// A path shaped like a chat share page (`/g/<id>` or `/i/<id>`); the
/// daemon decides whether its host is a share room's.
pub fn is_share_page_path(path: &str) -> bool {
    let mut parts: Vec<&str> = path.split('/').collect();
    if parts.last() == Some(&"") && parts.len() == 4 {
        parts.pop();
    }
    let [first, kind, id] = parts.as_slice() else { return false };
    if !first.is_empty() || !(*kind == "g" || *kind == "i") {
        return false;
    }
    (16..=128).contains(&id.chars().count())
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// The sign-in callback in any form auth accepts: `<scheme>://auth-callback`,
/// `<scheme>:auth-callback` and `<scheme>:///auth-callback` (`host` as
/// Foundation read it, `path` percent-decoded).
pub fn is_sign_in_callback(host: Option<&str>, path: &str) -> bool {
    if let Some(host) = host.map(|host| host.trim_matches('/'))
        && !host.is_empty()
    {
        return host.to_lowercase() == AUTH_CALLBACK_TARGET;
    }
    path.trim_matches('/').to_lowercase() == AUTH_CALLBACK_TARGET
}

/// A file: a folder opens a terminal there, a page a browser tab, a script
/// runs, a picture goes to a chat, anything else to the file opener.
pub fn route_file(file: &File) -> Route {
    if file.is_directory {
        return Route::Terminal { cwd: Some(file.path.clone()), command: None };
    }
    if PAGE_EXTENSIONS.contains(&file.ext.as_str()) {
        return Route::BrowserFile;
    }
    if let Some((_, shell)) = SCRIPT_SHELLS.iter().find(|(ext, _)| *ext == file.ext) {
        let quoted = shell_quote(&file.path);
        let command = if file.is_executable { quoted } else { format!("{shell} {quoted}") };
        return Route::Terminal { cwd: Some(file.folder.clone()), command: Some(command) };
    }
    if file.ext.is_empty() && file.is_executable {
        return Route::Terminal {
            cwd: Some(file.folder.clone()),
            command: Some(shell_quote(&file.path)),
        };
    }
    // A picture (a screenshot, a photo) goes to a chat; SVG stays a page.
    if !file.ext.is_empty() && file.is_image {
        return Route::AttachImage;
    }
    Route::File
}

/// `ssh://[user@]host[:port]`, as Terminal handles it. The host and user are
/// restricted to the characters a host name or login can hold, and `--` ends
/// ssh's options, so a crafted link cannot pass an option to ssh.
fn ssh(link: &Link) -> Route {
    // Only `[user@]host[:port]`: no password, path, query or fragment, and
    // every character as written ASCII.
    if !link.absolute.is_ascii()
        || link.password
        || link.query
        || link.fragment
        || !(link.path_encoded.is_empty() || link.path_encoded == "/")
        || !port_is_well_formed(link)
    {
        return Route::Unsupported;
    }
    let Some(host) = link.host.as_deref().filter(|host| is_host_name(host)) else {
        return Route::Unsupported;
    };
    if let Some(user) = link.user.as_deref()
        && !is_login(user)
    {
        return Route::Unsupported;
    }
    if let Some(port) = link.port
        && !(1..=65535).contains(&port)
    {
        return Route::Unsupported;
    }
    Route::Ssh {
        target: SshTarget { user: link.user.clone(), host: host.to_owned(), port: link.port },
    }
}

/// A `:` after the host names a port the URL could read (`host:` or
/// `host:abc` is refused, never read as no port).
fn port_is_well_formed(link: &Link) -> bool {
    if link.port.is_some() {
        return true;
    }
    let Some(mut authority) = link.absolute.split('/').nth(2) else { return true };
    if let Some((_, host)) = authority.rsplit_once('@') {
        authority = host;
    }
    if authority.starts_with('[')
        && let Some((_, rest)) = authority.split_once(']')
    {
        authority = rest;
    }
    !authority.contains(':')
}

/// `x-man-page://ls`, `x-man-page://1/ls`, `x-man-page:///ls`.
fn man_page(link: &Link) -> Route {
    let mut parts: Vec<&str> = link
        .host
        .iter()
        .chain(link.path_components.iter())
        .map(String::as_str)
        .filter(|part| !part.is_empty() && *part != "/")
        .collect();
    let Some(topic) = parts.pop().filter(|topic| is_man_token(topic)) else {
        return Route::Unsupported;
    };
    if parts.len() > 1 {
        return Route::Unsupported;
    }
    let command = match parts.first() {
        Some(section) if !is_man_token(section) => return Route::Unsupported,
        Some(section) => format!("man {} {}", shell_quote(section), shell_quote(topic)),
        None => format!("man {}", shell_quote(topic)),
    };
    Route::Terminal { cwd: None, command: Some(command) }
}

/// ASCII only: a look-alike letter (Cyrillic `а`, the Kelvin sign) would
/// name another host than the one the confirmation seems to show.
pub fn is_host_name(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with('-')
        && host.len() <= 253
        && host.chars().all(|c| c.is_ascii_alphanumeric() || ".-_:%".contains(c))
}

pub fn is_login(user: &str) -> bool {
    !user.is_empty()
        && !user.starts_with('-')
        && user.len() <= 64
        && user.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// A man page's section or topic: letters and digits in any script, and
/// `._+:-`, never an option.
pub fn is_man_token(token: &str) -> bool {
    !token.starts_with('-')
        && token.chars().count() <= 128
        && token.chars().all(|c| c.is_alphanumeric() || "._+:-".contains(c))
}

/// POSIX shell single quoting: `it's` becomes `'it'\''s'`.
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// `host` without IPv6 brackets, ASCII letters lowercased: OpenSSH lowercases
/// the host before it reads its config. An IPv6 zone (`fe80::1%en0`) keeps
/// its spelling: it names an interface, not a DNS label.
pub fn trust_key(host: &str) -> String {
    // Foundation's `.whitespaces`: spaces and tabs, never line breaks.
    let mut key = host.trim_matches(|c: char| {
        c == '\t'
            || (c.is_whitespace()
                && !matches!(
                    c,
                    '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
                ))
    });
    if key.starts_with('[') && key.ends_with(']') {
        key = key.get(1..key.len() - 1).unwrap_or("");
    }
    let (address, zone) = key.find('%').map_or((key, ""), |at| key.split_at(at));
    // ASCII letters only: Unicode lowercasing folds the Kelvin sign into `k`.
    address.to_ascii_lowercase() + zone
}

impl SshTarget {
    pub fn strings(&self) -> SshStrings {
        let bracketed =
            if self.host.contains(':') { format!("[{}]", self.host) } else { self.host.clone() };
        let user_at = self.user.as_deref().map(|user| format!("{user}@")).unwrap_or_default();
        let port = self.port.map(|port| format!(":{port}")).unwrap_or_default();
        let flag = self.port.map(|port| format!(" -p {port}")).unwrap_or_default();
        SshStrings {
            display: format!("{user_at}{bracketed}{port}"),
            trust_key: trust_key(&self.host),
            command: format!("ssh{flag} -- {}", shell_quote(&format!("{user_at}{bracketed}"))),
        }
    }
}

#[cfg(test)]
#[path = "external_open_tests.rs"]
mod tests;
