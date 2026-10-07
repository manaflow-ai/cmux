//! The shared case files (`tests/cases/*.json`) against this crate. The Swift
//! host runs the same files against AcpmuxPaneMethods.swift
//! (CmuxNextAgentPaneTests/AgentPanePolicyParityTests.swift), so a case that
//! passes here and fails there is a difference between the two hosts.

use cmux_agent_pane_policy::environment::{default_socket_path, resolve, tag_slug};
use cmux_agent_pane_policy::gesture::{PermissionOptions, needs_gesture};
use cmux_agent_pane_policy::params::{
    breaks_params_rule, requested_setting, session_refusal, stripping_prompt_meta,
    take_gesture_ticket,
};
use cmux_agent_pane_policy::reply::filtered_reply;
use cmux_agent_pane_policy::{Decision, connection, decide, policy};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

fn cases(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases").join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

fn object(v: &Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap()
}

fn name(c: &Value) -> &str {
    c["name"].as_str().unwrap()
}

#[test]
fn frames() {
    let all = cases("frames.json");
    for c in all.as_array().unwrap() {
        let text = c["text"].as_str().unwrap();
        let got = decide(text, c["first"].as_bool().unwrap(), c["token"].as_str());
        let expect = &c["expect"];
        match (&got, expect.get("send"), expect.get("refuse")) {
            (Decision::Send(sent), Some(Value::String(s)), _) if s == "unchanged" => {
                assert_eq!(sent, text, "{}", name(c));
            }
            (Decision::Send(sent), Some(want), _) => {
                assert_eq!(&serde_json::from_str::<Value>(sent).unwrap(), want, "{}", name(c));
            }
            (Decision::Refuse { refusal, method, request_id }, None, Some(code)) => {
                assert_eq!(refusal.code(), code.as_str().unwrap(), "{}", name(c));
                assert_eq!(method.as_deref(), expect["method"].as_str(), "{} method", name(c));
                assert_eq!(request_id.as_deref(), expect["id"].as_str(), "{} id", name(c));
            }
            _ => panic!("{}: got {got:?}, expected {expect}", name(c)),
        }
    }
}

#[test]
fn params_rule() {
    for c in cases("params.json").as_array().unwrap() {
        let modes: Option<BTreeSet<String>> = c["mode_fields"]
            .as_array()
            .map(|a| a.iter().map(|v| v.as_str().unwrap().to_owned()).collect());
        let got = breaks_params_rule(&object(&c["frame"]), modes.as_ref());
        assert_eq!(got, c["breaks"].as_bool().unwrap(), "{}", name(c));
    }
}

#[test]
fn gestures() {
    for c in cases("gestures.json").as_array().unwrap() {
        let denies: BTreeSet<(String, String)> = c["denies"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| (d[0].as_str().unwrap().to_owned(), d[1].as_str().unwrap().to_owned()))
            .collect();
        let got = needs_gesture(&object(&c["frame"]), |p, o| {
            denies.contains(&(p.to_owned(), o.to_owned()))
        });
        assert_eq!(got, c["needs"].as_bool().unwrap(), "{}", name(c));
    }
}

#[test]
fn permission_options() {
    for c in cases("options.json").as_array().unwrap() {
        let options = PermissionOptions::new();
        for f in c["frames"].as_array().unwrap() {
            options.observe(&object(&f["frame"]), f["reply_to"].as_str());
        }
        for check in c["checks"].as_array().unwrap() {
            let (p, o, deny) = (
                check[0].as_str().unwrap(),
                check[1].as_str().unwrap(),
                check[2].as_bool().unwrap(),
            );
            assert_eq!(options.is_deny(p, o), deny, "{} {p}/{o}", name(c));
        }
    }
}

#[test]
fn replies() {
    for c in cases("replies.json").as_array().unwrap() {
        let shape = &policy().reply_shapes[c["method"].as_str().unwrap()];
        let got = filtered_reply(&object(&c["reply"]), shape, c["page_id"].as_str().unwrap());
        assert_eq!(serde_json::from_str::<Value>(&got).unwrap(), c["expected"], "{}", name(c));
    }
}

#[test]
fn tickets_prompt_meta_and_settings() {
    for c in cases("tickets.json").as_array().unwrap() {
        let frame = object(&c["frame"]);
        let taken = take_gesture_ticket(&frame);
        assert_eq!(taken.ticket.as_deref(), c["ticket"].as_str(), "{} ticket", name(c));
        assert_eq!(taken.other_meta, c["other_meta"].as_bool().unwrap(), "{} other meta", name(c));
        assert_eq!(Value::Object(taken.object), c["without_ticket"], "{} without ticket", name(c));
        assert_eq!(
            stripping_prompt_meta(&frame).map(Value::Object),
            c["prompt_stripped"].as_object().cloned().map(Value::Object),
            "{} prompt",
            name(c)
        );
        let setting = requested_setting(&frame);
        match c["setting"].as_object() {
            None => assert!(setting.is_none(), "{} setting", name(c)),
            Some(want) => {
                let s = setting.unwrap();
                assert_eq!(
                    s.session_id.as_deref(),
                    want["session_id"].as_str(),
                    "{} session",
                    name(c)
                );
                assert_eq!(s.config_id, want["config_id"].as_str().unwrap(), "{} config", name(c));
                assert_eq!(s.value.as_deref(), want["value"].as_str(), "{} value", name(c));
            }
        }
    }
}

#[test]
fn session_scope() {
    for c in cases("sessions.json").as_array().unwrap() {
        let sessions: BTreeSet<&str> =
            c["sessions"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
        let refused = session_refusal(&object(&c["frame"]), |s| sessions.contains(s));
        assert_eq!(refused.is_some(), c["refused"].as_bool().unwrap(), "{}", name(c));
        if let Some(r) = refused {
            assert_eq!(
                (r.refusal.code(), r.request_id.as_deref()),
                ("transport.session_not_in_pane", Some("4")),
                "{}",
                name(c)
            );
        }
    }
}

#[test]
fn environment_tokens_and_sockets() {
    let e = cases("environment.json");
    for t in e["tag_slugs"].as_array().unwrap() {
        assert_eq!(tag_slug(t[0].as_str().unwrap()).as_deref(), t[1].as_str(), "tag {}", t[0]);
    }
    for t in e["tokens"].as_array().unwrap() {
        assert_eq!(
            connection::parse_local_app_token(t[0].as_str().unwrap().as_bytes()).as_deref(),
            t[1].as_str(),
            "token {}",
            t[0]
        );
    }
    for s in e["sockets"].as_array().unwrap() {
        let got =
            default_socket_path(Path::new(s[0].as_str().unwrap()), s[1].as_u64().unwrap() as u32);
        assert_eq!(got, s[2].as_str().unwrap(), "socket {}", s[0]);
    }
    for r in e["resolve"].as_array().unwrap() {
        let env: BTreeMap<String, String> = r["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned()))
            .collect();
        let exes: BTreeSet<PathBuf> = r["executables"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| PathBuf::from(p.as_str().unwrap()))
            .collect();
        let got = resolve(
            r["tag"].as_str(),
            r["bundled"].as_str().map(Path::new),
            &env,
            Path::new(r["user_home"].as_str().unwrap()),
            r["uid"].as_u64().unwrap() as u32,
            |p| exes.contains(p),
        );
        match r["expect"].as_object() {
            None => assert!(got.is_none(), "{}", name(r)),
            Some(want) => {
                let got = got.unwrap();
                assert_eq!(
                    got.executable,
                    PathBuf::from(want["executable"].as_str().unwrap()),
                    "{}",
                    name(r)
                );
                assert_eq!(got.home, PathBuf::from(want["home"].as_str().unwrap()), "{}", name(r));
                assert_eq!(got.socket_path, want["socket"].as_str().unwrap(), "{}", name(r));
                let args: Vec<&str> =
                    want["args"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()).collect();
                assert_eq!(got.daemon_arguments, args, "{}", name(r));
                assert_eq!(got.child_environment["ACPMUX_SOCKET"], got.socket_path, "{}", name(r));
            }
        }
    }
}

#[test]
fn origin_bearer_and_refusal_frame() {
    assert_eq!(connection::pane_origin(), "cmux-agent://pane");
    assert_eq!(connection::authorization("t"), "Bearer t");
    assert_eq!(
        connection::local_app_token_path(Path::new("/h")),
        PathBuf::from("/h/run/localapp.token")
    );
    let frame = cmux_agent_pane_policy::refusal_frame(
        r#""r-1""#,
        cmux_agent_pane_policy::Refusal::MethodRefused,
        Some("_acpmux/peer_add"),
        true,
    );
    let v: Value = serde_json::from_str(&frame).unwrap();
    assert_eq!(v["id"], "r-1");
    assert_eq!(v["error"]["code"], -32601);
    assert_eq!(v["error"]["message"], "Refused by the cmux host");
    assert_eq!(
        v["error"]["data"],
        serde_json::json!({"code": "transport.method_refused", "origin": "native", "method": "_acpmux/peer_add", "rootRequested": true})
    );
}

#[test]
fn reading_the_token_file() {
    let dir = std::env::temp_dir().join(format!("cmux-agent-pane-policy-{}", std::process::id()));
    let run = dir.join("run");
    std::fs::create_dir_all(&run).unwrap();
    assert_eq!(connection::read_local_app_token(&dir), None, "missing file");
    std::fs::write(run.join("localapp.token"), format!("{}\n", "b".repeat(64))).unwrap();
    assert_eq!(connection::read_local_app_token(&dir), Some("b".repeat(64)));
    std::fs::write(run.join("localapp.token"), "b".repeat(300)).unwrap();
    assert_eq!(connection::read_local_app_token(&dir), None, "over 256 bytes");
    std::fs::remove_dir_all(&dir).unwrap();
}
