//! The avatar strip a room shows (RFD 0141 phase 2): which faces a chat header or a workspace row
//! draws, in what order, how many more there are, and who is doing something worth a line ("Ana is
//! typing", "Claude is running"), from one list of records. Pure: the daemon projects each watched
//! room's records through it, and the app and iOS read the same answer, so no client re-derives
//! order or the line.
//!
//! The records must already be shared for the room (`Presence::shared`): an agent in a private chat
//! and anyone with Live off are never passed in, so the strip never lists them.

use serde::Serialize;

use crate::{Doing, Kind, Presence, PresenceId, Status};

/// Faces a strip draws before "+N" when the caller names no other bound.
pub const STRIP_FACES: usize = 3;
/// Names the activity line spells out before "and N more".
pub const LINE_NAMES: usize = 2;

/// One face in the strip.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Face {
    pub id: PresenceId,
    pub kind: Kind,
    pub name: Box<str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<Box<str>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_ref: Option<Box<str>>,
    pub doing: Doing,
    /// Away draws dimmed; Quiet draws as present with no activity.
    pub status: Status,
}

/// Who is doing something, in one line over the composer or under a row.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    /// People typing, then agents at work, at most `LINE_NAMES`.
    pub actors: Vec<Actor>,
    /// Actors past `actors`.
    pub more: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Actor {
    pub id: PresenceId,
    pub kind: Kind,
    pub name: Box<str>,
    pub doing: Doing,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Strip {
    pub faces: Vec<Face>,
    /// Records past `faces` ("+N").
    pub more: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<Line>,
}

/// Whether a record's activity earns the line: a person typing, an agent at work. An agent
/// waiting on a person or idle does not; a quiet or away entry never does.
fn acting(record: &Presence) -> bool {
    if record.status != Status::Live {
        return false;
    }
    match record.kind {
        Kind::Person => record.doing == Doing::Typing,
        Kind::Agent => !matches!(record.doing, Doing::Idle | Doing::Waiting),
    }
}

/// Order: acting first, then people before agents, live before away, then name, then id, so the
/// strip is stable across snapshots that list the same records in another order.
fn rank(record: &Presence) -> (bool, bool, bool, &str, &str) {
    (
        !acting(record),
        record.kind != Kind::Person,
        record.status == Status::Away,
        &record.name,
        &record.id.0,
    )
}

/// The strip for `records`, leaving out `viewer` (a client never sees its own face) and any
/// duplicate id (the first copy, by rank, wins). `faces` bounds the faces drawn; 0 draws none and
/// counts everyone in `more`.
pub fn strip(records: &[Presence], viewer: Option<&PresenceId>, faces: usize) -> Strip {
    let mut shown: Vec<&Presence> = records.iter().filter(|r| Some(&r.id) != viewer).collect();
    shown.sort_by(|a, b| rank(a).cmp(&rank(b)));
    let mut seen = std::collections::HashSet::new();
    shown.retain(|r| seen.insert(&r.id.0));
    let more = u32::try_from(shown.len().saturating_sub(faces)).unwrap_or(u32::MAX);
    let mut actors: Vec<Actor> = shown
        .iter()
        .filter(|r| acting(r))
        .map(|r| Actor { id: r.id.clone(), kind: r.kind, name: r.name.clone(), doing: r.doing })
        .collect();
    let line = (!actors.is_empty()).then(|| {
        let more = u32::try_from(actors.len().saturating_sub(LINE_NAMES)).unwrap_or(u32::MAX);
        actors.truncate(LINE_NAMES);
        Line { actors, more }
    });
    let faces = shown
        .into_iter()
        .take(faces)
        .map(|r| Face {
            id: r.id.clone(),
            kind: r.kind,
            name: r.name.clone(),
            color: r.color.clone(),
            avatar_ref: r.avatar_ref.clone(),
            doing: if r.status == Status::Live { r.doing } else { Doing::Idle },
            status: r.status,
        })
        .collect();
    Strip { faces, more, line }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn person(id: &str, name: &str) -> Presence {
        Presence::new(PresenceId(id.into()), Kind::Person, name, 1)
    }

    fn agent(id: &str, name: &str, doing: Doing) -> Presence {
        let mut record = Presence::new(PresenceId(id.into()), Kind::Agent, name, 1);
        record.doing = doing;
        record
    }

    fn ids(strip: &Strip) -> Vec<&str> {
        strip.faces.iter().map(|f| &*f.id.0).collect()
    }

    #[test]
    fn an_empty_room_draws_nothing() {
        assert_eq!(strip(&[], None, STRIP_FACES), Strip::default());
    }

    #[test]
    fn the_viewer_never_sees_their_own_face() {
        let me = PresenceId("me".into());
        let s = strip(&[person("me", "Me"), person("ana", "Ana")], Some(&me), STRIP_FACES);
        assert_eq!(ids(&s), ["ana"]);
        assert_eq!(s.more, 0);
    }

    #[test]
    fn people_typing_and_agents_running_come_first_and_fill_the_line() {
        let mut ana = person("ana", "Ana");
        ana.doing = Doing::Typing;
        let records = [
            person("bo", "Bo"),
            agent("s1", "Claude", Doing::Running),
            agent("s2", "Codex", Doing::Waiting),
            ana,
        ];
        let s = strip(&records, None, STRIP_FACES);
        assert_eq!(ids(&s), ["ana", "s1", "bo"]);
        assert_eq!(s.more, 1);
        let line = s.line.expect("someone acts");
        let names: Vec<_> = line.actors.iter().map(|a| (&*a.name, a.doing)).collect();
        assert_eq!(names, [("Ana", Doing::Typing), ("Claude", Doing::Running)]);
        assert_eq!(line.more, 0);
    }

    #[test]
    fn the_line_names_two_and_counts_the_rest() {
        let records = [
            agent("a", "A", Doing::Running),
            agent("b", "B", Doing::Editing),
            agent("c", "C", Doing::Thinking),
        ];
        let line = strip(&records, None, STRIP_FACES).line.expect("agents act");
        assert_eq!(line.actors.len(), LINE_NAMES);
        assert_eq!(line.more, 1);
    }

    #[test]
    fn quiet_and_away_never_act_and_away_sorts_after_live() {
        let mut quiet = person("q", "Quinn");
        quiet.status = Status::Quiet;
        quiet.doing = Doing::Typing;
        let mut away = agent("w", "Away agent", Doing::Running);
        away.status = Status::Away;
        let s = strip(&[away, quiet, agent("l", "Live agent", Doing::Idle)], None, STRIP_FACES);
        assert_eq!(s.line, None);
        assert_eq!(ids(&s), ["q", "l", "w"]);
        assert!(s.faces.iter().all(|f| f.doing == Doing::Idle));
    }

    #[test]
    fn order_is_stable_whatever_order_the_records_arrive_in() {
        let a = [person("x", "Ana"), person("y", "Ana"), person("z", "Bo")];
        let mut b = a.clone();
        b.reverse();
        assert_eq!(strip(&a, None, 2), strip(&b, None, 2));
        assert_eq!(ids(&strip(&a, None, 2)), ["x", "y"]);
    }

    #[test]
    fn a_duplicate_id_draws_once() {
        let s = strip(&[person("ana", "Ana"), person("ana", "Ana")], None, STRIP_FACES);
        assert_eq!(ids(&s), ["ana"]);
        assert_eq!(s.more, 0);
    }

    #[test]
    fn zero_faces_counts_everyone() {
        let s = strip(&[person("a", "A"), person("b", "B")], None, 0);
        assert!(s.faces.is_empty());
        assert_eq!(s.more, 2);
    }

    #[test]
    fn a_face_serializes_camel_case_without_empty_fields() {
        let s = strip(&[person("ana", "Ana")], None, STRIP_FACES);
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"faces": [{"id": "ana", "kind": "person", "name": "Ana", "doing": "idle", "status": "live"}], "more": 0})
        );
    }
}
