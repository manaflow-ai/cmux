use super::*;

fn words(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn open(values: &[&str]) -> Result<Open, String> {
    parse_open(&words(values), Path::new("/work"))
}

const CLIP: &str = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/49596/tool-burst-clean-send-x1.mp4";

#[test]
fn one_source_is_a_url_or_a_path() {
    let one = open(&[CLIP]).unwrap();
    assert_eq!(one.sources, vec![Source::Web(CLIP.into())]);
    assert_eq!((one.looping, one.rate, one.place.len()), (false, 1.0, 0));
    assert_eq!(one.sources[0].name(), "tool-burst-clean-send-x1.mp4");
    let local = open(&["clips/demo.MOV"]).unwrap();
    assert_eq!(local.sources, vec![Source::Local(PathBuf::from("/work/clips/demo.MOV"))]);
    assert_eq!(local.sources[0].extension(), "mov");
    let file_url = open(&["file:///tmp/a%20b.webm"]).unwrap();
    assert_eq!(file_url.sources, vec![Source::Local(PathBuf::from("/tmp/a b.webm"))]);
    let absolute = open(&["/abs/x.m4v"]).unwrap();
    assert_eq!(absolute.sources, vec![Source::Local(PathBuf::from("/abs/x.m4v"))]);
}

#[test]
fn two_sources_and_every_flag() {
    let two = open(&[
        "before.mp4",
        CLIP,
        "--loop",
        "--rate",
        "0.5",
        "--workspace",
        "current",
        "--pane=pane_1",
        "--name",
        "Compare",
    ])
    .unwrap();
    assert_eq!(two.sources.len(), 2);
    assert!(two.looping);
    assert_eq!(two.rate, 0.5);
    assert_eq!(two.name.as_deref(), Some("Compare"));
    assert_eq!(
        two.place,
        vec![("workspace".into(), "current".into()), ("pane".into(), "pane_1".into())]
    );
    assert!(open(&["a.mp4", "b.mp4", "c.mp4"]).is_err());
    assert!(open(&[]).is_err());
    assert!(open(&["--loop"]).is_err());
}

#[test]
fn rates_are_half_one_and_two() {
    for (word, rate) in
        [("0.5", 0.5), (".5", 0.5), ("0.5x", 0.5), ("1", 1.0), ("1x", 1.0), ("2", 2.0), ("2X", 2.0)]
    {
        assert_eq!(open(&["a.mp4", "--rate", word]).unwrap().rate, rate, "{word}");
    }
    for bad in ["3", "0", "fast", "1.5", ""] {
        assert!(open(&["a.mp4", "--rate", bad]).is_err(), "{bad}");
    }
    assert!(open(&["a.mp4", "--rate"]).is_err());
}

#[test]
fn bad_extensions_schemes_and_options_are_refused() {
    for bad in ["notes.txt", "clip", "https://example.com/watch?v=1", "https://example.com/a.gif"] {
        let error = open(&[bad]).unwrap_err();
        assert!(error.contains(".mp4"), "{bad}: {error}");
    }
    for bad in ["http://example.com/a.mp4", "ftp://example.com/a.mp4", "data://x/a.mp4"] {
        let error = open(&[bad]).unwrap_err();
        assert!(error.contains("not supported"), "{bad}: {error}");
    }
    let credentials = open(&["https://me:secret@example.com/a.mp4"]).unwrap_err();
    assert!(
        credentials.contains("credentials") && !credentials.contains("secret"),
        "{credentials}"
    );
    assert!(open(&["a.mp4", "--engine", "chromium"]).is_err());
    assert!(open(&["a.mp4", "--focus"]).is_err());
    assert!(open(&["a.mp4", "--pane", "p", "--pane", "q"]).is_err());
    // After `--`, a word is a source even when it looks like an option.
    assert_eq!(
        open(&["--", "--odd.mp4"]).unwrap().sources,
        vec![Source::Local(PathBuf::from("/work/--odd.mp4"))]
    );
}

#[test]
fn the_folder_name_is_a_stable_hash_of_the_sources_in_order() {
    let a = folder_name(&["url:https://a.test/x.mp4".into()]);
    assert_eq!(a.len(), 32);
    assert!(is_folder_name(&a));
    assert_eq!(a, folder_name(&["url:https://a.test/x.mp4".into()]));
    let ab = folder_name(&["url:a".into(), "url:b".into()]);
    assert_ne!(ab, folder_name(&["url:b".into(), "url:a".into()]));
    // The separator keeps `ab`+`c` apart from `a`+`bc`.
    assert_ne!(folder_name(&["ab".into(), "c".into()]), folder_name(&["a".into(), "bc".into()]));
    assert!(!is_folder_name("index.html"));
    assert!(!is_folder_name(&a.to_uppercase()));
}

#[test]
fn media_names_and_labels() {
    let web = Source::Web("https://a.test/dir/Clip%20One.MP4".into());
    assert_eq!(web.name(), "Clip One.MP4");
    assert_eq!(media_name(0, &web), "a.mp4");
    assert_eq!(media_name(1, &Source::Local("/x/y.webm".into())), "b.webm");
    let names =
        |values: &[&str]| values.iter().map(|value| (*value).to_owned()).collect::<Vec<_>>();
    assert_eq!(labels(&names(&["before-send.mp4", "after-send.mp4"])), names(&["Before", "After"]));
    assert_eq!(labels(&names(&["AFTER.mov", "Before.mov"])), names(&["After", "Before"]));
    assert_eq!(labels(&names(&["x1.mp4", "x2.mp4"])), names(&["x1.mp4", "x2.mp4"]));
    assert_eq!(labels(&names(&["one.mp4"])), names(&["one.mp4"]));
}

fn config_of(page: &str) -> Value {
    let start = page.find(r#"<script id="config" type="application/json">"#).unwrap();
    let body = &page[start..];
    let body = &body[body.find('>').unwrap() + 1..];
    serde_json::from_str(&body[..body.find("</script>").unwrap()]).unwrap()
}

#[test]
fn the_page_bakes_in_relative_sources_and_escapes_names() {
    let open = open(&["/v/before.mp4", "/v/after.mov", "--loop", "--rate", "2"]).unwrap();
    let page = render(&open);
    assert!(!page.contains("{{"), "a placeholder is left");
    assert!(page.contains("<title>before.mp4 vs after.mov</title>"));
    let config = config_of(&page);
    assert_eq!(config["loop"], true);
    assert_eq!(config["rate"], 2.0);
    assert_eq!(config["sources"][0]["src"], "a.mp4");
    assert_eq!(config["sources"][1]["src"], "b.mov");
    assert_eq!(config["sources"][0]["label"], "Before");
    assert_eq!(config["sources"][1]["name"], "after.mov");
    // No network: the page names no other origin.
    assert!(!page.contains("https://") && !page.contains("http://"));
}

#[test]
fn a_hostile_name_cannot_leave_the_script_or_the_title() {
    // A URL's name is decoded, so it can hold `/` and `<`.
    let hostile = "https://a.test/%3C%2Fscript%3E%3Cscript%3Ealert(1)%3C%2Fscript%3E%7B%7BCONFIG%7D%7D%26%E2%80%A8.mp4";
    let open = Open {
        sources: vec![Source::Web(hostile.into())],
        looping: false,
        rate: 1.0,
        name: Some("<b>{{TITLE}}</b>".into()),
        place: Vec::new(),
    };
    let page = render(&open);
    // The page has exactly its own two closing script tags.
    assert_eq!(page.matches("</script>").count(), 2, "{page}");
    assert!(!page.contains("<script>alert"));
    assert!(page.contains("<title>&lt;b&gt;{{TITLE}}&lt;/b&gt;</title>"));
    let config = config_of(&page);
    assert_eq!(
        config["sources"][0]["name"],
        "</script><script>alert(1)</script>{{CONFIG}}&\u{2028}.mp4"
    );
    assert!(!script_json(&json!("\u{2029}<>&")).contains(['<', '>', '&', '\u{2029}']));
}

#[test]
fn the_tab_is_a_webkit_browser_open_of_the_page() {
    const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
    let open = open(&["/v/a.mp4", "--pane", PANE]).unwrap();
    let url = "file:///cache/cmux/video-view/0123/index.html";
    let words = browser_words(&open, url);
    let plan = match super::super::command::parse(&words, super::super::Surface::Cmux).unwrap() {
        CommandPlan::Protocol(plan) => *plan,
        _ => panic!("browser open made no request"),
    };
    assert_eq!(plan.operation.name().unwrap(), "tab.create_browser");
    assert_eq!(plan.params["url"], url);
    assert_eq!(plan.params["engine"], "webkit");
    assert_eq!(plan.params["name"], "a.mp4");
    assert_eq!(plan.params["pane"], PANE);
    println!("tab.create_browser params: {}", plan.params);
}

#[test]
fn prepare_copies_once_downloads_once_and_reuses_the_folder() {
    let scratch = tempfile::tempdir().unwrap();
    let media = scratch.path().join("before.mp4");
    std::fs::write(&media, b"local bytes").unwrap();
    let root = scratch.path().join("cache");
    let open = Open {
        sources: vec![Source::Local(media), Source::Web("https://a.test/after.mp4".into())],
        looping: true,
        rate: 1.0,
        name: None,
        place: Vec::new(),
    };
    let mut fetched = 0;
    let mut fetch = |url: &str, destination: &Path| -> Result<u64, String> {
        assert_eq!(url, "https://a.test/after.mp4");
        fetched += 1;
        std::fs::write(destination, b"web bytes").map(|()| 9).map_err(|error| error.to_string())
    };
    let first = prepare(&open, &root, &mut fetch).unwrap();
    assert_eq!(first.downloaded, vec![("after.mp4".to_owned(), 9)]);
    let folder = first.index.parent().unwrap().to_path_buf();
    assert_eq!(folder.parent().unwrap(), root);
    assert!(is_folder_name(folder.file_name().unwrap().to_str().unwrap()));
    assert_eq!(std::fs::read(folder.join("a.mp4")).unwrap(), b"local bytes");
    assert_eq!(std::fs::read(folder.join("b.mp4")).unwrap(), b"web bytes");
    assert!(std::fs::read_to_string(&first.index).unwrap().contains("\"a.mp4\""));
    let again = prepare(&open, &root, &mut fetch).unwrap();
    assert_eq!(again.index, first.index);
    assert!(again.downloaded.is_empty());
    assert_eq!(fetched, 1);
    let mut names: Vec<_> =
        std::fs::read_dir(&folder).unwrap().map(|e| e.unwrap().file_name()).collect();
    names.sort();
    assert_eq!(names, ["a.mp4", "b.mp4", "index.html"]);
    // A failed download leaves no partial file and no media.
    let failing = Open { sources: vec![Source::Web("https://a.test/gone.mp4".into())], ..open };
    let mut refuse = |_: &str, destination: &Path| -> Result<u64, String> {
        std::fs::write(destination, b"half").unwrap();
        Err("gone.mp4: the server answered 404".to_owned())
    };
    assert!(prepare(&failing, &root, &mut refuse).is_err());
    let failed = root.join(folder_name(&["url:https://a.test/gone.mp4".into()]));
    assert_eq!(std::fs::read_dir(&failed).unwrap().count(), 0, "a partial file is left");
    let missing = Open { sources: vec![Source::Local(scratch.path().join("none.mp4"))], ..failing };
    assert!(prepare(&missing, &root, &mut refuse).is_err());
}

#[test]
fn prune_keeps_the_newest_folders_and_the_one_just_opened() {
    let scratch = tempfile::tempdir().unwrap();
    let root = scratch.path();
    let base = std::time::SystemTime::now() - Duration::from_secs(1000);
    let mut names = Vec::new();
    for index in 0..5u64 {
        let name = folder_name(&[index.to_string()]);
        let folder = root.join(&name);
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("a.mp4"), vec![0u8; 10]).unwrap();
        std::fs::File::open(&folder)
            .unwrap()
            .set_modified(base + Duration::from_secs(index * 10))
            .unwrap();
        names.push(name);
    }
    std::fs::create_dir(root.join("not-ours")).unwrap();
    // Keep 3: the oldest (names[0]) is the one just opened, so it stays.
    prune(root, &names[0], 3, u64::MAX);
    let left = |name: &str| root.join(name).exists();
    assert!(left(&names[0]) && left(&names[4]) && left(&names[3]));
    assert!(!left(&names[2]) && !left(&names[1]));
    assert!(left("not-ours"));
    // A byte cap of 25 keeps two 10-byte folders: the one opened and the next newest.
    prune(root, &names[4], 10, 25);
    assert!(left(&names[4]) && left(&names[3]) && !left(&names[0]));
}

#[test]
fn the_template_has_each_placeholder_once() {
    let page = include_str!("video_view.html");
    assert_eq!(page.matches("{{TITLE}}").count(), 1);
    assert_eq!(page.matches("{{CONFIG}}").count(), 1);
    assert!(page.find("{{TITLE}}") < page.find("{{CONFIG}}"));
}
