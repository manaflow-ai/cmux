//! `CloudHomeMapping` and `CloudHomeState` decisions as ops: the cloud's rows with the account's id as
//! Home's, the inbox laid over heads, and the snapshot order.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("mapping.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn identity() -> Value {
    json!({"cloudId": "user_u_1", "localId": "p_me", "displayName": "Me", "participantId": "user_8dd4635719067d14ccee"})
}

fn entry(id: &str, last_seq: u64) -> Value {
    json!({"conversation": id, "rev": 1, "kind": "group", "title": id, "last_seq": last_seq,
           "last_at": "2026-11-25T20:16:00.000Z", "unread": 2})
}

#[test]
fn sha256_matches_the_fips_vectors() {
    use cmux_home_rules::mapping::sha256::hex;
    assert_eq!(hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    assert_eq!(hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert_eq!(
        hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    );
    assert_eq!(
        hex(&[b'a'; 1000]),
        "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
    );
}

#[test]
fn the_identity_is_the_workers_ids() {
    let reply = op(
        "cloudIdentity",
        json!({"stackUserId": "u_1", "displayName": "Me", "localId": "p_me",
        "stackProjectId": "proj_1", "stackTeamId": "TEAM-ABC"}),
    );
    assert_eq!(reply["identity"], identity());
    assert_eq!(reply["workerTeamId"], "team_7f372c4c2f3a6d2c1355");
    let lower = op(
        "cloudIdentity",
        json!({"stackUserId": "u_1", "displayName": "Me", "localId": "p_me",
        "stackProjectId": "proj_1", "stackTeamId": "team-abc"}),
    );
    assert_eq!(lower["workerTeamId"], "team_7f372c4c2f3a6d2c1355");
    let bare = op(
        "cloudIdentity",
        json!({"stackUserId": "user_u_1", "displayName": "Me", "localId": "p_me"}),
    );
    assert_eq!(bare["identity"]["participantId"], "user_u_1");
    assert_eq!(bare["identity"]["cloudId"], "user_u_1");
}

#[test]
fn an_address_is_an_invited_contact_and_roles_are_filtered() {
    let reply = op(
        "cloudParticipant",
        json!({"identity": identity(),
        "participant": {"id": "addr_1", "kind": "address", "display_name": "a@b.c", "role": "superuser"}}),
    );
    let p = &reply["participant"];
    assert_eq!(p["kind"], "human");
    assert_eq!(p["membership"], "invited");
    assert_eq!(p["invitedContact"], "a@b.c");
    assert!(p.get("role").is_none());
    let me = op(
        "cloudParticipant",
        json!({"identity": identity(),
        "participant": {"id": "user_8dd4635719067d14ccee", "kind": "human", "display_name": "Me", "role": "admin"}}),
    );
    assert_eq!(me["participant"]["id"], "p_me");
    assert_eq!(me["participant"]["role"], "admin");
}

#[test]
fn a_cloud_head_drops_who_left_and_merges_the_users_cursors() {
    let reply = op(
        "cloudSummary",
        json!({"identity": identity(), "summary": {
            "id": "c1", "title": "Team", "last_seq": 9, "rev": 4, "kind": "dm",
            "created_at": "2026-11-25T20:16:00.000Z", "updated_at": "bad",
            "participants": [
                {"id": "user_u_1", "kind": "human", "display_name": "Me"},
                {"id": "user_gone", "kind": "human", "display_name": "Gone", "left_at": "2026-11-25T20:16:00.000Z"},
                {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"},
            ],
            "read_cursors": {"user_u_1": 3, "user_8dd4635719067d14ccee": 7, "user_z": 1},
            "settings": {"wake_policy": "mentions"},
        }}),
    );
    let s = &reply["summary"];
    assert_eq!(s["owner"], "cloud");
    assert_eq!(s["declaredKind"], "direct");
    assert_eq!(s["chiefReplies"], "mentions");
    assert_eq!(s["updatedAt"], -62135769600.0);
    let ids: Vec<&Value> = s["participants"].as_array().unwrap().iter().map(|p| &p["id"]).collect();
    assert_eq!(ids, [&json!("p_me"), &json!("agent_mux")]);
    assert_eq!(s["participants"][1]["agentClass"], "chief");
    assert_eq!(s["readCursors"], json!(["p_me", 7, "user_z", 1]));
}

#[test]
fn an_entry_alone_is_a_summary_with_its_floor_cursor() {
    let mut e = entry("c1", 10);
    e["dm_peer"] = json!("agent_7");
    e["pinned"] = json!(true);
    e["pin_position"] = json!(3);
    e["mentions"] = json!(1);
    let s = op("inboxEntrySummary", json!({"entry": e, "identity": identity()}))["summary"].clone();
    assert_eq!(s["readCursors"], json!(["p_me", 8]));
    assert_eq!(s["pinRank"], 3);
    assert_eq!(s["mentionCount"], 1);
    assert_eq!(s["declaredKind"], "group");
    assert_eq!(s["participants"][1]["id"], "agent_7");
    assert_eq!(s["participants"][1]["kind"], "agent");
}

#[test]
fn an_entry_over_a_head_keeps_the_chief_and_moves_last_seq_forward() {
    let head = json!({"id": "c1", "declaredKind": "chief", "lastSeq": 4, "updatedAt": 0.0, "pinRank": 1, "extra": "kept"});
    let s = op(
        "inboxEntrySummary",
        json!({"entry": entry("c1", 10), "identity": identity(), "head": head}),
    )["summary"]
        .clone();
    assert_eq!(s["declaredKind"], "chief");
    assert_eq!(s["lastSeq"], 10);
    assert!(s["updatedAt"].as_f64().unwrap() > 1.7e9);
    assert!(s.get("pinRank").is_none());
    assert_eq!(s["muted"], false);
    assert_eq!(s["extra"], "kept");
}

#[test]
fn the_snapshot_lists_entries_then_created_then_open() {
    let reply = op(
        "cloudSnapshot",
        json!({
            "identity": identity(),
            "entries": [entry("c2", 1), entry("c1", 1)],
            "heads": [{"id": "c9", "lastSeq": 0}, {"id": "c5", "lastSeq": 0}, {"id": "c3", "lastSeq": 0}, {"id": "c4", "lastSeq": 0}],
            "created": ["c5", "c1"],
            "targets": ["c9", "c3", "c4", "c1"],
            "removed": ["c4"],
            "inboxRev": 6,
        }),
    );
    let ids: Vec<&Value> =
        reply["conversations"].as_array().unwrap().iter().map(|c| &c["id"]).collect();
    assert_eq!(
        ids,
        ["c1", "c2", "c5", "c3", "c9"]
            .iter()
            .map(|id| json!(id))
            .collect::<Vec<_>>()
            .iter()
            .collect::<Vec<_>>()
    );
    assert_eq!(reply["rev"], 7);
}

#[test]
fn missing_heads_are_listed_unsubscribed_and_behind() {
    let reply = op(
        "cloudMissingHeads",
        json!({
            "entries": [entry("c1", 5), entry("c2", 5), entry("c3", 5), entry("c4", 5)],
            "heads": [{"id": "c2", "lastSeq": 5}, {"id": "c3", "lastSeq": 4}],
            "targets": ["c4"],
        }),
    );
    assert_eq!(reply["ids"], json!(["c1", "c3"]));
}

#[test]
fn a_participant_record_comes_from_a_head_or_the_directory() {
    let state = json!({"identity": identity(),
        "heads": [{"id": "c1", "participants": [{"id": "agent_c", "kind": "agent", "displayName": "Chief", "agentClass": "chief", "membership": "active"}]}],
        "directory": [{"id": "user_friend", "kind": "human", "displayName": "Friend", "membership": "active"}]});
    let record = |id: &str| {
        let mut request = state.clone();
        request["id"] = json!(id);
        op("cloudParticipantRecord", request)["participant"].clone()
    };
    assert_eq!(
        record("agent_c"),
        json!({"id": "agent_c", "kind": "agent", "display_name": "Chief", "agent_class": "mux"})
    );
    assert_eq!(
        record("user_friend"),
        json!({"id": "user_friend", "kind": "human", "display_name": "Friend"})
    );
    assert_eq!(record("p_me")["id"], "user_8dd4635719067d14ccee");
    assert_eq!(record("agent_new")["agent_class"], "agent");
    assert!(call("mapping.cloudParticipantRecord", &json!({"id": "x"})).is_err());
}

#[test]
fn cloud_parts_mention_the_users_cloud_id() {
    let reply = op(
        "cloudParts",
        json!({"identity": identity(),
        "parts": [{"text": {"_0": "@me", "mentions": [{"start": 0, "length": 3, "participant": "p_me"}]}}]}),
    );
    assert_eq!(reply["parts"][0]["runs"][0]["mention"], "user_8dd4635719067d14ccee");
}

/// `HomeGroupRolesTests`: the roles reach the Home members, an unknown role is none, and a large
/// group carries its count.
#[test]
fn group_roles_and_member_count_reach_the_home_head() {
    let me = json!({"cloudId": "user_me", "localId": "user_me", "displayName": "Lawrence", "participantId": "user_me"});
    let head = |extra: Value| {
        let mut summary = json!({"id": "conv_g", "owner": "cloud", "title": "Launch", "kind": "group", "last_seq": 1, "rev": 1,
            "created_at": "2026-10-01T00:00:00.000Z", "updated_at": "2026-10-01T00:00:00.000Z", "read_cursors": {},
            "participants": [
                {"id": "user_me", "kind": "human", "display_name": "Lawrence", "role": "owner"},
                {"id": "user_aziz", "kind": "human", "display_name": "Aziz", "role": "admin"},
                {"id": "user_leo", "kind": "human", "display_name": "Leo", "role": "read_only"},
                {"id": "user_sam", "kind": "human", "display_name": "Sam", "role": "member"},
                {"id": "user_kim", "kind": "human", "display_name": "Kim", "role": "emperor"}]});
        summary.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        op("cloudSummary", json!({"summary": summary, "identity": me}))["summary"].clone()
    };
    let summary = head(json!({}));
    let roles: Vec<Value> = summary["participants"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.get("role").cloned().unwrap_or(Value::Null))
        .collect();
    assert_eq!(
        roles,
        [json!("owner"), json!("admin"), json!("read_only"), json!("member"), Value::Null]
    );
    assert!(summary.get("memberCount").is_none());
    assert_eq!(head(json!({"member_count": 5000}))["memberCount"], 5000);
}
