//! Replays `schemas/remote-tab/client.json` (the viewer's reducer).

use cmux_remote_browser::client::{Client, ClientEffect, ClientInput, ClientNote, ClientReject};
use serde::Deserialize;

const CLIENT: &str = include_str!("../../../../schemas/remote-tab/client.json");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VectorFile {
    #[allow(dead_code)]
    description: String,
    version: u32,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    name: String,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Step {
    input: ClientInput,
    expect: Expect,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Expect {
    effects: Vec<ClientEffect>,
    note: Option<ClientNote>,
    reject: Option<ClientReject>,
    open_menu: Option<u64>,
    open_dialog: Option<u64>,
    screen_seq: u32,
}

#[test]
fn client_vectors() {
    let file: VectorFile = serde_json::from_str(CLIENT).expect("client.json parses");
    assert_eq!(file.version, 1);
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let mut client = Client::default();
        for (i, step) in case.steps.into_iter().enumerate() {
            let at = format!("{} step {i}", case.name);
            let before = client.clone();
            match client.apply(step.input) {
                Ok(out) => {
                    assert_eq!(step.expect.reject, None, "{at}: expected a reject");
                    assert_eq!(out.effects, step.expect.effects, "{at}: effects");
                    assert_eq!(out.note, step.expect.note, "{at}: note");
                }
                Err(reject) => {
                    assert_eq!(Some(reject), step.expect.reject, "{at}: reject");
                    assert!(step.expect.effects.is_empty() && step.expect.note.is_none(), "{at}");
                    assert_eq!(client, before, "{at}: a reject changed the state");
                }
            }
            assert_eq!(client.open_menu, step.expect.open_menu, "{at}: open menu");
            assert_eq!(client.open_dialog, step.expect.open_dialog, "{at}: open dialog");
            assert_eq!(client.screen_seq, step.expect.screen_seq, "{at}: screen seq");
        }
    }
}
