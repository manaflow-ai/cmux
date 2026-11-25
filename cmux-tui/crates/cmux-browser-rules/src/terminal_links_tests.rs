//! The terminal link rules, pinned to the Swift they replace: every case of
//! TerminalLinkResolverSecurityTests, TerminalCmdClickLinkTests' printed path, TerminalLinkRemoteCandidatesTests,
//! CloudFileViewerTests' Cloud path and CloudFileRoutingTests' offline web links, plus the examples
//! TerminalLinkResolver's documentation names (on a temporary folder).

use crate::ops;
use crate::terminal_links::*;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

/// A folder of this test's own, removed when it drops.
struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let unique = format!(
            "terminal-link-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let path = std::env::temp_dir().join(unique);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &str {
        self.0.to_str().unwrap()
    }

    fn file(&self, relative: &str) -> String {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "report").unwrap();
        path.to_str().unwrap().to_owned()
    }

    fn folder(&self, relative: &str) -> String {
        let path = self.0.join(relative);
        std::fs::create_dir_all(&path).unwrap();
        path.to_str().unwrap().to_owned()
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn none() -> TerminalLinkContext {
    TerminalLinkContext::default()
}

fn at(cwd: &str) -> TerminalLinkContext {
    TerminalLinkContext { cwd: Some(cwd.to_owned()), ..TerminalLinkContext::default() }
}

fn web_only() -> TerminalLinkContext {
    TerminalLinkContext { allows_local_files: Some(false), ..TerminalLinkContext::default() }
}

fn url(text: &str) -> Option<TerminalLinkTarget> {
    Some(TerminalLinkTarget::Url { url: text.to_owned() })
}

/// `URL(fileURLWithPath:isDirectory:)` of a test path (no character a path test uses needs more
/// than the space's escape).
fn file(path: &str, is_directory: bool) -> Option<TerminalLinkTarget> {
    let mut url = format!("file://{}", path.replace(' ', "%20"));
    if is_directory && !url.ends_with('/') {
        url.push('/');
    }
    Some(TerminalLinkTarget::File { url, is_directory })
}

// TerminalLinkResolverSecurityTests

#[test]
fn rejects_schemes_and_web_addresses_outside_the_terminal_allowlist() {
    for text in [
        "javascript:alert(1)",
        "ssh://host.example/",
        "cmux://settings",
        "mailto:attacker@example.com",
        "data:text/html,payload",
        "ftp://host.example/file",
        "https://user:password@example.com/",
        "https://exa mple.com/",
        "https://example.com/\u{202E}txt",
        "https://example.com/%E2%80%AEtxt",
        "example.com/%E2%80%AEtxt",
    ] {
        assert_eq!(resolve(text, &none()), None, "{text:?}");
    }
}

#[test]
fn accepts_allowed_web_links() {
    for text in ["https://example.com/path", "http://localhost:3000/"] {
        assert_eq!(resolve(text, &none()), url(text), "{text:?}");
    }
}

#[test]
fn accepts_a_hostless_local_file_but_rejects_remote_file_sources() {
    let folder = Folder::new("security");
    let path = folder.file("report draft.txt");
    let absolute = format!("file://{}", path.replace(' ', "%20"));

    assert_eq!(resolve(&absolute, &none()), file(&path, false));
    assert_eq!(resolve(&path, &none()), file(&path, false));
    assert_eq!(resolve(&absolute, &web_only()), None);

    let foreign = format!("file://remote.example{}", path.replace(' ', "%20"));
    assert_eq!(resolve(&foreign, &none()), None);
    let foreign_folder = format!("file://remote.example{}/", folder.path());
    assert_eq!(resolve("report draft.txt", &at(&foreign_folder)), None);
}

// TerminalCmdClickLinkTests.aPrintedPathKeepsItsLineAndColumn

#[test]
fn a_printed_path_keeps_its_line_and_column() {
    assert_eq!(location("src/app.ts:3:5"), Some(Location { line: 3, column: Some(5) }));
    assert_eq!(location("\"notes/todo.md:12\","), Some(Location { line: 12, column: None }));
    assert_eq!(location("README.md"), None);
    assert_eq!(location("localhost:3000/docs"), None);
    assert_eq!(location("https://example.com:8080"), None);
}

// TerminalLinkRemoteCandidatesTests

#[cfg(unix)]
#[test]
fn dot_dot_folds_as_text_even_where_this_mac_has_a_symlink() {
    let root = Folder::new("remote");
    root.folder("real/sub");
    std::os::unix::fs::symlink(root.0.join("real"), root.0.join("link")).unwrap();
    let link = format!("{}/link", root.path());

    assert_eq!(
        remote_candidates("../notes.md", Some(&format!("{link}/sub"))),
        [format!("{link}/notes.md")]
    );
    assert_eq!(
        remote_candidates(&format!("{link}/sub/../notes.md"), None),
        [format!("{link}/notes.md")]
    );
}

#[test]
fn a_path_that_also_exists_on_this_mac_keeps_its_private_prefix() {
    assert_eq!(remote_candidates("/private/etc/hosts", None), ["/private/etc/hosts"]);
    assert_eq!(remote_candidates("hosts:3", Some("/private/etc")), ["/private/etc/hosts"]);
}

#[test]
fn private_stays_in_a_vm_path() {
    assert_eq!(remote_candidates("/private/var/tmp/../log/x.md", None), ["/private/var/log/x.md"]);
    assert_eq!(remote_candidates("x.md", Some("/private/tmp/./a")), ["/private/tmp/a/x.md"]);
}

#[test]
fn dot_dot_never_leaves_the_root() {
    assert_eq!(remote_candidates("../../x.md", Some("/home")), ["/x.md"]);
    assert_eq!(remote_candidates("/a//b/./c/", None), ["/a/b/c"]);
}

// CloudFileViewerTests.aCloudTerminalsPathNamesTheMachinesFile

#[test]
fn a_cloud_terminals_path_names_the_machines_file() {
    assert_eq!(
        remote_candidates("/home/cmux/app/README.md:12", Some("/tmp")),
        ["/home/cmux/app/README.md"]
    );
    assert_eq!(
        remote_candidates("“src/main.rs:3:5”,", Some("/home/cmux/app")),
        ["/home/cmux/app/src/main.rs"]
    );
    assert_eq!(
        remote_candidates("../notes.md", Some("file://vm/home/cmux/app")),
        ["/home/cmux/notes.md"]
    );
    // A URL keeps its own route; `~` is that machine's home, unknown here; no folder, no path.
    assert!(remote_candidates("https://example.com/a.md", Some("/home/cmux")).is_empty());
    assert!(remote_candidates("~/notes.md", Some("/home/cmux")).is_empty());
    assert!(remote_candidates("notes.md", None).is_empty());
}

// CloudFileRoutingTests.offlineTerminalWebLinksKeepTheirBrowserFallback

#[test]
fn offline_terminal_web_links_keep_their_browser_fallback() {
    assert_eq!(resolve("docs.rs/serde", &web_only()), url("https://docs.rs/serde"));
    assert_eq!(resolve("www.example.com", &web_only()), url("https://www.example.com"));
    assert_eq!(resolve("localhost:3000/docs", &web_only()), url("http://localhost:3000/docs"));
}

// TerminalLinkResolver's documented examples.

#[test]
fn quotes_brackets_and_trailing_punctuation_go_and_a_closing_parenthesis_that_closes_one_stays() {
    assert_eq!(trim("  \"build-fleet/ORG-BACKUP.md\",  "), "build-fleet/ORG-BACKUP.md");
    assert_eq!(trim("~/Desktop/reply.md."), "~/Desktop/reply.md");
    assert_eq!(trim("“notes.md”;"), "notes.md");
    assert_eq!(trim("<https://example.com/a>"), "https://example.com/a");
    assert_eq!(trim("wiki/Foo_(bar)"), "wiki/Foo_(bar)");
    assert_eq!(trim("(wiki/Foo_(bar))."), "wiki/Foo_(bar)");
    assert_eq!(trim("src/app.ts:3:5:"), "src/app.ts:3:5");
}

#[test]
fn a_relative_path_resolves_under_the_terminals_folder_then_the_git_root() {
    let repo = Folder::new("git");
    repo.folder(".git");
    let backup = repo.file("build-fleet/ORG-BACKUP.md");
    let code = repo.file("sub/src/app.ts");
    let sub = repo.folder("sub");

    assert_eq!(resolve("\"build-fleet/ORG-BACKUP.md\",", &at(repo.path())), file(&backup, false));
    assert_eq!(resolve("\"build-fleet/ORG-BACKUP.md\",", &at(&sub)), file(&backup, false));
    assert_eq!(resolve("src/app.ts:3:5", &at(&sub)), file(&code, false));
    let osc7 = format!("file://{sub}");
    assert_eq!(resolve("src/app.ts:3", &at(&osc7)), file(&code, false));
    let named = TerminalLinkContext {
        cwd: Some(format!("file://my-mac.local{sub}")),
        local_host_names: Some(vec!["my-mac.local".into()]),
        ..TerminalLinkContext::default()
    };
    assert_eq!(resolve("src/app.ts", &named), file(&code, false));
    assert_eq!(resolve("src/app.ts", &at(&format!("file://other-mac{sub}"))), None);
    assert_eq!(resolve("src", &at(&sub)), file(&format!("{sub}/src"), true));
    assert_eq!(resolve("../build-fleet/ORG-BACKUP.md", &at(&sub)), file(&backup, false));
    // A path that exists nowhere is no link, and never a web host.
    assert_eq!(resolve("build-fleet/x.md", &at(&sub)), None);
    assert_eq!(resolve("build-fleet/x.md", &none()), None);
    // Local files never open where the terminal may not (a Cloud workspace).
    let web = TerminalLinkContext { allows_local_files: Some(false), ..at(repo.path()) };
    assert_eq!(resolve("build-fleet/ORG-BACKUP.md", &web), None);
}

#[test]
fn a_tilde_path_resolves_under_home() {
    let home = Folder::new("home");
    let reply = home.file("Desktop/reply.md");
    let context = TerminalLinkContext {
        home: Some(home.path().to_owned()),
        ..TerminalLinkContext::default()
    };
    assert_eq!(resolve("~/Desktop/reply.md.", &context), file(&reply, false));
    assert_eq!(resolve("~/Desktop", &context), file(&format!("{}/Desktop", home.path()), true));
    assert_eq!(resolve("~/Desktop/missing.md", &context), None);
}

#[test]
fn a_web_host_without_a_scheme_needs_localhost_an_ip_with_a_port_or_a_real_top_level_domain() {
    assert_eq!(resolve("localhost:3000/docs", &none()), url("http://localhost:3000/docs"));
    assert_eq!(resolve("app.localhost/x", &none()), url("http://app.localhost/x"));
    assert_eq!(resolve("docs.rs/serde", &none()), url("https://docs.rs/serde"));
    assert_eq!(resolve("example.com:8080", &none()), url("https://example.com:8080"));
    assert_eq!(resolve("192.168.1.2:8080/x", &none()), url("http://192.168.1.2:8080/x"));
    for text in [
        "192.168.1.2",
        "192.168.1.2/x",
        "README.md",
        "notes.sh",
        "build-fleet/x.md",
        "example.invalidtld/x",
        "user@example.com/x",
        "exa_mple.com/x",
        "example.com:80a/x",
    ] {
        assert_eq!(resolve(text, &none()), None, "{text:?}");
    }
    // The top-level domain test is the caller's.
    assert_eq!(
        resolve_with("example.zz/x", &none(), |tld| tld == "zz"),
        url("https://example.zz/x")
    );
}

#[test]
fn controls_and_invisible_formatting_are_never_a_link() {
    for text in
        ["https://example.com/\u{7}", "https://example.com/\u{200B}", "example.com/\u{2066}x", ""]
    {
        assert_eq!(resolve(text, &none()), None, "{text:?}");
    }
    assert!(remote_candidates("/a/\u{200E}b", None).is_empty());
}

#[test]
fn a_file_url_with_a_query_port_or_credentials_is_refused() {
    let folder = Folder::new("query");
    let path = folder.file("a.md");
    assert_eq!(resolve(&format!("file://{path}"), &none()), file(&path, false));
    assert_eq!(resolve(&format!("file://localhost{path}"), &none()), file(&path, false));
    for text in [
        format!("file://{path}?x"),
        format!("file://{path}#x"),
        format!("file://localhost:22{path}"),
        format!("file://me@localhost{path}"),
    ] {
        assert_eq!(resolve(&text, &none()), None, "{text:?}");
    }
}

#[test]
fn the_ops_answer_in_swifts_codable_shape() {
    let folder = Folder::new("ops");
    let path = folder.file("a b.md");
    let reply = ops::call(
        "browser_rules_terminal_link",
        json!({"text": "\"a b.md:3\",", "cwd": folder.path(), "allowsLocalFiles": true,
               "localHostNames": ["localhost"]}),
    )
    .unwrap();
    let expected = format!("file://{}", path.replace(' ', "%20"));
    assert_eq!(reply, json!({"file": {"_0": expected, "isDirectory": false}}));
    assert_eq!(
        ops::call("browser_rules_terminal_link", json!({"text": "docs.rs/serde"})),
        Ok(json!({"url": {"_0": "https://docs.rs/serde"}}))
    );
    assert_eq!(
        ops::call("browser_rules_terminal_link", json!({"text": "nope.md"})),
        Ok(json!(null))
    );
    assert_eq!(
        ops::call("browser_rules_terminal_link_location", json!({"text": "src/app.ts:3:5"})),
        Ok(json!({"line": 3, "column": 5}))
    );
    assert_eq!(
        ops::call("browser_rules_terminal_link_location", json!({"text": "a.ts:3"})),
        Ok(json!({"line": 3, "column": null}))
    );
    assert_eq!(
        ops::call(
            "browser_rules_terminal_link_remote_candidates",
            json!({"text": "../notes.md", "cwd": "/home/cmux/app"})
        ),
        Ok(json!(["/home/cmux/notes.md"]))
    );
    assert_eq!(
        ops::call("browser_rules_terminal_link_trim", json!({"text": "(wiki/Foo_(bar))."})),
        Ok(json!("wiki/Foo_(bar)"))
    );
    assert!(Path::new(&path).exists());
}
