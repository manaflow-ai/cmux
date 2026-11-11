//! `render: web` panes (plans/cmux-next/extensibility-DESIGN.md section 4,
//! step 5): an implementation with `web` is a page on the shared page host at
//! `cmux-app://<host>/`, where `<host>` is the app id with its one `/` turned
//! into `.` (`cmux/codemirror` -> `cmux.codemirror`).
//!
//! Rust owns every decision about such a page; the Mac client only hosts the
//! WKWebView and serves the files this module resolved:
//! - which implementations are web pages, and their entry page ([`web_pages`]);
//! - the one file root (`runtime.web.root`): relative, no `..`, no absolute
//!   path, and every entry inside it ([`check`], [`resolve_request`]);
//! - the page's CSP: the app's declared CSP intersected with the strict page
//!   policy, so an app can only narrow it ([`effective_csp`]).

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::issue::{Issue, escape};

/// The custom scheme every app page loads from.
pub const APP_PAGE_SCHEME: &str = "cmux-app";

/// The strict page policy (`PageCSP.strict` in CmuxNextPages): no network, no
/// frames, same-origin script and style plus inline, images and fonts from
/// the page or `data:`. An app's CSP is intersected with it directive by
/// directive; a directive not listed here falls back to `default-src 'none'`.
pub const STRICT_PAGE_CSP: &[(&str, &[&str])] = &[
    ("default-src", &["'none'"]),
    ("script-src", &["'self'", "'unsafe-inline'"]),
    ("style-src", &["'self'", "'unsafe-inline'"]),
    ("img-src", &["'self'", "data:"]),
    ("font-src", &["'self'", "data:"]),
    ("worker-src", &["'self'"]),
];

/// Directives that do not fall back to `default-src`; an app page always gets
/// them closed (a page cannot rebase its URLs or post a form anywhere).
const CLOSED_NON_FETCH: &[&str] = &["base-uri", "form-action"];

/// One web page an app implements.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebPage {
    /// The interface it implements (`cmux.pane/1`, `cmux.editor/1`).
    pub interface: String,
    /// `cmux-app://<host>/`.
    pub origin: String,
    /// The file root inside the app tree, without a trailing `/` (`web`).
    pub root: String,
    /// The entry page relative to the root (`index.html`).
    pub entry: String,
    /// The full entry URL (`cmux-app://cmux.codemirror/index.html`).
    pub url: String,
    /// The CSP header the page host sends with every response.
    pub csp: String,
    pub symbol: Option<String>,
}

/// The URL host of an app's pages: `cmux/codemirror` -> `cmux.codemirror`.
/// Ids are `[a-z0-9-]+/[a-z0-9-]+`, so the mapping is one to one.
pub fn app_page_host(id: &str) -> String {
    id.replacen('/', ".", 1)
}

/// Every `web` implementation of a valid manifest, in interface order. An
/// implementation whose entry or root breaks a rule of [`check`] is left out
/// (the validator reports it; a client never opens it).
pub fn web_pages(manifest: &Value) -> Vec<WebPage> {
    let Some(implements) = manifest["implements"].as_object() else { return Vec::new() };
    let Ok(root) = web_root(manifest) else { return Vec::new() };
    let id = manifest["id"].as_str().unwrap_or_default();
    let host = app_page_host(id);
    let csp = effective_csp(manifest.pointer("/runtime/web/csp").and_then(Value::as_str));
    let mut pages: Vec<WebPage> = implements
        .iter()
        .filter_map(|(interface, imp)| {
            let web = imp.get("web")?.as_str()?;
            let entry = entry_in_root(&root, web).ok()?;
            let origin = format!("{APP_PAGE_SCHEME}://{host}/");
            Some(WebPage {
                interface: interface.clone(),
                url: format!("{origin}{entry}"),
                origin,
                root: root.clone(),
                entry,
                csp: csp.clone(),
                symbol: imp.get("symbol").and_then(Value::as_str).map(str::to_string),
            })
        })
        .collect();
    pages.sort_by(|a, b| a.interface.cmp(&b.interface));
    pages
}

/// Validator rules for web pages (called from `rules::check`).
pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    if m.pointer("/runtime/web").is_none() {
        return;
    }
    let root = match web_root(m) {
        Ok(root) => root,
        Err(message) => {
            out.push(Issue::error("/runtime/web/root", "runtime.web.root", message));
            return;
        }
    };
    for (name, imp) in m["implements"].as_object().into_iter().flatten() {
        let Some(web) = imp.get("web").and_then(Value::as_str) else { continue };
        if let Err(message) = entry_in_root(&root, web) {
            out.push(Issue::error(
                format!("/implements/{}/web", escape(name)),
                "web.outsideRoot",
                message,
            ));
        }
    }
}

/// `runtime.web.root` normalized (no trailing `/`), or why it is refused.
fn web_root(m: &Value) -> Result<String, String> {
    let raw =
        m.pointer("/runtime/web/root").and_then(Value::as_str).ok_or("no runtime.web.root")?;
    let segments = relative_segments(raw)?;
    if segments.is_empty() {
        return Err("runtime.web.root must name a folder inside the app, not the app itself".into());
    }
    Ok(segments.join("/"))
}

/// `web` (a path in the app tree) as a path under `root`, or why it is refused.
fn entry_in_root(root: &str, web: &str) -> Result<String, String> {
    let segments = relative_segments(web)?;
    let root_segments: Vec<&str> = root.split('/').collect();
    let inside = segments.len() > root_segments.len()
        && segments.iter().zip(&root_segments).all(|(a, b)| a == b);
    if !inside {
        return Err(format!("{web} is not inside runtime.web.root ({root}/)"));
    }
    Ok(segments[root_segments.len()..].join("/"))
}

/// The segments of a relative path, refusing an absolute path, a `..`
/// segment, a backslash, a NUL or a control character. `.` and empty
/// segments are dropped.
fn relative_segments(path: &str) -> Result<Vec<String>, String> {
    if path.starts_with('/') {
        return Err(format!("{path} is an absolute path"));
    }
    if path.chars().any(|c| c == '\\' || c.is_control()) {
        return Err(format!("{path:?} has a backslash or a control character"));
    }
    let mut out = Vec::new();
    for segment in path.split('/') {
        match segment {
            "" | "." => {}
            ".." => return Err(format!("{path} leaves its folder (..)")),
            s => out.push(s.to_string()),
        }
    }
    Ok(out)
}

/// Why a page request is not served.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PageFileRefusal {
    /// The request path leaves the root (`..`, an absolute path, a symlink out).
    OutsideRoot,
    /// Inside the root, but no such file.
    NotFound,
}

/// The file to serve for the URL path of a `cmux-app://<host>/<path>` request
/// (already percent-decoded), under `<app_dir>/<root>`. `/` serves
/// `index.html`. The file's real path (symlinks resolved) must stay inside the
/// root's real path, so a symlink in the app tree cannot reach out of it.
pub fn resolve_request(
    app_dir: &Path,
    root: &str,
    url_path: &str,
) -> Result<PathBuf, PageFileRefusal> {
    let root_segments = relative_segments(root).map_err(|_| PageFileRefusal::OutsideRoot)?;
    if root_segments.is_empty() {
        return Err(PageFileRefusal::OutsideRoot);
    }
    let trimmed = url_path.trim_start_matches('/');
    let mut segments = relative_segments(trimmed).map_err(|_| PageFileRefusal::OutsideRoot)?;
    if segments.is_empty() {
        segments.push("index.html".into());
    }
    let root_dir = root_segments.iter().fold(app_dir.to_path_buf(), |p, s| p.join(s));
    let real_root = root_dir.canonicalize().map_err(|_| PageFileRefusal::NotFound)?;
    // `segments` has no `..` and no absolute part (relative_segments), so only
    // a symlink can leave the root: the real-path check below catches it.
    let file = segments.iter().fold(root_dir, |p, s| p.join(s));
    let real = match file.canonicalize() {
        Ok(real) => real,
        Err(_) => return Err(PageFileRefusal::NotFound),
    };
    if !real.starts_with(&real_root) {
        return Err(PageFileRefusal::OutsideRoot);
    }
    if !real.is_file() {
        return Err(PageFileRefusal::NotFound);
    }
    Ok(real)
}

/// The app's CSP intersected with [`STRICT_PAGE_CSP`]: for each strict
/// directive, the sources both allow. The app's own directive applies, else
/// its `default-src`, else the app says nothing and the strict sources stay.
/// An empty intersection is `'none'`. Every other directive is closed by
/// `default-src 'none'`, and `base-uri` and `form-action` are closed too.
/// A malformed app CSP (a quote-less keyword, a comma) only drops sources:
/// the result is never wider than the strict policy.
pub fn effective_csp(app_csp: Option<&str>) -> String {
    let app = app_csp.map(parse_csp).unwrap_or_default();
    let app_sources = |name: &str| -> Option<&Vec<String>> {
        app.iter()
            .find(|(n, _)| n == name)
            .or_else(|| app.iter().find(|(n, _)| n == "default-src"))
            .map(|(_, s)| s)
    };
    let mut directives: Vec<String> = STRICT_PAGE_CSP
        .iter()
        .map(|(name, strict)| {
            let kept: Vec<&str> = match app_sources(name) {
                None => strict.to_vec(),
                Some(app) => strict.iter().copied().filter(|s| allows(app, s)).collect(),
            };
            let kept = if kept.is_empty() || kept == ["'none'"] { vec!["'none'"] } else { kept };
            format!("{name} {}", kept.join(" "))
        })
        .collect();
    directives.extend(CLOSED_NON_FETCH.iter().map(|name| format!("{name} 'none'")));
    directives.join("; ")
}

/// Whether the app's source list allows the strict source `source`.
fn allows(app: &[String], source: &str) -> bool {
    if app.iter().any(|s| s == "'none'") {
        return false;
    }
    app.iter().any(|s| {
        s == source
            // `*` matches any URL source, never a keyword or `data:`.
            || (s == "*" && !source.starts_with('\'') && !source.ends_with(':'))
    })
}

/// `(directive, sources)` pairs, names lowercased, first occurrence wins (as
/// browsers do).
fn parse_csp(raw: &str) -> Vec<(String, Vec<String>)> {
    let mut out: Vec<(String, Vec<String>)> = Vec::new();
    // A `,` starts a second policy in a header; only the first counts here,
    // and an app that sends two gets none of the second.
    let first = raw.split(',').next().unwrap_or_default();
    for directive in first.split(';') {
        let mut words = directive.split_ascii_whitespace();
        let Some(name) = words.next() else { continue };
        let name = name.to_ascii_lowercase();
        if out.iter().any(|(n, _)| *n == name) {
            continue;
        }
        let sources = words.map(|w| {
            let lower = w.to_ascii_lowercase();
            if lower.starts_with('\'') { lower } else { w.to_string() }
        });
        out.push((name, sources.collect()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn segments_refuse_escapes() {
        assert!(relative_segments("/etc").is_err());
        assert!(relative_segments("web/../..").is_err());
        assert!(relative_segments("web\\x").is_err());
        assert_eq!(relative_segments("./web//a").unwrap(), ["web", "a"]);
    }

    #[test]
    fn no_app_csp_is_the_strict_policy_plus_closed_extras() {
        assert_eq!(
            effective_csp(None),
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
             img-src 'self' data:; font-src 'self' data:; worker-src 'self'; base-uri 'none'; form-action 'none'"
        );
    }

    #[test]
    fn host_maps_the_id_slash() {
        assert_eq!(app_page_host("local/my-app"), "local.my-app");
        let m = json!({"id": "a/b", "runtime": {"web": {"root": "web/"}},
                       "implements": {"cmux.pane/1": {"web": "web/x/i.html"}}});
        assert_eq!(web_pages(&m)[0].url, "cmux-app://a.b/x/i.html");
    }
}
