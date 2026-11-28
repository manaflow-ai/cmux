//! Parity with the Swift `ExternalOpenRouter` cases these rules came from
//! (ExternalLinkGateTests, ShareLinkRouteTests, ExternalImageOpenTests). Each
//! link is given as Foundation's `URL` reads it.

use super::*;

const SHARE: &str = "c2hhcmUtMDAwMDAwMDAwMDAx";

fn web(absolute: &str, scheme: &str, host: &str, path: &str) -> Link {
    Link {
        absolute: absolute.to_owned(),
        scheme: Some(scheme.to_owned()),
        host: Some(host.to_owned()),
        path_encoded: path.to_owned(),
        path: path.to_owned(),
        ..Link::default()
    }
}

fn open(link: Link) -> Route {
    route(&Request { link, link_scheme: Some("cmux-dev".to_owned()), ..Request::default() })
}

#[test]
fn a_share_page_opens_as_a_share_link() {
    for (host, path) in [
        ("share.cmux.dev", format!("/g/{SHARE}")),
        ("share-dev.cmux.dev", format!("/i/{SHARE}")),
        ("cmux-platform-production.debussy.workers.dev", format!("/g/{SHARE}/")),
    ] {
        let link = web(&format!("https://{host}{path}"), "https", host, &path);
        assert_eq!(open(link), Route::ShareLink, "{host}{path}");
    }
}

#[test]
fn the_guest_pages_app_link_opens_as_a_share_link() {
    let mut link = web("cmux-dev://share?link=x", "cmux-dev", "share", "");
    link.query = true;
    assert_eq!(open(link), Route::ShareLink);
    // Another build's scheme is not this build's link; other hosts of this
    // scheme stay deep links.
    assert_eq!(
        open(web("cmux-nightly://share?link=x", "cmux-nightly", "share", "")),
        Route::Unsupported
    );
    assert_eq!(open(web("cmux-dev://tab/1", "cmux-dev", "tab", "/1")), Route::DeepLink);
    assert_eq!(
        open(web("CMUX-DEV://tab/1", "CMUX-DEV", "tab", "/1")),
        Route::DeepLink,
        "schemes compare without case"
    );
    let mut callback = web("cmux-dev://auth-callback?code=1", "cmux-dev", "auth-callback", "");
    callback.auth_callback = true;
    assert_eq!(open(callback), Route::Unsupported);
}

#[test]
fn no_build_scheme_routes_no_links() {
    let link = web("cmux-dev://tab/1", "cmux-dev", "tab", "/1");
    assert_eq!(route(&Request { link, ..Request::default() }), Route::Unsupported);
}

#[test]
fn other_pages_stay_browser_tabs() {
    for (absolute, scheme, host, path) in [
        ("https://example.com/g/short", "https", "example.com", "/g/short".to_owned()),
        ("", "https", "example.com", format!("/g/{SHARE}/more")),
        ("", "https", "example.com", format!("/x/{SHARE}")),
        ("", "http", "share.cmux.dev", format!("/g/{SHARE}")),
        ("https://share.cmux.dev/", "https", "share.cmux.dev", "/".to_owned()),
    ] {
        assert_eq!(
            open(web(absolute, scheme, host, &path)),
            Route::BrowserTab,
            "{scheme}://{host}{path}"
        );
    }
}

#[test]
fn the_screen_links_web_form_is_a_deep_link() {
    for path in ["/deeplink/screen", "/deeplink/screen/", "/deeplink/screen//"] {
        assert_eq!(open(web("", "https", "cmux.com", path)), Route::DeepLink, "{path}");
    }
    assert_eq!(open(web("", "https", "WWW.cmux.com", "/deeplink/screen")), Route::DeepLink);
    assert_eq!(open(web("", "http", "cmux.com", "/deeplink/screen")), Route::BrowserTab);
    assert_eq!(open(web("", "https", "evil.com", "/deeplink/screen")), Route::BrowserTab);
}

#[test]
fn a_web_link_from_inside_cmux_keeps_only_web_and_build_routes() {
    let web_link = |link: Link, file: Option<File>| {
        route(&Request {
            link,
            file,
            link_scheme: Some("cmux-dev".to_owned()),
            mode: Mode::WebLink,
        })
    };
    let share = format!("/g/{SHARE}");
    assert_eq!(web_link(web("", "https", "share.cmux.dev", &share), None), Route::ShareLink);
    assert_eq!(web_link(web("", "https", "example.com", "/"), None), Route::BrowserTab);
    assert_eq!(web_link(web("", "cmux-dev", "tab", "/1"), None), Route::DeepLink);
    let page = File { path: "/a/page.html".into(), ext: "html".into(), ..File::default() };
    assert_eq!(web_link(web("", "file", "", "/a/page.html"), Some(page)), Route::Unsupported);
    let man = Link {
        path_components: vec!["ls".into()],
        ..web("x-man-page://ls", "x-man-page", "ls", "")
    };
    assert_eq!(web_link(man, None), Route::Unsupported, "never a terminal command");
}

#[test]
fn a_page_continued_from_another_device_opens_as_a_tab_or_share_link() {
    let continuing =
        |link: Link| route(&Request { link, mode: Mode::Continuing, ..Request::default() });
    let share = format!("/g/{SHARE}");
    assert_eq!(continuing(web("", "https", "share.cmux.dev", &share)), Route::ShareLink);
    assert_eq!(continuing(web("", "https", "example.com", "/docs")), Route::BrowserTab);
    assert_eq!(continuing(web("", "https", "cmux.com", "/deeplink/screen")), Route::DeepLink);
    assert_eq!(continuing(web("", "ssh", "host", "")), Route::Unsupported);
    assert_eq!(
        continuing(web("", "cmux-dev", "tab", "/1")),
        Route::Unsupported,
        "only web pages continue"
    );
}

fn file(path: &str, ext: &str) -> File {
    let folder = path.rsplit_once('/').map_or("", |(folder, _)| folder);
    File {
        path: path.to_owned(),
        folder: folder.to_owned(),
        ext: ext.to_owned(),
        ..File::default()
    }
}

#[test]
fn an_image_goes_to_a_chat() {
    for (name, ext) in [("photo.JPG", "jpg"), ("IMG_1.HEIC", "heic"), ("a.gif", "gif")] {
        let image = File { is_image: true, ..file(&format!("/Users/me/Desktop/{name}"), ext) };
        assert_eq!(route_file(&image), Route::AttachImage, "{name}");
    }
}

#[test]
fn other_files_keep_their_routes() {
    let folder = File { is_directory: true, ..file("/Users/me/folder", "") };
    assert_eq!(
        route_file(&folder),
        Route::Terminal { cwd: Some("/Users/me/folder".into()), command: None }
    );
    let svg = File { is_image: true, ..file("/Users/me/logo.svg", "svg") };
    assert_eq!(route_file(&svg), Route::BrowserFile, "SVG stays a page");
    assert_eq!(route_file(&file("/Users/me/page.html", "html")), Route::BrowserFile);
    assert_eq!(
        route_file(&file("/Users/me/run.sh", "sh")),
        Route::Terminal {
            cwd: Some("/Users/me".into()),
            command: Some("sh '/Users/me/run.sh'".into())
        }
    );
    let executable_script = File { is_executable: true, ..file("/Users/me/go.command", "command") };
    assert_eq!(
        route_file(&executable_script),
        Route::Terminal {
            cwd: Some("/Users/me".into()),
            command: Some("'/Users/me/go.command'".into())
        }
    );
    assert_eq!(
        route_file(&file("/Users/me/x.pl", "pl")),
        Route::Terminal {
            cwd: Some("/Users/me".into()),
            command: Some("perl '/Users/me/x.pl'".into())
        }
    );
    let tool = File { is_executable: true, ..file("/Users/me/tool", "") };
    assert_eq!(
        route_file(&tool),
        Route::Terminal { cwd: Some("/Users/me".into()), command: Some("'/Users/me/tool'".into()) }
    );
    for (name, ext) in
        [("README.md", "md"), ("doc.pdf", "pdf"), ("notes.txt", "txt"), ("clip.mov", "mov")]
    {
        assert_eq!(route_file(&file(&format!("/Users/me/{name}"), ext)), Route::File, "{name}");
    }
    assert_eq!(
        route_file(&file("/Users/me/plain", "")),
        Route::File,
        "no extension, not executable"
    );
}

#[test]
fn a_file_link_routes_by_its_file() {
    let request = Request {
        link: web("file:///Users/me/run.sh", "file", "", "/Users/me/run.sh"),
        file: Some(file("/Users/me/run.sh", "sh")),
        ..Request::default()
    };
    assert_eq!(
        route(&request),
        Route::Terminal {
            cwd: Some("/Users/me".into()),
            command: Some("sh '/Users/me/run.sh'".into())
        }
    );
}

fn ssh_link(absolute: &str, user: Option<&str>, host: &str, port: Option<i64>) -> Link {
    Link {
        absolute: absolute.to_owned(),
        scheme: Some("ssh".to_owned()),
        host: Some(host.to_owned()),
        user: user.map(str::to_owned),
        port,
        ..Link::default()
    }
}

fn target(route: Route) -> SshTarget {
    match route {
        Route::Ssh { target } => target,
        other => panic!("not an ssh route: {other:?}"),
    }
}

#[test]
fn an_ssh_link_routes_to_its_target() {
    let leo = target(open(ssh_link(
        "ssh://leo@build.example.com:2222",
        Some("leo"),
        "build.example.com",
        Some(2222),
    )));
    assert_eq!(
        leo,
        SshTarget { user: Some("leo".into()), host: "build.example.com".into(), port: Some(2222) }
    );
    let mut slash = ssh_link("ssh://cosmic-gray/", None, "cosmic-gray", None);
    slash.path_encoded = "/".into();
    assert_eq!(target(open(slash)).host, "cosmic-gray");
}

#[test]
fn a_crafted_link_never_routes() {
    let crafted = [
        ssh_link("ssh://-oProxyCommand=evil", None, "-oProxyCommand=evil", None),
        ssh_link("ssh://-l@host", Some("-l"), "host", None),
        ssh_link("ssh://h%C3%B6st.example", None, "h\u{f6}st.example", None),
        ssh_link("ssh://%D0%B0pple.example", None, "\u{430}pple.example", None),
        ssh_link("ssh://host;rm%20-rf", None, "host;rm -rf", None),
        ssh_link("ssh://host:0", None, "host", Some(0)),
        ssh_link("ssh://us%27er@host", Some("us'er"), "host", None),
        Link { password: true, ..ssh_link("ssh://leo:secret@host", Some("leo"), "host", None) },
        Link { path_encoded: "/path".into(), ..ssh_link("ssh://host/path", None, "host", None) },
        Link { query: true, ..ssh_link("ssh://host?x=1", None, "host", None) },
        Link { fragment: true, ..ssh_link("ssh://host#frag", None, "host", None) },
        ssh_link("ssh://host:", None, "host", None),
        ssh_link("ssh://leo@[::1]:", Some("leo"), "::1", None),
        ssh_link("ssh://k\u{212a}.example", None, "kk.example", None),
        Link { host: None, ..ssh_link("ssh://", None, "", None) },
    ];
    for link in crafted {
        let absolute = link.absolute.clone();
        assert_eq!(open(link), Route::Unsupported, "{absolute}");
    }
}

#[test]
fn an_ipv6_host_with_a_port_routes() {
    let v6 = target(open(ssh_link("ssh://leo@[::1]:2222", Some("leo"), "::1", Some(2222))));
    let strings = v6.strings();
    assert_eq!(strings.display, "leo@[::1]:2222");
    assert_eq!(strings.command, "ssh -p 2222 -- 'leo@[::1]'");
    let plain = target(open(ssh_link("ssh://build.example.com", None, "build.example.com", None)));
    assert_eq!(plain.strings().command, "ssh -- 'build.example.com'");
    assert_eq!(plain.strings().display, "build.example.com");
}

#[test]
fn an_ipv6_zone_keeps_its_spelling_in_the_trust_key() {
    assert_eq!(trust_key("[FE80::1%en0]"), "fe80::1%en0");
    assert_eq!(trust_key("FE80::1%EN0"), "fe80::1%EN0");
    assert_eq!(trust_key("Lab.Example.COM"), "lab.example.com");
    assert_eq!(trust_key(" Lab.Example.COM\t"), "lab.example.com");
    assert_eq!(trust_key("\u{212a}.example"), "\u{212a}.example", "the Kelvin sign is not folded");
    assert_eq!(trust_key("[]"), "");
    assert_eq!(trust_key("["), "[", "an unclosed bracket stays");
}

#[test]
fn a_man_page_link_types_man_with_its_section_and_topic() {
    let man = |host: Option<&str>, components: &[&str]| {
        open(Link {
            scheme: Some("x-man-page".into()),
            host: host.map(str::to_owned),
            path_components: components.iter().map(|part| (*part).to_owned()).collect(),
            ..Link::default()
        })
    };
    let typed = |command: &str| Route::Terminal { cwd: None, command: Some(command.into()) };
    assert_eq!(man(Some("ls"), &[]), typed("man 'ls'"));
    assert_eq!(man(Some("1"), &["/", "ls"]), typed("man '1' 'ls'"));
    assert_eq!(man(None, &["/", "ls"]), typed("man 'ls'"));
    assert_eq!(man(Some("1"), &["/", "2", "ls"]), Route::Unsupported, "one section at most");
    assert_eq!(man(Some("-k"), &[]), Route::Unsupported);
    assert_eq!(man(Some("1"), &["/", "ls;rm"]), Route::Unsupported);
    assert_eq!(man(None, &[]), Route::Unsupported);
}

#[test]
fn the_sign_in_callback_reads_in_every_form() {
    assert!(is_sign_in_callback(Some("auth-callback"), ""));
    assert!(is_sign_in_callback(Some("Auth-Callback"), ""));
    assert!(is_sign_in_callback(None, "auth-callback"));
    assert!(is_sign_in_callback(Some(""), "/auth-callback"));
    assert!(!is_sign_in_callback(Some("tab"), "/auth-callback"));
    assert!(!is_sign_in_callback(None, "/tab"));
}

#[test]
fn shell_quoting_closes_and_reopens_around_a_quote() {
    assert_eq!(shell_quote("it's"), r"'it'\''s'");
}

#[test]
fn requests_read_from_the_apps_json() {
    let request: Request = serde_json::from_str(
        r#"{"link":{"absolute":"ssh://h","scheme":"ssh","host":"h","pathComponents":[]},"mode":"open"}"#,
    )
    .unwrap();
    assert_eq!(target(route(&request)).host, "h");
}
