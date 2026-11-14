//! `render: web` panes (plans/cmux-next/extensibility-DESIGN.md section 4,
//! step 5): the manifest keeps a web implementation, its root stays inside
//! the app, and its CSP only narrows the strict page policy.

use std::path::Path;

use cmux_app_manifest::{
    PageFileRefusal, effective_csp, resolve_request, validate_manifest, validate_package_file,
    web_pages,
};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    fn codemirror_dir() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../first-party-apps/codemirror")
    }

    fn web_app(root: &str, web: &str, csp: Option<&str>) -> Value {
        let mut runtime = json!({ "root": root });
        if let Some(csp) = csp {
            runtime["csp"] = json!(csp);
        }
        json!({
            "manifestVersion": 2,
            "id": "octo/board",
            "name": { "en": "Board" },
            "version": "1.0.0",
            "description": { "en": "A board." },
            "publisher": { "name": "octo" },
            "repository": "https://github.com/octo/board",
            "license": "MIT",
            "icon": "assets/icon.svg",
            "engines": { "cmux": "^2.0" },
            "runtime": { "web": runtime },
            "implements": { "cmux.pane/1": { "web": web, "title": { "en": "Board" } } },
            "files": ["web/", "assets/"]
        })
    }

    fn codes(m: &Value) -> Vec<&'static str> {
        validate_manifest(m).into_iter().map(|i| i.code).collect()
    }

    #[test]
    fn codemirror_keeps_its_web_entry() {
        let report = validate_package_file(&codemirror_dir(), "cmux-app.v2.json");
        assert!(report.is_valid(), "{:?}", report.issues);
        let pages = web_pages(&report.manifest.expect("manifest"));
        assert_eq!(pages.len(), 1, "{pages:?}");
        let page = &pages[0];
        assert_eq!(page.interface, "cmux.editor/1");
        assert_eq!(page.origin, "cmux-app://cmux.codemirror/");
        assert_eq!((page.root.as_str(), page.entry.as_str()), ("web", "index.html"));
        assert_eq!(page.url, "cmux-app://cmux.codemirror/index.html");
        assert_eq!(page.symbol.as_deref(), Some("doc.text"));
        // The entry the host serves is the shipped file.
        let file = resolve_request(&codemirror_dir(), &page.root, "/")
            .unwrap_or_else(|e| panic!("{e:?} under {}", codemirror_dir().display()));
        assert!(file.ends_with("web/index.html"), "{}", file.display());
    }

    #[test]
    fn a_pane_web_entry_is_a_page() {
        let pages = web_pages(&web_app("web/", "web/index.html", None));
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].interface, "cmux.pane/1");
        assert_eq!(pages[0].url, "cmux-app://octo.board/index.html");
        assert!(codes(&web_app("web/", "web/index.html", None)).is_empty());
    }

    #[test]
    fn a_root_that_escapes_the_app_is_refused() {
        for root in ["../web", "/etc", "web/../..", "./", "web\\..\\x"] {
            let m = web_app(root, "web/index.html", None);
            let found = codes(&m);
            assert!(
                found.iter().any(|c| *c == "schema" || *c == "runtime.web.root"),
                "{root}: {found:?}"
            );
            assert!(web_pages(&m).is_empty(), "{root} must open no page");
        }
    }

    #[test]
    fn an_entry_outside_the_root_is_refused() {
        let m = web_app("web/", "assets/page.html", None);
        assert_eq!(codes(&m), ["web.outsideRoot"]);
        assert!(web_pages(&m).is_empty());
        // The root itself is not a page.
        assert_eq!(codes(&web_app("web/", "web", None)), ["web.outsideRoot"]);
    }

    #[test]
    fn requests_cannot_leave_the_root() {
        let dir = codemirror_dir();
        for path in ["/../cmux-app.v2.json", "/..%2f", "/../../README.md", "//etc/passwd"] {
            let got = resolve_request(&dir, "web", path);
            assert!(
                matches!(got, Err(PageFileRefusal::OutsideRoot | PageFileRefusal::NotFound)),
                "{path}: {got:?}"
            );
            if let Ok(file) = got {
                panic!("{path} served {}", file.display());
            }
        }
        assert_eq!(
            resolve_request(&dir, "web", "/../cmux-app.v2.json"),
            Err(PageFileRefusal::OutsideRoot)
        );
        assert_eq!(resolve_request(&dir, "web", "/nope.js"), Err(PageFileRefusal::NotFound));
        assert!(resolve_request(&dir, "web", "/main.js").is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_out_of_the_root_is_refused() {
        let tmp = std::env::temp_dir().join(format!("cmux-web-pane-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("web")).expect("mkdir");
        std::fs::write(tmp.join("secret.txt"), "no").expect("write");
        std::fs::write(tmp.join("web/index.html"), "<p>ok</p>").expect("write");
        std::os::unix::fs::symlink(tmp.join("secret.txt"), tmp.join("web/leak.txt"))
            .expect("symlink");
        assert_eq!(resolve_request(&tmp, "web", "/leak.txt"), Err(PageFileRefusal::OutsideRoot));
        assert!(resolve_request(&tmp, "web", "/").is_ok());
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn the_csp_is_the_app_csp_intersected_with_the_strict_policy() {
        // codemirror: default-src 'self'; style-src 'self' 'unsafe-inline'.
        let csp = effective_csp(Some("default-src 'self'; style-src 'self' 'unsafe-inline'"));
        assert_eq!(
            csp,
            "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
             img-src 'self'; font-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'"
        );
    }

    #[test]
    fn an_app_csp_can_never_widen_the_strict_policy() {
        let csp = effective_csp(Some(
            "default-src *; script-src * 'unsafe-eval' 'unsafe-inline' 'self' https://evil.example; \
             connect-src https://evil.example; frame-src *; img-src * data: blob:",
        ));
        for banned in ["evil.example", "unsafe-eval", "blob:", "connect-src", "frame-src", " *"] {
            assert!(!csp.contains(banned), "{banned} leaked into {csp}");
        }
        assert!(csp.starts_with("default-src 'none'; script-src 'self' 'unsafe-inline';"), "{csp}");
        // `*` matches URLs on network schemes, never 'self' on cmux-app://, so only data: stays.
        assert!(csp.contains("img-src data:;"), "{csp}");
    }

    #[test]
    fn an_app_none_or_garbage_only_narrows() {
        assert!(effective_csp(Some("script-src 'none'")).contains("script-src 'none'"));
        // A second policy after a comma is ignored, not merged.
        let csp = effective_csp(Some("img-src 'self', img-src https://x.example"));
        assert!(csp.contains("img-src 'self';") && !csp.contains("x.example"), "{csp}");
        // Unknown junk keeps the strict policy.
        assert_eq!(effective_csp(Some(";;;")), effective_csp(None));
    }
}
