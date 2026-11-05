use std::sync::{Arc, Mutex};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::tests::{
    CREDENTIAL, Ran, command, entry, fake, far, mint_answer, never, no_secret, parsed, platform,
    run_with,
};
use super::super::{AddArgs, Hooks, RunOptions, Verb, bootstrap, run};
use super::policy::Delivery;
use super::*;

const VALUE: &str = "sk-live-vault-value-0123456789";

fn run_vault(words: &[&str], origin: &str, output: OutputMode, value: &str) -> Ran {
    let command = command(words);
    let platform = platform(origin);
    let mut out = Vec::new();
    let mut asked = Vec::new();
    let mut confirm = |question: &str| {
        asked.push(question.to_owned());
        true
    };
    let value = value.to_owned();
    let mut read_value = move |_: &str| -> Result<zeroize::Zeroizing<String>, String> {
        Ok(zeroize::Zeroizing::new(value.clone()))
    };
    let mut ssh = |_: &bootstrap::SshPlan| -> std::io::Result<i32> { panic!("no ssh here") };
    let mut hooks = Hooks { confirm: &mut confirm, read_value: &mut read_value, ssh: &mut ssh };
    let options = RunOptions { interactive: false, every: std::time::Duration::from_millis(20) };
    let code = run(&command, &platform, output, options, &mut out, &mut hooks, never());
    Ran { code, out: String::from_utf8(out).unwrap(), asked }
}

fn no_value(text: &str) {
    no_secret(text);
    let encoded = base64::engine::general_purpose::STANDARD.encode(VALUE);
    assert!(!text.contains(VALUE), "the value leaked in {text:?}");
    assert!(!text.contains(&encoded), "the encoded value leaked in {text:?}");
}

fn vault_of(words: &[&str]) -> VaultVerb {
    match command(words).verb {
        Verb::Vault(verb) => verb,
        other => panic!("{other:?}"),
    }
}

#[test]
fn vault_verbs_parse_and_a_value_never_comes_from_argv() {
    assert_eq!(
        vault_of(&["machine", "vault", "set", "OPENAI_API_KEY"]),
        VaultVerb::Set { name: "OPENAI_API_KEY".into(), policy: None }
    );
    assert_eq!(vault_of(&["machine", "vault", "ls"]), VaultVerb::Ls);
    assert_eq!(
        vault_of(&["machine", "vault", "list", "--platform", "https://p.example"]),
        VaultVerb::Ls
    );
    assert_eq!(
        vault_of(&["machine", "vault", "rm", "GITHUB_TOKEN"]),
        VaultVerb::Rm { name: "GITHUB_TOKEN".into() }
    );
    assert_eq!(
        vault_of(&["machine", "vault", "grant", "mini-9"]),
        VaultVerb::Grant { machine: "mini-9".into(), granted: true }
    );
    assert_eq!(
        vault_of(&["machine", "vault", "revoke", "m_1", "--cloud-token-file", "/t"]),
        VaultVerb::Grant { machine: "m_1".into(), granted: false }
    );
    let error = parsed(&["machine", "vault", "set", "API_KEY", VALUE]).unwrap().unwrap_err();
    assert!(error.0.contains("never the command line"), "{}", error.0);
    assert!(!error.0.contains(VALUE));
    let error = parsed(&["machine", "vault", "set", "API_KEY", "--cloud-token-stdin"])
        .unwrap()
        .unwrap_err();
    assert!(error.0.contains("reads its value from stdin"), "{}", error.0);
    for bad in [
        vec!["machine", "vault"],
        vec!["machine", "vault", "set"],
        vec!["machine", "vault", "set", "PATH"],
        vec!["machine", "vault", "set", "CMUX_TOKEN"],
        vec!["machine", "vault", "set", "1BAD"],
        vec!["machine", "vault", "set", "A-B"],
        vec!["machine", "vault", "logins", "save"],
        vec!["machine", "vault", "ls", "extra"],
        vec!["machine", "vault", "grant"],
        vec!["machine", "vault", "ls", "--bogus"],
    ] {
        assert!(parsed(&bad).is_some_and(|r| r.is_err()), "{bad:?}");
    }
    // The Credential Vault's own noun is not ours.
    assert!(parsed(&["vault", "ls"]).is_none());
}

#[test]
fn set_sends_the_value_base64_with_its_fingerprint_and_never_prints_it() {
    for output in [OutputMode::Human, OutputMode::Json, OutputMode::JsonLines, OutputMode::Quiet] {
        let (origin, requests) = fake(Arc::new(|request: &str| {
            if request.starts_with("PUT /v1/vault/env/OPENAI_API_KEY ") {
                return (200, json!({"name": "OPENAI_API_KEY", "revision": 4}).to_string());
            }
            (404, "{}".to_owned())
        }));
        let ran = run_vault(&["machine", "vault", "set", "OPENAI_API_KEY"], &origin, output, VALUE);
        assert_eq!(ran.code, Ok(0), "{output:?}");
        no_value(&ran.out);
        match output {
            OutputMode::Human => {
                assert_eq!(ran.out, "OPENAI_API_KEY saved to your vault (revision 4).\n");
            }
            OutputMode::Quiet => assert!(ran.out.is_empty()),
            _ => assert_eq!(
                serde_json::from_str::<Value>(ran.out.trim()).unwrap(),
                json!({"name": "OPENAI_API_KEY", "revision": 4})
            ),
        }
        let request = requests.recv().unwrap();
        let (head, body) = request.split_once("\r\n\r\n").unwrap();
        assert!(head.to_ascii_lowercase().contains(&format!("authorization: bearer {CREDENTIAL}")));
        assert!(!head.contains(VALUE), "the value is only in the body");
        let body: Value = serde_json::from_str(body).unwrap();
        let sent = base64::engine::general_purpose::STANDARD
            .decode(body["valueBase64"].as_str().unwrap())
            .unwrap();
        assert_eq!(sent, VALUE.as_bytes());
        assert_eq!(body["fingerprint"], fingerprint(VALUE.as_bytes()));
        assert_eq!(body.as_object().unwrap().len(), 2, "{body}");
    }
}

#[test]
fn set_refuses_an_empty_value_and_errors_never_carry_the_value() {
    let (origin, requests) = fake(Arc::new(|_: &str| (500, "{}".to_owned())));
    let ran = run_vault(&["machine", "vault", "set", "API_KEY"], &origin, OutputMode::Human, "");
    assert_eq!(ran.code.unwrap_err().exit, 2);
    assert!(requests.try_recv().is_err(), "nothing was sent");
    // A server that echoes what it got: none of it reaches the message.
    let echo = Arc::new(|request: &str| {
        (400, json!({"code": "vault.invalid", "message": request}).to_string())
    });
    let (origin, _requests) = fake(echo);
    let failure =
        run_vault(&["machine", "vault", "set", "API_KEY"], &origin, OutputMode::Json, VALUE)
            .code
            .unwrap_err();
    assert_eq!(failure.message, "the cmux platform refused the value: 400 vault.invalid");
    no_value(&failure.message);
}

#[test]
fn ls_prints_names_revisions_and_times_only() {
    let listed = json!({"entries": [
        {"name": "OPENAI_API_KEY", "revision": 3, "updatedAt": "2026-11-02T10:00:00Z", "value": VALUE},
        {"name": "GITHUB_TOKEN", "revision": 1, "updatedAt": "2026-11-01T09:00:00Z", "valueBase64": VALUE},
        {"name": "../bad", "revision": 1},
    ]});
    for output in [OutputMode::Human, OutputMode::Json] {
        let listed = listed.clone();
        let (origin, _requests) = fake(Arc::new(move |request: &str| {
            assert!(request.starts_with("GET /v1/vault/env "), "{request}");
            (200, listed.to_string())
        }));
        let ran = run_vault(&["machine", "vault", "ls"], &origin, output, VALUE);
        assert_eq!(ran.code, Ok(0));
        no_value(&ran.out);
        if output == OutputMode::Human {
            // No `delivery` in the answer: an older hub, which puts the value in the env.
            assert_eq!(
                ran.out,
                "OPENAI_API_KEY  r3  2026-11-02T10:00:00Z  env (weaker: agents can read the value)\nGITHUB_TOKEN  r1  2026-11-01T09:00:00Z  env (weaker: agents can read the value)\n"
            );
        } else {
            let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
            assert_eq!(value["entries"].as_array().unwrap().len(), 2);
            assert_eq!(
                value["entries"][0],
                json!({"name": "OPENAI_API_KEY", "revision": 3, "updatedAt": "2026-11-02T10:00:00Z", "delivery": "env", "allowedHosts": []})
            );
        }
    }
    let (origin, _requests) = fake(Arc::new(|_: &str| (404, "{}".to_owned())));
    let failure =
        run_vault(&["machine", "vault", "ls"], &origin, OutputMode::Human, VALUE).code.unwrap_err();
    assert_eq!(failure.message, "the vault isn't available on this server yet (it answered 404)");
}

#[test]
fn rm_deletes_and_a_missing_name_says_so() {
    let (origin, requests) = fake(Arc::new(|request: &str| {
        if request.starts_with("DELETE /v1/vault/env/API_KEY ") {
            return (200, "{}".to_owned());
        }
        (404, json!({"code": "vault.not_found"}).to_string())
    }));
    let ran = run_vault(&["machine", "vault", "rm", "API_KEY"], &origin, OutputMode::Json, VALUE);
    assert_eq!(ran.code, Ok(0));
    assert_eq!(
        serde_json::from_str::<Value>(ran.out.trim()).unwrap(),
        json!({"name": "API_KEY", "removed": true})
    );
    assert!(requests.recv().unwrap().starts_with("DELETE /v1/vault/env/API_KEY "));
    let failure =
        run_vault(&["machine", "vault", "rm", "OTHER"], &origin, OutputMode::Human, VALUE)
            .code
            .unwrap_err();
    assert_eq!(failure.code, "machine_vault.not_found");
    assert_eq!(failure.message, "your vault has no OTHER");
}

#[test]
fn grant_and_revoke_put_the_machines_vault_flag_by_name() {
    for (verb, granted) in [("grant", true), ("revoke", false)] {
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let seen = Arc::clone(&bodies);
        let (origin, _requests) = fake(Arc::new(move |request: &str| {
            if request.starts_with("GET /v1/machines/credentials ") {
                return (200, json!([entry("jt_1")]).to_string());
            }
            if request.starts_with("PUT /v1/machines/m_1/vault ") {
                seen.lock().unwrap().push(request.split_once("\r\n\r\n").unwrap().1.to_owned());
                return (200, json!({"granted": granted}).to_string());
            }
            (404, "{}".to_owned())
        }));
        let ran =
            run_vault(&["machine", "vault", verb, "lane-vm-3"], &origin, OutputMode::Json, VALUE);
        assert_eq!(ran.code, Ok(0), "{verb}");
        assert_eq!(
            serde_json::from_str::<Value>(ran.out.trim()).unwrap(),
            json!({"machineId": "m_1", "name": "lane-vm-3", "granted": granted})
        );
        let body: Value = serde_json::from_str(&bodies.lock().unwrap()[0]).unwrap();
        assert_eq!(body, json!({"granted": granted}));
    }
}

#[test]
fn the_consent_names_every_env_var_and_no_login() {
    assert_eq!(
        consent_text(&["OPENAI_API_KEY".into(), "GITHUB_TOKEN".into()]),
        "This machine gets 2 env vars from your vault: OPENAI_API_KEY, GITHUB_TOKEN. Continue?"
    );
    assert_eq!(
        consent_text(&["OPENAI_API_KEY".into()]),
        "This machine gets 1 env var from your vault: OPENAI_API_KEY. Continue?"
    );
    assert!(consent_text(&[]).starts_with("This machine gets your vault (it has no env vars yet"));
    for text in [consent_text(&[]), consent_text(&["A_B".into()])] {
        assert!(!text.to_ascii_lowercase().contains("login"), "{text}");
    }
}

/// A platform with a vault of two vars that mints, recording each mint's body.
fn vault_platform(mint_status: u16) -> (String, std::sync::mpsc::Receiver<String>) {
    fake(Arc::new(move |request: &str| {
        if request.starts_with("GET /v1/vault/env ") {
            return (
                200,
                json!({"entries": [{"name": "OPENAI_API_KEY", "revision": 1}, {"name": "GITHUB_TOKEN", "revision": 2}]})
                    .to_string(),
            );
        }
        if request.starts_with("POST /v1/machines/join-tokens ") {
            if mint_status == 403 {
                return (403, json!({"code": "machine.vault_personal_only"}).to_string());
            }
            return (200, mint_answer(far()));
        }
        (404, "{}".to_owned())
    }))
}

#[test]
fn add_vault_asks_with_the_names_then_mints_with_vault_true() {
    let (origin, requests) = vault_platform(200);
    let ran =
        run_with(&["machine", "add", "--vault"], &origin, OutputMode::Json, false, true, never());
    assert_eq!(ran.code, Ok(0));
    assert_eq!(
        ran.asked,
        vec![
            "This machine gets 2 env vars from your vault: OPENAI_API_KEY, GITHUB_TOKEN. Continue?"
        ]
    );
    assert!(requests.recv().unwrap().starts_with("GET /v1/vault/env "));
    let mint = requests.recv().unwrap();
    assert!(mint.starts_with("POST /v1/machines/join-tokens "));
    let body: Value = serde_json::from_str(mint.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body, json!({"vault": true}));
    // A no: no token is made.
    let (origin, requests) = vault_platform(200);
    let ran =
        run_with(&["machine", "add", "--vault"], &origin, OutputMode::Human, false, false, never());
    assert_eq!(ran.code.unwrap_err().exit, 2);
    assert!(requests.recv().unwrap().starts_with("GET /v1/vault/env "));
    assert!(requests.try_recv().is_err(), "nothing minted after a no");
    // --yes asks nothing; --quiet without --yes refuses before any call.
    let (origin, _requests) = vault_platform(200);
    let ran = run_with(
        &["machine", "add", "--vault", "--yes"],
        &origin,
        OutputMode::Json,
        false,
        false,
        never(),
    );
    assert_eq!(ran.code, Ok(0));
    assert!(ran.asked.is_empty());
    let (origin, requests) = vault_platform(200);
    let ran =
        run_with(&["machine", "add", "--vault"], &origin, OutputMode::Quiet, false, true, never());
    assert_eq!(ran.code.unwrap_err().exit, 2);
    assert!(requests.try_recv().is_err());
    // Without --vault, nothing about the vault changes.
    let (origin, requests) = vault_platform(200);
    let ran = run_with(&["machine", "add"], &origin, OutputMode::Json, false, true, never());
    assert_eq!(ran.code, Ok(0));
    assert!(ran.asked.is_empty());
    let mint = requests.recv().unwrap();
    let body: Value = serde_json::from_str(mint.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body, json!({}));
}

#[test]
fn add_vault_on_a_team_says_the_vault_is_personal_only() {
    let (origin, _requests) = vault_platform(403);
    let failure = run_with(
        &["machine", "add", "--vault", "--yes"],
        &origin,
        OutputMode::Json,
        false,
        true,
        never(),
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_join.vault_personal_only");
    no_secret(&failure.message);
}

#[test]
fn add_flags_parse_together_and_refuse_what_does_not_fit() {
    assert_eq!(
        command(&["machine", "add", "--vault", "-y"]).verb,
        Verb::Add(AddArgs { vault: true, yes: true, ..AddArgs::default() })
    );
    assert_eq!(
        command(&["machine", "add", "leo@mini-9", "--bootstrap"]).verb,
        Verb::Add(AddArgs {
            host: Some("leo@mini-9".into()),
            bootstrap: true,
            ..AddArgs::default()
        })
    );
    assert_eq!(
        command(&["machine", "add", "--vault", "--destination", "mini-9"]).verb,
        Verb::Add(AddArgs { host: Some("mini-9".into()), vault: true, ..AddArgs::default() })
    );
    assert_eq!(
        command(&["machine", "add", "--usb", "/Volumes/STICK", "--ttl", "5m"]).verb,
        Verb::Add(AddArgs {
            usb: Some("/Volumes/STICK".into()),
            ttl: Some(300),
            ..AddArgs::default()
        })
    );
    // Without --vault or --bootstrap a host is still the app's card.
    assert!(parsed(&["machine", "add", "leo@mini-9"]).is_none());
    for bad in [
        vec!["machine", "add", "--yes"],
        vec!["machine", "add", "--bootstrap"],
        vec!["machine", "add", "--usb", "/x", "leo@mini-9", "--vault"],
        vec!["machine", "add", "--usb", "/x", "--ttl", "25h"],
        vec!["machine", "add", "--usb", "/x", "--ttl", "1h"],
        vec!["machine", "add", "--usb", "/x", "--wait"],
        vec!["machine", "add", "--usb"],
        vec!["machine", "add", "--ttl", "1h"],
        vec!["machine", "add", "-oProxyCommand=x", "--vault"],
        vec!["machine", "add", "--destination", "-oProxyCommand=x", "--vault"],
        vec!["machine", "add", "a b", "--bootstrap"],
    ] {
        assert!(parsed(&bad).is_some_and(|r| r.is_err()), "{bad:?}");
    }
}

#[test]
fn an_empty_usb_or_destination_is_refused_before_anything_runs() {
    for bad in [
        vec!["machine", "add", "--usb", ""],
        vec!["machine", "add", "--usb="],
        vec!["machine", "add", "--vault", "--usb="],
        vec!["machine", "add", "--vault", "--destination="],
    ] {
        let error = parsed(&bad).expect("ours").unwrap_err();
        assert!(error.0.ends_with("needs a value"), "{bad:?}: {}", error.0);
    }
    // Refused at parse: `run_if_requested` fails before reading a credential, so nothing is
    // minted and no line is printed.
}

#[test]
fn machine_adds_switches_leave_json_to_the_global_output_mode() {
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<String>>();
    for args in [
        vec!["machine", "add", "leo@mini-9", "--bootstrap", "--json"],
        vec!["machine", "add", "--vault", "--json", "--yes"],
        vec!["machine", "add", "--vault", "--yes", "--json"],
        vec!["machine", "add", "--wait", "--json"],
        vec!["machine", "vault", "ls", "--cloud-token-stdin", "--json"],
    ] {
        let (global, rest) = match crate::cli::parse_globals(&words(&args)) {
            Ok(parsed) => parsed,
            Err((error, _)) => panic!("{args:?}: {}", error.0),
        };
        assert_eq!(global.output, OutputMode::Json, "{args:?}");
        assert!(!rest.contains(&"--json".to_owned()), "{args:?}: {rest:?}");
        assert!(
            parsed(&rest.iter().map(String::as_str).collect::<Vec<_>>()).is_some_and(|r| r.is_ok()),
            "{rest:?}"
        );
    }
    // Elsewhere `--bootstrap` keeps its value (`cloud new-machine --bootstrap NAME`).
    let (_, rest) =
        match crate::cli::parse_globals(&words(&["cloud", "new-machine", "--bootstrap", "--json"]))
        {
            Ok(parsed) => parsed,
            Err((error, _)) => panic!("{}", error.0),
        };
    assert_eq!(rest, words(&["cloud", "new-machine", "--bootstrap", "--json"]));
}

fn policy_of(hosts: &[&str]) -> Option<Policy> {
    Some(Policy {
        delivery: Delivery::Proxy,
        allowed_hosts: hosts.iter().map(|h| (*h).to_owned()).collect(),
    })
}

#[test]
fn policy_flags_parse_and_refuse_what_does_not_fit() {
    assert_eq!(
        vault_of(&[
            "machine",
            "vault",
            "set",
            "GITHUB_TOKEN",
            "--host",
            "api.github.com",
            "--host=GitHub.com",
            "--host",
            "api.github.com",
        ]),
        VaultVerb::Set {
            name: "GITHUB_TOKEN".into(),
            policy: policy_of(&["api.github.com", "github.com"])
        }
    );
    assert_eq!(
        vault_of(&["machine", "vault", "set", "API_KEY", "--env"]),
        VaultVerb::Set {
            name: "API_KEY".into(),
            policy: Some(Policy { delivery: Delivery::Env, allowed_hosts: vec![] })
        }
    );
    assert_eq!(
        vault_of(&["machine", "vault", "policy", "API_KEY", "--no-hosts"]),
        VaultVerb::Policy { name: "API_KEY".into(), policy: policy_of(&[]).unwrap() }
    );
    assert_eq!(
        vault_of(&["machine", "vault", "policy", "API_KEY", "--host", "*.example.com:8443"]),
        VaultVerb::Policy {
            name: "API_KEY".into(),
            policy: policy_of(&["*.example.com:8443"]).unwrap()
        }
    );
    let error = parsed(&["machine", "vault", "set", "API_KEY", "--env", "--host", "a.example"])
        .unwrap()
        .unwrap_err();
    assert!(error.0.contains("not both"), "{}", error.0);
    let many: Vec<String> = (0..17).map(|i| format!("h{i}.example.com")).collect();
    let mut words = vec!["machine", "vault", "policy", "API_KEY"];
    for host in &many {
        words.extend(["--host", host.as_str()]);
    }
    assert!(parsed(&words).unwrap().unwrap_err().0.contains("at most 16"));
    for bad in [
        vec!["machine", "vault", "policy", "API_KEY"],
        vec!["machine", "vault", "policy", "API_KEY", "--env", "--no-hosts"],
        vec!["machine", "vault", "policy", "API_KEY", "--host", "a.example", "--no-hosts"],
        vec!["machine", "vault", "policy", "API_KEY", "--host"],
        vec!["machine", "vault", "policy", "API_KEY", "--env=1"],
        vec!["machine", "vault", "ls", "--host", "a.example"],
        vec!["machine", "vault", "rm", "API_KEY", "--env"],
        vec!["machine", "vault", "policy", "PATH", "--env"],
    ] {
        assert!(parsed(&bad).is_some_and(|r| r.is_err()), "{bad:?}");
    }
    for host in [
        "https://api.github.com",
        "api.github.com/v3",
        "user@api.github.com",
        "1.2.3.4",
        "api.github.com.",
        "example.com:0",
        "example.com:65536",
        "*example.com",
        "a.*.example.com",
        "localhost",
        "",
    ] {
        let error =
            parsed(&["machine", "vault", "set", "API_KEY", "--host", host]).unwrap().unwrap_err();
        assert!(error.0.contains("is not a host"), "{host}: {}", error.0);
    }
    assert!(policy::host_ok("example.com:65535"));
}

/// The platform's allowed-host pattern, which `host_pattern_ok` checks by hand.
const HOST_PATTERN: &str =
    r"^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}(:[1-9][0-9]{0,4})?$";

#[test]
fn the_host_check_accepts_what_the_platform_pattern_accepts() {
    let pattern = regex::Regex::new(HOST_PATTERN).unwrap();
    let same = |host: &str| {
        assert_eq!(policy::host_pattern_ok(host), pattern.is_match(host), "{host:?}");
    };
    let label63 = "a".repeat(63);
    let label64 = "a".repeat(64);
    for host in [
        "api.github.com",
        "*.example.com:8443",
        "a.b",
        "0.a",
        "a-b.c",
        "a.b-",
        "a.b-c9",
        "-a.b",
        "a-.b",
        "a.-b",
        "a.0b",
        "a.b:1",
        "a.b:0",
        "a.b:01",
        "a.b:99999",
        "a.b:999999",
        "a.b:",
        "a.b:1:2",
        "a.b:1a",
        "a..b",
        ".a.b",
        "a.b.",
        "*.a",
        "*.*.a.b",
        "**.a.b",
        "*a.b",
        "A.b",
        "a.B",
        "a.b\n",
        "\na.b",
        "a.b c",
        "é.com",
        "a.côm",
        "a.b:１",
    ] {
        same(host);
    }
    for host in [
        format!("{label63}.{label63}"),
        format!("{label64}.a"),
        format!("a.{label64}"),
        format!("*.{label63}.{label63}:65535"),
    ] {
        same(&host);
    }
    // Every host up to six characters from the pattern's alphabet.
    let alphabet = ['a', '0', '1', '-', '.', '*', ':', 'Z'];
    let mut hosts = vec![String::new()];
    for _ in 0..6 {
        hosts = hosts
            .iter()
            .flat_map(|host| {
                alphabet.iter().map(move |c| {
                    let mut longer = host.clone();
                    longer.push(*c);
                    longer
                })
            })
            .collect();
        for host in &hosts {
            same(host);
        }
    }
}

/// The body of the first request, as JSON.
fn body_of(request: &str) -> Value {
    serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap()
}

#[test]
fn set_with_hosts_sends_the_policy_and_set_without_flags_sends_none() {
    let answer = |request: &str| {
        if request.starts_with("PUT /v1/vault/env/GITHUB_TOKEN ") {
            return (200, json!({"name": "GITHUB_TOKEN", "revision": 2}).to_string());
        }
        (404, "{}".to_owned())
    };
    let (origin, requests) = fake(Arc::new(answer));
    let ran = run_vault(
        &[
            "machine",
            "vault",
            "set",
            "GITHUB_TOKEN",
            "--host",
            "api.github.com",
            "--host",
            "github.com",
        ],
        &origin,
        OutputMode::Human,
        VALUE,
    );
    assert_eq!(ran.code, Ok(0));
    no_value(&ran.out);
    assert_eq!(
        ran.out,
        "GITHUB_TOKEN saved to your vault (revision 2).\nDelivery: proxy: api.github.com, github.com\n"
    );
    let body = body_of(&requests.recv().unwrap());
    assert_eq!(body["delivery"], "proxy");
    assert_eq!(body["allowedHosts"], json!(["api.github.com", "github.com"]));
    assert_eq!(body["fingerprint"], fingerprint(VALUE.as_bytes()));
    assert_eq!(body.as_object().unwrap().len(), 4, "{body}");

    let (origin, requests) = fake(Arc::new(answer));
    let ran = run_vault(
        &["machine", "vault", "set", "GITHUB_TOKEN", "--env"],
        &origin,
        OutputMode::Json,
        VALUE,
    );
    assert_eq!(ran.code, Ok(0));
    assert_eq!(
        serde_json::from_str::<Value>(ran.out.trim()).unwrap(),
        json!({"name": "GITHUB_TOKEN", "revision": 2, "delivery": "env", "allowedHosts": []})
    );
    let body = body_of(&requests.recv().unwrap());
    assert_eq!(body["delivery"], "env");

    // No flag: no policy fields, so the platform keeps (or defaults) the entry's policy.
    let (origin, requests) = fake(Arc::new(answer));
    let ran =
        run_vault(&["machine", "vault", "set", "GITHUB_TOKEN"], &origin, OutputMode::Human, VALUE);
    assert_eq!(ran.code, Ok(0));
    assert_eq!(ran.out, "GITHUB_TOKEN saved to your vault (revision 2).\n");
    let body = body_of(&requests.recv().unwrap());
    assert!(body.get("delivery").is_none() && body.get("allowedHosts").is_none(), "{body}");
}

#[test]
fn policy_puts_the_policy_path_and_never_sends_a_value() {
    for (words, sent, human) in [
        (
            vec!["machine", "vault", "policy", "API_KEY", "--host", "api.example.com"],
            json!({"delivery": "proxy", "allowedHosts": ["api.example.com"]}),
            "API_KEY: proxy: api.example.com\n",
        ),
        (
            vec!["machine", "vault", "policy", "API_KEY", "--no-hosts"],
            json!({"delivery": "proxy", "allowedHosts": []}),
            "API_KEY: proxy: no hosts (placeholder only)\n",
        ),
        (
            vec!["machine", "vault", "policy", "API_KEY", "--env"],
            json!({"delivery": "env", "allowedHosts": []}),
            "API_KEY: env (weaker: agents can read the value)\n",
        ),
    ] {
        let (origin, requests) = fake(Arc::new(|request: &str| {
            if request.starts_with("PUT /v1/vault/env/API_KEY/policy ") {
                let mut answer = body_of(request);
                answer["name"] = json!("API_KEY");
                answer["revision"] = json!(7);
                return (200, answer.to_string());
            }
            (404, "{}".to_owned())
        }));
        let ran = run_vault(&words, &origin, OutputMode::Human, VALUE);
        assert_eq!(ran.code, Ok(0), "{words:?}");
        assert_eq!(ran.out, human);
        let request = requests.recv().unwrap();
        assert!(request.starts_with("PUT /v1/vault/env/API_KEY/policy "), "{request}");
        assert!(!request.contains(VALUE), "the policy call never carries a value");
        assert_eq!(body_of(&request), sent);

        let (origin, _requests) = fake(Arc::new(|request: &str| {
            let mut answer = body_of(request);
            answer["name"] = json!("API_KEY");
            answer["revision"] = json!(7);
            (200, answer.to_string())
        }));
        let ran = run_vault(&words, &origin, OutputMode::Json, VALUE);
        let mut expected = sent.clone();
        expected["name"] = json!("API_KEY");
        expected["revision"] = json!(7);
        assert_eq!(serde_json::from_str::<Value>(ran.out.trim()).unwrap(), expected);
    }
    for (code, failure) in [
        ("vault.no_entry", "machine_vault.not_found"),
        ("vault.invalid_hosts", "machine_vault.invalid_hosts"),
    ] {
        let (origin, _requests) =
            fake(Arc::new(move |_: &str| (400, json!({"code": code}).to_string())));
        let ran = run_vault(
            &["machine", "vault", "policy", "API_KEY", "--env"],
            &origin,
            OutputMode::Human,
            VALUE,
        );
        assert_eq!(ran.code.unwrap_err().code, failure);
    }
    // `set --host` gets the same message for hosts the platform refuses.
    let (origin, _requests) =
        fake(Arc::new(|_: &str| (400, json!({"code": "vault.invalid_hosts"}).to_string())));
    let failure = run_vault(
        &["machine", "vault", "set", "API_KEY", "--host", "a.example.com"],
        &origin,
        OutputMode::Human,
        VALUE,
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_vault.invalid_hosts");
    no_value(&failure.message);
}

#[test]
fn ls_renders_each_delivery_and_json_carries_the_policy() {
    let listed = json!({"entries": [
        {"name": "GITHUB_TOKEN", "revision": 1, "delivery": "proxy", "allowedHosts": ["api.github.com", "github.com"]},
        {"name": "OTHER_KEY", "revision": 2, "delivery": "proxy", "allowedHosts": []},
        {"name": "LEGACY_KEY", "revision": 3, "delivery": "env", "allowedHosts": ["kept.example.com"]},
        {"name": "ODD_KEY", "revision": 4, "delivery": "proxy", "allowedHosts": ["https://evil/x", VALUE, "ok.example.com"]},
    ]});
    let (origin, _requests) = {
        let listed = listed.clone();
        fake(Arc::new(move |_: &str| (200, listed.to_string())))
    };
    let ran = run_vault(&["machine", "vault", "ls"], &origin, OutputMode::Human, VALUE);
    assert_eq!(ran.code, Ok(0));
    no_value(&ran.out);
    assert_eq!(
        ran.out,
        "GITHUB_TOKEN  r1  proxy: api.github.com, github.com\n\
         OTHER_KEY  r2  proxy: no hosts (placeholder only)\n\
         LEGACY_KEY  r3  env (weaker: agents can read the value)\n\
         ODD_KEY  r4  proxy: ok.example.com\n"
    );
    let (origin, _requests) = fake(Arc::new(move |_: &str| (200, listed.to_string())));
    let ran = run_vault(&["machine", "vault", "ls"], &origin, OutputMode::Json, VALUE);
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    assert_eq!(value["entries"][0]["delivery"], "proxy");
    assert_eq!(value["entries"][0]["allowedHosts"], json!(["api.github.com", "github.com"]));
    assert_eq!(value["entries"][1]["allowedHosts"], json!([]));
    assert_eq!(value["entries"][2]["delivery"], "env");
    assert_eq!(value["entries"][2]["allowedHosts"], json!(["kept.example.com"]));
    assert_eq!(value["entries"][3]["allowedHosts"], json!(["ok.example.com"]));
}
