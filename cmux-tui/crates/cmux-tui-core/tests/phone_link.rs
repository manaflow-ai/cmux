#![cfg(unix)]
//! `offer-link-to-phone` over the daemon socket. Leo, 2026-11-14: "I tried to open up a link on
//! the terminal on iOS. And a direct open link one. It opened in Alma on Mac". A link a program
//! opens while the phone drives the terminal goes to the phone; the Mac keeps every other one.

use cmux_tui_core::Actor;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

fn connect(path: &Path) -> BufReader<UnixStream> {
    let stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
    BufReader::new(stream)
}

fn read(stream: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(stream.read_line(&mut line).unwrap(), 0);
    serde_json::from_str(&line).unwrap()
}

/// Sends `value` with `id` and reads lines until its reply (skipping stream events).
fn rpc(stream: &mut BufReader<UnixStream>, id: u64, mut value: Value) -> Value {
    value["id"] = json!(id);
    writeln!(stream.get_mut(), "{value}").unwrap();
    loop {
        let line = read(stream);
        if line["id"] == id {
            return line;
        }
    }
}

/// Reads the phone's attach channel until its `phone-open-link` event.
fn pushed_link(phone: &mut BufReader<UnixStream>) -> Value {
    loop {
        let line = read(phone);
        if line["event"] == "phone-open-link" {
            return line;
        }
    }
}

#[test]
fn a_link_a_program_opens_goes_to_the_phone_that_drives_the_terminal() {
    let mux = Mux::new("phone-link-integration", SurfaceOptions::default());
    let surface =
        mux.new_workspace_as(&Actor::Daemon, Some("work".into()), Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().unwrap().to_string();
    let socket =
        std::env::temp_dir().join(format!("cmux-phone-link-{}", std::process::id())).join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let github = "https://github.com/login/device";
    let offer =
        |url: &str| json!({"cmd": "offer-link-to-phone", "terminal_id": terminal, "url": url});

    // The Mac app's own connection, attached to the terminal.
    let mut mac = connect(&socket);
    rpc(&mut mac, 1, json!({"cmd": "set-client-info", "name": "cmux", "kind": "app"}));
    rpc(&mut mac, 2, json!({"cmd": "attach-surface", "surface": surface.id}));
    // Nobody typed yet: the Mac opens it.
    assert_eq!(rpc(&mut mac, 3, offer(github))["data"]["offered"], false);

    // The phone, as the Mac's splice marks it: its attach channel and its input lane.
    let mut phone = connect(&socket);
    let info = json!({"cmd": "set-client-info", "name": "iPhone", "kind": "ios", "remote": true,
                      "device_id": "iphone-1", "capabilities": ["phone-open-link-v1"]});
    assert_eq!(rpc(&mut phone, 1, info)["ok"], true);
    rpc(&mut phone, 2, json!({"cmd": "attach-surface", "surface": surface.id}));
    let mut lane = connect(&socket);
    rpc(&mut lane, 1, json!({"cmd": "set-client-info", "remote": true, "device_id": "iphone-1"}));
    rpc(&mut lane, 2, json!({"cmd": "send", "surface": surface.id, "text": "x"}));

    // The phone typed last: the link goes to its attach channel, and the Mac opens nothing.
    assert_eq!(rpc(&mut mac, 4, offer(github))["data"]["offered"], true);
    let event = pushed_link(&mut phone);
    assert_eq!(event["terminal_id"], terminal);
    assert_eq!(event["url"], github);

    // A dev server only the Mac reaches stays on the Mac.
    assert_eq!(rpc(&mut mac, 5, offer("http://localhost:3000/"))["data"]["offered"], false);

    // The phone may not ask for it itself.
    assert_eq!(rpc(&mut lane, 3, offer(github))["ok"], false);

    // The Mac's own key takes the terminal back.
    rpc(&mut mac, 6, json!({"cmd": "send", "surface": surface.id, "text": "y"}));
    assert_eq!(rpc(&mut mac, 7, offer(github))["data"]["offered"], false);

    // The phone types again, then its input lane leaves: its keys no longer count.
    rpc(&mut lane, 4, json!({"cmd": "send", "surface": surface.id, "text": "z"}));
    drop(lane);
    let mut gone = false;
    for id in 8..200 {
        if rpc(&mut mac, id, offer(github))["data"]["offered"] == false {
            gone = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(gone, "a closed input lane's keys still sent links to the phone");

    mux.shutdown();
    server::cleanup(&socket);
}
