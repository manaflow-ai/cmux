use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::{AgentShare, Armed, AutoOff, Caller};

const AGENT: Caller = Caller::LocalAgent { pid: Some(4242) };

/// An `AgentShare` whose audit rows land in the returned list, with `idle` as the no-viewer time.
fn share(idle: Duration) -> (AgentShare, Arc<Mutex<Vec<Value>>>) {
    let rows = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&rows);
    let share = AgentShare::new(
        Box::new(move |row| sink.lock().unwrap().push(row)),
        Box::new(move || idle),
        super::TICKET_TTL,
    );
    (share, rows)
}

fn events(rows: &Arc<Mutex<Vec<Value>>>) -> Vec<String> {
    rows.lock()
        .unwrap()
        .iter()
        .map(|row| row["event"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn agent() -> Value {
    json!({"session": "aid-54792b8db3a10d84", "name": "lane agents-share"})
}

fn ticket(share: &AgentShare, action: &str) -> String {
    share
        .ticket(AGENT, &json!({"action": action, "agent": agent()}))
        .expect("an owner's local agent gets a ticket")["ticket"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn redeem(share: &AgentShare, ticket: &str, allowed: bool) -> Value {
    share
        .redeem(
            Caller::App,
            &json!({"ticket": ticket, "allowed": allowed, "account": "user-a",
                    "this_device": {"id": "dev-studio", "name": "Studio"}}),
        )
        .expect("the app redeems")
}

#[test]
fn the_owners_agent_with_the_permission_on_passes_with_no_dialog() {
    let (share, rows) = share(Duration::from_secs(900));
    let id = ticket(&share, "share");
    let answer = redeem(&share, &id, true);
    assert_eq!(answer["dialog"], false);
    assert_eq!(answer["on"], true);
    assert_eq!(answer["agent"]["session"], "aid-54792b8db3a10d84");
    assert_eq!(answer["agent"]["pid"], 4242);
    assert_eq!(answer["idle_minutes"], 15);
    // The audit row names the agent session and the device.
    let rows = rows.lock().unwrap().clone();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["event"], "remote_host.agent_share_on");
    assert_eq!(rows[0]["agent"]["session"], "aid-54792b8db3a10d84");
    assert_eq!(rows[0]["agent"]["name"], "lane agents-share");
    assert_eq!(rows[0]["device"], json!({"id": "dev-studio", "name": "Studio"}));
    assert_eq!(rows[0]["account"], "user-a");
    // The ticket is single-use: a second redeem asks the person.
    assert_eq!(redeem(&share, &id, true)["dialog"], true);
    // The decision alone arms nothing; the made change arms the agent's countdown.
    assert_eq!(share.status()["active"], false);
    assert_eq!(applied(&share, &id, true)["armed"], true);
    assert_eq!(share.status()["active"], true);
}

fn applied(share: &AgentShare, ticket: &str, ok: bool) -> Value {
    share.applied(Caller::App, &json!({"ticket": ticket, "ok": ok})).expect("the app reports")
}

#[test]
fn agent_share_arms_only_after_a_made_change_and_never_on_the_persons_share() {
    let (share, _) = share(Duration::from_secs(900));
    // A failed hub write arms nothing.
    let failed = ticket(&share, "share");
    redeem(&share, &failed, true);
    assert_eq!(applied(&share, &failed, false)["armed"], false);
    assert_eq!(share.status()["active"], false);
    // An agent repeating share on a Mac the person already shares leaves it uncounted.
    let repeat = ticket(&share, "share");
    share
        .redeem(
            Caller::App,
            &json!({"ticket": repeat, "allowed": true, "account": "user-a", "already_shared": true,
                    "this_device": {"id": "dev-studio", "name": "Studio"}}),
        )
        .unwrap();
    assert_eq!(applied(&share, &repeat, true)["armed"], false);
    assert_eq!(share.status()["active"], false);
    // A report is single-use, and only the app makes it.
    assert_eq!(applied(&share, &repeat, true)["armed"], false);
    assert!(share.applied(AGENT, &json!({"ticket": repeat, "ok": true})).is_err());
    // An unshare whose write failed keeps the agent's countdown; a made one cancels it.
    let on = ticket(&share, "share");
    redeem(&share, &on, true);
    applied(&share, &on, true);
    let off = ticket(&share, "unshare");
    redeem(&share, &off, true);
    applied(&share, &off, false);
    assert_eq!(share.status()["active"], true);
    let off = ticket(&share, "unshare");
    redeem(&share, &off, true);
    applied(&share, &off, true);
    assert_eq!(share.status()["active"], false);
}

#[test]
fn the_owners_agent_with_the_permission_off_gets_the_dialog() {
    let (share, rows) = share(Duration::from_secs(900));
    let id = ticket(&share, "share");
    let answer = redeem(&share, &id, false);
    assert_eq!(answer, json!({"dialog": true, "reason": "agents.not_allowed"}));
    assert_eq!(events(&rows), ["remote_host.agent_share_asks_person"]);
    assert_eq!(rows.lock().unwrap()[0]["agent"]["session"], "aid-54792b8db3a10d84");
    // Nothing armed, no notice: the person's dialog decides, as today.
    assert_eq!(share.status()["active"], false);
    assert_eq!(share.status()["notices"], json!([]));
    // Signed out, an unknown ticket and an expired one ask the person too.
    let id = ticket(&share, "share");
    let signed_out =
        share.redeem(Caller::App, &json!({"ticket": id, "allowed": true, "account": ""})).unwrap();
    assert_eq!(signed_out["reason"], "agents.signed_out");
    assert_eq!(redeem(&share, "forged", true)["reason"], "agents.ticket_invalid");
    let (expiring, _) = {
        let rows = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&rows);
        (
            AgentShare::new(
                Box::new(move |row| sink.lock().unwrap().push(row)),
                Box::new(|| Duration::from_secs(900)),
                Duration::ZERO,
            ),
            rows,
        )
    };
    let id = ticket(&expiring, "share");
    assert_eq!(redeem(&expiring, &id, true)["reason"], "agents.ticket_invalid");
}

#[test]
fn an_agent_never_redeems_its_own_ticket_nor_asks_for_the_permission_itself() {
    let (share, rows) = share(Duration::from_secs(900));
    let id = ticket(&share, "share");
    // Only the verified app redeems: an agent that skips the app is refused.
    let refused = share
        .redeem(AGENT, &json!({"ticket": id, "allowed": true, "account": "user-a"}))
        .unwrap_err();
    assert_eq!(refused.code, "origin.forbidden");
    assert!(share.person(AGENT).is_err());
    // Turning the permission on is the person's: never an agent ticket.
    let refused = share
        .ticket(AGENT, &json!({"action": "allow_agents", "on": true, "agent": agent()}))
        .unwrap_err();
    assert_eq!(refused.code, "agents.person_only");
    assert_eq!(events(&rows), ["remote_host.agent_share_refused"]);
    // The app asks for no tickets, and other actions are not tickets.
    assert!(share.ticket(Caller::App, &json!({"action": "share"})).is_err());
    assert!(share.ticket(AGENT, &json!({"action": "access", "scope": "full"})).is_err());
    assert!(share.ticket(AGENT, &json!({"action": "unshare", "device": "Laptop"})).is_err());
}

#[test]
fn an_agent_asking_for_another_accounts_device_is_refused() {
    let (share, rows) = share(Duration::from_secs(900));
    let id = share
        .ticket(AGENT, &json!({"action": "share", "device": "Laptop", "agent": agent()}))
        .unwrap()["ticket"]
        .as_str()
        .unwrap()
        .to_owned();
    let params = |id: &str, owner: &str| {
        json!({"ticket": id, "allowed": true, "account": "user-a",
               "this_device": {"id": "dev-studio", "name": "Studio"},
               "target": {"id": "dev-laptop", "name": "Laptop", "account": owner}})
    };
    let refused = share.redeem(Caller::App, &params(&id, "user-b")).unwrap_err();
    assert_eq!(refused.code, "agents.other_account");
    // A device the app does not list as this account's (no target) is refused the same way.
    let id = share
        .ticket(AGENT, &json!({"action": "share", "device": "Laptop", "agent": agent()}))
        .unwrap()["ticket"]
        .as_str()
        .unwrap()
        .to_owned();
    let refused = share
        .redeem(Caller::App, &json!({"ticket": id, "allowed": true, "account": "user-a"}))
        .unwrap_err();
    assert_eq!(refused.code, "agents.other_account");
    assert_eq!(
        events(&rows),
        ["remote_host.agent_share_refused", "remote_host.agent_share_refused"]
    );
    // The same account's device passes with no dialog; the target turns on there (no timer here).
    let id = share
        .ticket(AGENT, &json!({"action": "share", "device": "Laptop", "agent": agent()}))
        .unwrap()["ticket"]
        .as_str()
        .unwrap()
        .to_owned();
    let answer = share.redeem(Caller::App, &params(&id, "user-a")).unwrap();
    assert_eq!(answer["dialog"], false);
    assert_eq!(answer["target"]["name"], "Laptop");
    assert_eq!(answer["notice"]["turn_off"], Value::Null);
    assert_eq!(share.status()["active"], false);
    assert_eq!(rows.lock().unwrap().last().unwrap()["target"]["id"], "dev-laptop");
}

#[test]
fn every_agent_change_emits_a_notice_with_a_working_turn_off() {
    let (share, rows) = share(Duration::from_secs(900));
    let on = redeem(&share, &ticket(&share, "share"), true);
    assert_eq!(on["notice"]["kind"], "shared");
    assert_eq!(on["notice"]["device_name"], "Studio");
    assert_eq!(on["notice"]["agent"], "lane agents-share");
    assert_eq!(on["notice"]["turn_off"], super::TURN_OFF_ACTION);
    let off = redeem(&share, &ticket(&share, "unshare"), true);
    assert_eq!(off["on"], false);
    assert_eq!(off["notice"]["kind"], "unshared");
    // Off cancels the agent's timer, and writes its own row.
    assert_eq!(share.status()["active"], false);
    assert_eq!(events(&rows), ["remote_host.agent_share_on", "remote_host.agent_share_off"]);
    let notices = share.status()["notices"].clone();
    assert_eq!(notices.as_array().unwrap().len(), 2);
    assert!(notices[1]["seq"].as_u64() > notices[0]["seq"].as_u64());
}

/// A timer whose firings arrive on the returned channel.
fn timer() -> (Arc<AutoOff>, Receiver<Armed>) {
    let (sender, receiver) = channel();
    let sender = Mutex::new(sender);
    let timer = AutoOff::new(Box::new(move |armed| {
        let _ = sender.lock().unwrap().send(armed);
    }));
    (timer, receiver)
}

fn armed(idle: Duration) -> Armed {
    Armed {
        actor: super::Actor { session: Some("aid-1".into()), name: None, pid: Some(1) },
        device: json!({"id": "dev-studio", "name": "Studio"}),
        idle,
        deadline: None,
    }
}

#[test]
fn auto_off_fires_after_the_idle_time_with_no_viewer() {
    let (timer, fired) = timer();
    timer.arm(armed(Duration::from_millis(40)));
    let armed = fired.recv_timeout(Duration::from_secs(10)).expect("fires with no viewer");
    assert_eq!(armed.actor.session.as_deref(), Some("aid-1"));
    // Fired once, then stopped: nothing more arrives.
    assert!(fired.recv_timeout(Duration::from_millis(200)).is_err());
}

#[test]
fn auto_off_does_not_fire_while_a_viewer_is_connected_and_rearms_when_it_leaves() {
    let (timer, fired) = timer();
    timer.viewer(true);
    timer.arm(armed(Duration::from_millis(40)));
    assert!(fired.recv_timeout(Duration::from_millis(400)).is_err(), "held while a viewer watches");
    // A viewer connecting after the countdown started holds it too.
    timer.viewer(false);
    timer.viewer(true);
    assert!(fired.recv_timeout(Duration::from_millis(400)).is_err());
    // The last viewer leaves: the countdown starts again and fires.
    timer.viewer(false);
    assert!(fired.recv_timeout(Duration::from_secs(10)).is_ok());
}

#[test]
fn auto_off_is_cancelled_when_the_person_takes_over() {
    let (share, rows) = share(Duration::from_millis(40));
    let turned_off = Arc::new(Mutex::new(0));
    let count = Arc::clone(&turned_off);
    share.set_turn_off(Box::new(move || {
        *count.lock().unwrap() += 1;
        Ok(())
    }));
    let id = ticket(&share, "share");
    redeem(&share, &id, true);
    applied(&share, &id, true);
    assert_eq!(share.person(Caller::App).unwrap()["cancelled"], true);
    let (timer, fired) = timer();
    timer.arm(armed(Duration::from_millis(40)));
    assert!(timer.cancel());
    assert!(fired.recv_timeout(Duration::from_millis(400)).is_err());
    assert_eq!(*turned_off.lock().unwrap(), 0);
    assert_eq!(events(&rows), ["remote_host.agent_share_on"]);
}

#[test]
fn auto_off_turns_sharing_off_and_writes_its_row_and_notice() {
    let (share, rows) = share(Duration::from_millis(40));
    let (sender, turned_off) = channel();
    let sender = Mutex::new(sender);
    share.set_turn_off(Box::new(move || {
        let _ = sender.lock().unwrap().send(());
        Ok(())
    }));
    let id = ticket(&share, "share");
    redeem(&share, &id, true);
    applied(&share, &id, true);
    turned_off.recv_timeout(Duration::from_secs(10)).expect("the timer turns sharing off");
    // The row and the notice follow the call in the timer thread; the next status sees them.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !events(&rows).contains(&"remote_host.agent_share_auto_off".to_owned()) {
        assert!(std::time::Instant::now() < deadline, "no auto-off row: {:?}", events(&rows));
        std::thread::yield_now();
    }
    let row = rows.lock().unwrap().last().unwrap().clone();
    assert_eq!(row["agent"]["session"], "aid-54792b8db3a10d84");
    assert_eq!(row["device"]["name"], "Studio");
    assert_eq!(row["turned_off"], true);
    let status = share.status();
    assert_eq!(status["active"], false);
    assert_eq!(status["notices"].as_array().unwrap().last().unwrap()["kind"], "auto_off");
}

#[test]
fn the_audit_log_is_one_owner_only_json_line_per_row() {
    struct Dir(std::path::PathBuf);
    impl Dir {
        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let dir =
        Dir(std::env::temp_dir().join(format!("agent-share-audit-{}", super::mint_id().unwrap())));
    super::append_in(dir.path(), json!({"event": "remote_host.agent_share_on"})).unwrap();
    super::append_in(dir.path(), json!({"event": "remote_host.agent_share_off"})).unwrap();
    let text = std::fs::read_to_string(dir.path().join("audit.jsonl")).unwrap();
    let lines: Vec<Value> = text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[1]["event"], "remote_host.agent_share_off");
    assert!(lines[0]["ts_unix"].as_u64().is_some());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(dir.path().join("audit.jsonl")).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0);
    }
}
