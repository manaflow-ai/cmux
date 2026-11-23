//! `embed` panes (plans/cmux-next/extensions/DESIGN.md section 5): an
//! external web app in a pane, on a browser profile of its app only, that
//! navigates only to its url's origin and the declared origins.

use cmux_app_manifest::{
    Severity, embed_allows, embed_pages, embed_profile_id, is_valid, validate_manifest,
};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    fn embed_app(id: &str, interface: &str, embed: Value) -> Value {
        json!({
            "manifestVersion": 2,
            "id": id,
            "name": "Figma",
            "version": "1.0.0",
            "description": "d",
            "repository": "https://github.com/octo/figma",
            "icon": "icon.png",
            "engines": { "cmux": "^2.0" },
            "presentation": { "tab": true },
            "implements": { interface: { "embed": embed, "symbol": "paintbrush" } }
        })
    }

    fn figma(origins: Value) -> Value {
        embed_app(
            "octo/figma",
            "cmux.pane/1",
            json!({ "url": "https://www.figma.com/files", "origins": origins }),
        )
    }

    fn codes(m: &Value) -> Vec<&'static str> {
        validate_manifest(m)
            .into_iter()
            .filter(|i| i.severity == Severity::Error)
            .map(|i| i.code)
            .collect()
    }

    #[test]
    fn an_embed_lists_its_url_origin_then_the_declared_ones() {
        let m = figma(json!(["https://*.figma.com", "https://accounts.google.com"]));
        assert!(is_valid(&validate_manifest(&m)), "{:?}", validate_manifest(&m));
        let pages = embed_pages(&m);
        assert_eq!(pages.len(), 1);
        let page = &pages[0];
        assert_eq!(page.interface, "cmux.pane/1");
        assert_eq!(page.url, "https://www.figma.com/files");
        assert_eq!(
            page.origins,
            ["https://www.figma.com", "https://*.figma.com", "https://accounts.google.com"]
        );
        assert_eq!(page.profile, embed_profile_id("octo/figma"));
        assert_eq!(page.symbol.as_deref(), Some("paintbrush"));
        // The url's host is lowercased into its origin.
        let mixed = embed_app("octo/f", "cmux.pane/1", json!({ "url": "https://WWW.Figma.com/x" }));
        assert_eq!(embed_pages(&mixed)[0].origins, ["https://www.figma.com"]);
    }

    #[test]
    fn each_app_has_its_own_stable_profile() {
        let a = embed_pages(&figma(json!([])))[0].profile.clone();
        let again = embed_pages(&figma(json!(["https://figma.com"])))[0].profile.clone();
        let other = embed_pages(&embed_app(
            "evil/figma",
            "cmux.pane/1",
            json!({ "url": "https://www.figma.com/" }),
        ))[0]
            .profile
            .clone();
        assert_eq!(a, again, "an update keeps the sign-in");
        assert_ne!(a, other, "two apps never share cookies");
    }

    #[test]
    fn navigation_stays_on_declared_origins() {
        let origins =
            embed_pages(&figma(json!(["https://*.figma.com", "https://accounts.google.com"])))[0]
                .origins
                .clone();
        for ok in [
            "https://www.figma.com/file/abc?x=1",
            "https://static.figma.com/a.js",
            "https://deep.sub.figma.com/",
            "https://ACCOUNTS.google.com/o/oauth2",
            "https://accounts.google.com:443/",
        ] {
            assert!(embed_allows(&origins, ok), "{ok}");
        }
        for refused in [
            "https://figma.com.evil.com/",
            "https://evilfigma.com/",
            "https://google.com/",
            "https://mail.google.com/",
            "http://www.figma.com/",
            "https://www.figma.com:8443/",
            "https://user@www.figma.com/",
            "javascript:alert(1)",
            "file:///etc/passwd",
        ] {
            assert!(!embed_allows(&origins, refused), "{refused}");
        }
        // `*.figma.com` is subdomains only; the apex needs its own entry.
        assert!(!embed_allows(&["https://*.figma.com".to_string()], "https://figma.com/"));
    }

    #[test]
    fn origins_must_be_public_https_hosts() {
        for (bad, at) in [
            (json!(["https://intranet.local"]), 0),
            (json!(["https://figma.com", "https://10.0.0.1"]), 1),
            (json!(["https://localhost"]), 0),
        ] {
            let m = figma(bad);
            let issues = validate_manifest(&m);
            let want = format!("/implements/cmux.pane~11/embed/origins/{at}");
            assert!(
                issues.iter().any(|i| i.code == "embed.origin" && i.path == want),
                "{issues:?}"
            );
            assert!(embed_pages(&m).is_empty(), "a refused embed is never listed");
        }
        let m = embed_app("octo/x", "cmux.pane/1", json!({ "url": "https://127.0.0.1/" }));
        assert!(codes(&m).contains(&"embed.origin"), "{:?}", codes(&m));
    }

    #[test]
    fn an_embed_implements_cmux_pane_only() {
        let m = embed_app("octo/x", "cmux.editor/1", json!({ "url": "https://www.figma.com/" }));
        assert!(codes(&m).contains(&"embed.interface"), "{:?}", codes(&m));
        assert!(embed_pages(&m).is_empty());
    }

    #[test]
    fn the_schema_refuses_http_and_paths_in_origins() {
        for embed in [
            json!({ "url": "http://www.figma.com/" }),
            json!({ "url": "https://www.figma.com/", "origins": ["https://figma.com/path"] }),
            json!({ "url": "https://www.figma.com/", "extra": true }),
            json!({ "origins": [] }),
        ] {
            let m = embed_app("octo/x", "cmux.pane/1", embed.clone());
            assert!(!is_valid(&validate_manifest(&m)), "{embed}");
        }
        // An embed is one shape of an implementation, never two.
        let mut m = figma(json!([]));
        m["implements"]["cmux.pane/1"]["web"] = json!("web/index.html");
        assert!(!is_valid(&validate_manifest(&m)));
    }
}
