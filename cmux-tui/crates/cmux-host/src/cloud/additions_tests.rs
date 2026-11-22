use std::cell::Cell;
use std::sync::{Arc, Mutex};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::additions::{
    ADDITIONS_PATH, CONSENT_PATH, IdleEdge, MAX_KEYS, MIN_GAP_MS, Outcome, Sent, collect_command,
    keys, run_once, valid_key,
};
use super::client::{CloudClient, Http};
use super::wire::{Bound, Env};

/// Each platform request: method, url, body, bearer.
type Seen = Vec<(String, String, Option<Value>, Option<String>)>;

#[derive(Clone)]
struct Fake {
    seen: Arc<Mutex<Seen>>,
    consent: (u16, Value),
    put: (u16, Value),
}

impl Fake {
    fn new(consent: (u16, Value)) -> Fake {
        Fake { seen: Arc::default(), consent, put: (200, json!({"additions": [], "updatedAt": 1})) }
    }
    fn seen(&self) -> Seen {
        self.seen.lock().unwrap().clone()
    }
}

impl Http for Fake {
    fn post(&self, url: &str, _: &Value, _: Option<&str>) -> Result<(u16, Value), String> {
        if url.ends_with("/v1/auth/challenge") {
            return Ok((
                200,
                json!({"install":"inst-vm", "nonce":"n", "message_prefix":"cmux-auth-v1\ndevelopment\ninst-vm\n"}),
            ));
        }
        Ok((
            200,
            json!({"access_token":"bearer-1","token_type":"Bearer","expires_at":600_000,
                "user":"user-test","install":"inst-vm","grant":"grant-test","team":"team-a"}),
        ))
    }
    fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.seen.lock().unwrap().push(("GET".into(), url.into(), None, bearer.map(Into::into)));
        Ok(self.consent.clone())
    }
    fn send(
        &self,
        method: &str,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        _: &[(&str, &str)],
    ) -> Result<(u16, Value), String> {
        self.seen.lock().unwrap().push((
            method.into(),
            url.into(),
            body.cloned(),
            bearer.map(Into::into),
        ));
        Ok(self.put.clone())
    }
}

fn client(fake: &Fake) -> CloudClient<Fake> {
    CloudClient::new(
        fake.clone(),
        Bound {
            machine: "vm-test".to_owned(),
            team: "team-a".to_owned(),
            host: "host-test".to_owned(),
            epoch: 1,
            install: "inst-vm".to_owned(),
            user: "user-test".to_owned(),
            grant: "grant-test".to_owned(),
            env: Env::Dev,
            api_origin: Env::Dev.api_origin().to_owned(),
            keyset: Value::Null,
            bound_at: 0,
        },
        InstallKey::generate(&SystemRandom::new()).unwrap(),
    )
}

const LINES: &str = "npm typescript\napt ripgrep\nnpm @scope/pkg\ncargo a/b/c\napt ripgrep\n";

#[test]
fn consent_off_or_surface_off_sends_nothing_and_collects_nothing() {
    for consent in [
        (200, json!({"share": false})),
        (200, json!({})),
        (404, json!({"code": "install_counts.not_found"})),
        (403, json!({"code": "install_counts.forbidden"})),
    ] {
        let fake = Fake::new(consent);
        let collected = Cell::new(false);
        let outcome = run_once(
            &mut client(&fake),
            || {
                collected.set(true);
                Some(LINES.to_owned())
            },
            &mut Sent::default(),
            1,
        );
        assert_eq!(outcome, Outcome::NotShared);
        assert!(!collected.get(), "consent off must not run the collection");
        let seen = fake.seen();
        assert_eq!(seen.len(), 1, "only the consent read");
        assert_eq!(seen[0].0, "GET");
        assert_eq!(seen[0].1, format!("{}{CONSENT_PATH}", Env::Dev.platform_origin()));
    }
}

#[test]
fn consent_on_sends_one_put_with_the_whole_checked_list_then_never_resends_it_unchanged() {
    let fake = Fake::new((200, json!({"share": true})));
    let mut client = client(&fake);
    let mut sent = Sent::default();
    assert_eq!(run_once(&mut client, || Some(LINES.to_owned()), &mut sent, 1), Outcome::Sent(2));
    let seen = fake.seen();
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[1].0, "PUT");
    assert_eq!(seen[1].1, format!("{}{ADDITIONS_PATH}", Env::Dev.platform_origin()));
    assert_eq!(seen[1].2, Some(json!({"additions": ["apt:ripgrep", "npm:typescript"]})));
    assert_eq!(seen[1].3.as_deref(), Some("bearer-1"));

    // Unchanged: the consent is read again, nothing is sent.
    assert_eq!(run_once(&mut client, || Some(LINES.to_owned()), &mut sent, 2), Outcome::Unchanged);
    let seen = fake.seen();
    assert_eq!(seen.len(), 3);
    assert_eq!(seen[2].0, "GET");

    // Changed: the whole new list.
    let more = format!("{LINES}uv ruff\n");
    assert_eq!(run_once(&mut client, || Some(more), &mut sent, 3), Outcome::Sent(3));
    assert_eq!(
        fake.seen()[4].2,
        Some(json!({"additions": ["apt:ripgrep", "npm:typescript", "uv:ruff"]}))
    );
}

#[test]
fn no_baseline_sends_nothing_and_a_refused_send_is_tried_again() {
    let fake = Fake::new((200, json!({"share": true})));
    let mut sent = Sent::default();
    assert_eq!(run_once(&mut client(&fake), || None, &mut sent, 1), Outcome::NotCollected);
    assert_eq!(fake.seen().len(), 1);

    let mut refused = Fake::new((200, json!({"share": true})));
    refused.put = (500, json!({"code": "install_counts.unavailable"}));
    let mut c = client(&refused);
    assert!(matches!(
        run_once(&mut c, || Some(LINES.to_owned()), &mut sent, 1),
        Outcome::Refused(_)
    ));
    // Not recorded as sent: the next idle period sends again.
    assert!(matches!(
        run_once(&mut c, || Some(LINES.to_owned()), &mut sent, 2),
        Outcome::Refused(_)
    ));
    assert_eq!(refused.seen().iter().filter(|s| s.0 == "PUT").count(), 2);

    let mut withdrawn = Fake::new((200, json!({"share": true})));
    withdrawn.put = (403, json!({"code": "install_counts.not_shared"}));
    let outcome = run_once(&mut client(&withdrawn), || Some(LINES.to_owned()), &mut sent, 1);
    assert_eq!(outcome, Outcome::NotShared);
}

#[test]
fn keys_follow_the_platform_rule() {
    assert!(valid_key("apt:ripgrep"));
    assert!(valid_key("npm:a/b"));
    assert!(!valid_key("npm:@scope/pkg"));
    assert!(!valid_key("cargo:a/b/c"));
    assert!(!valid_key(""));
    assert!(!valid_key(&format!("apt:{}", "x".repeat(61))));
    assert!(valid_key(&format!("apt:{}", "x".repeat(60))));
    assert_eq!(keys("apt  \nbad\napt lib.so-1\n"), vec!["apt:lib.so-1"]);
    let many: String = (0..600).map(|i| format!("apt p{i:04}\n")).collect();
    let list = keys(&many);
    assert_eq!(list.len(), MAX_KEYS);
    assert_eq!(list[0], "apt:p0000");
}

#[test]
fn the_collection_is_the_image_layers_shell() {
    let command = collect_command("/home/cmux", "/etc/cmux/image-packages.txt");
    assert_eq!(
        command,
        "{ dpkg-query -W -f='apt ${Package}\\n'; \
         npm ls -g --depth=0 --parseable 2>/dev/null | sed -n 's#.*/node_modules/#npm #p'; \
         ls /home/cmux/.bun/install/global/node_modules 2>/dev/null | sed 's#^#bun #'; \
         ls /home/cmux/.local/share/uv/tools 2>/dev/null | sed 's#^#uv #'; \
         ls /home/cmux/.local/pipx/venvs 2>/dev/null | sed 's#^#pipx #'; \
         ls /home/cmux/.cargo/bin 2>/dev/null | sed 's#^#cargo #'; } \
         | LC_ALL=C sort -u | LC_ALL=C comm -13 /etc/cmux/image-packages.txt -"
    );
}

#[test]
fn one_run_per_idle_period_at_most_once_per_gap() {
    let mut edge = IdleEdge::default();
    assert!(!edge.observe(false, 0));
    assert!(edge.observe(true, 1_000));
    assert!(!edge.observe(true, 31_000), "once per idle period");
    assert!(!edge.observe(false, 61_000));
    assert!(!edge.observe(true, 91_000), "a new period inside the gap waits");
    assert!(edge.observe(true, 1_000 + MIN_GAP_MS), "then fires once the gap passed");
    assert!(!edge.observe(true, 2_000 + MIN_GAP_MS));
}

#[cfg(target_os = "linux")]
#[test]
fn no_baseline_on_the_machine_collects_nothing() {
    let root = tempfile::tempdir().unwrap();
    let paths = crate::config::Paths::new(root.path());
    let out = super::additions::collect_on_machine(
        &paths,
        "/nonexistent",
        std::time::Duration::from_secs(5),
    );
    assert_eq!(out, None);
}

#[cfg(target_os = "linux")]
#[test]
fn the_machine_collection_prints_kind_name_lines_missing_from_the_baseline() {
    let root = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".cargo/bin")).unwrap();
    for bin in ["kept-tool", "new-tool"] {
        std::fs::write(home.path().join(".cargo/bin").join(bin), "").unwrap();
    }
    let etc = root.path().join("etc/cmux");
    std::fs::create_dir_all(&etc).unwrap();
    std::fs::write(etc.join("image-packages.txt"), "cargo kept-tool\n").unwrap();
    let paths = crate::config::Paths::new(root.path());
    let home = home.path().to_str().unwrap();
    let out =
        super::additions::collect_on_machine(&paths, home, std::time::Duration::from_secs(60))
            .expect("the shell runs");
    let lines: Vec<&str> = out.lines().collect();
    assert!(lines.contains(&"cargo new-tool"), "{lines:?}");
    assert!(!lines.contains(&"cargo kept-tool"), "the baseline's names are not additions");
}
