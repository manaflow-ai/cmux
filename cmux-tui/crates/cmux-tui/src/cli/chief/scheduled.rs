//! Send Later from the CLI (`conversation-scheduled-v1`, cmux#25634):
//! `cmux chief send TEXT --at WHEN` queues the message on the local owner,
//! which sends it at its time whether or not the CLI still runs, and
//! `cmux chief scheduled [list|edit|cancel|send-now]` reads and changes the
//! caller's queue in the current chat.

use std::io::Write as _;

use serde_json::{Value, json};

use super::backend::Owner;
use super::link::new_message_id;
use super::script::Request;
use super::{Session, render};

type Outcome = Result<(), (i32, String)>;

struct Text {
    local_only: &'static str,
    bad_time: &'static str,
    no_wait: &'static str,
    scheduled: &'static str,
    none: &'static str,
    needs_id: &'static str,
    cancelled: &'static str,
    sent: &'static str,
    edited: &'static str,
    failed: &'static str,
    bad_verb: &'static str,
}

static ENGLISH: Text = Text {
    local_only: "Send Later works in local chats only",
    bad_time: "{when} is not a time: give +30m, +2h, +1d, 2026-10-27T09:00:00-07:00 or a Unix time",
    no_wait: "--at and --wait do not go together: the message is sent later",
    scheduled: "scheduled {id} for {time}",
    none: "no scheduled messages",
    needs_id: "name a scheduled message: its id (sch_..., cmux chief scheduled)",
    cancelled: "cancelled {id}",
    sent: "sent {id} as #{seq}",
    edited: "rescheduled {id} for {time}",
    failed: "{id} was not sent: {reason}",
    bad_verb: "cmux chief scheduled takes list, edit ID [TEXT] [--at WHEN], cancel ID or send-now ID",
};

static JAPANESE: Text = Text {
    local_only: "後で送信はローカルのチャットでのみ使えます",
    bad_time: "{when} は時刻ではありません: +30m、+2h、+1d、2026-10-27T09:00:00+09:00 または Unix 時刻を指定してください",
    no_wait: "--at と --wait は同時に使えません: メッセージは後で送信されます",
    scheduled: "{id} を {time} に送信予約しました",
    none: "予約されたメッセージはありません",
    needs_id: "予約メッセージの ID (sch_...、cmux chief scheduled) を指定してください",
    cancelled: "{id} を取り消しました",
    sent: "{id} を #{seq} として送信しました",
    edited: "{id} を {time} に変更しました",
    failed: "{id} は送信されませんでした: {reason}",
    bad_verb: "cmux chief scheduled には list、edit ID [TEXT] [--at WHEN]、cancel ID、send-now ID を指定します",
};

fn text() -> &'static Text {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// Unix times below this are seconds, at or above it milliseconds (in
/// seconds it is the year 5138, in milliseconds March 1973).
const UNIX_MS_FROM: u64 = 100_000_000_000;

/// Parses WHEN: `+N` with a unit `s`, `m`, `h` or `d` from now, an RFC 3339
/// time with a `Z` or `±HH:MM` offset (seconds optional), or a Unix time in
/// seconds or milliseconds.
pub(super) fn parse_when(when: &str, now_ms: u64) -> Result<u64, String> {
    let bad = || text().bad_time.replace("{when}", when);
    let when = when.trim();
    if let Some(relative) = when.strip_prefix('+') {
        let split = relative.find(|c: char| !c.is_ascii_digit()).unwrap_or(relative.len());
        let (count, unit) = relative.split_at(split);
        let count: u64 = count.parse().map_err(|_| bad())?;
        let unit_ms = match unit {
            "s" => 1_000,
            "m" | "" => 60_000,
            "h" => 3_600_000,
            "d" => 86_400_000,
            _ => return Err(bad()),
        };
        return count.checked_mul(unit_ms).and_then(|ms| now_ms.checked_add(ms)).ok_or_else(bad);
    }
    if !when.is_empty() && when.bytes().all(|b| b.is_ascii_digit()) {
        let unix: u64 = when.parse().map_err(|_| bad())?;
        return if unix < UNIX_MS_FROM {
            unix.checked_mul(1_000).ok_or_else(bad)
        } else {
            Ok(unix)
        };
    }
    rfc3339_ms(when).ok_or_else(bad)
}

/// `YYYY-MM-DDTHH:MM[:SS[.fff]](Z|±HH:MM)` to Unix milliseconds.
fn rfc3339_ms(text: &str) -> Option<u64> {
    let (date, rest) = text.split_once(['T', ' '])?;
    let mut date = date.split('-');
    let (year, month, day): (i64, i64, i64) =
        (date.next()?.parse().ok()?, date.next()?.parse().ok()?, date.next()?.parse().ok()?);
    if date.next().is_some() {
        return None;
    }
    let offset_at = rest.find(['Z', 'z', '+', '-'])?;
    let (clock, zone) = rest.split_at(offset_at);
    let offset_minutes: i64 = match zone {
        "Z" | "z" => 0,
        _ => {
            let sign = if zone.starts_with('-') { -1 } else { 1 };
            let (hours, minutes) = zone[1..].split_once(':')?;
            let (hours, minutes) = (hours.parse::<i64>().ok()?, minutes.parse::<i64>().ok()?);
            if !(0..24).contains(&hours) || !(0..60).contains(&minutes) {
                return None;
            }
            sign * (hours * 60 + minutes)
        }
    };
    let mut clock = clock.split(':');
    let hour: i64 = clock.next()?.parse().ok()?;
    let minute: i64 = clock.next()?.parse().ok()?;
    let (second, millis) = match clock.next() {
        Some(seconds) => match seconds.split_once('.') {
            Some((whole, fraction)) => {
                let fraction = format!("{fraction:0<3}");
                (whole.parse::<i64>().ok()?, fraction.get(..3)?.parse::<i64>().ok()?)
            }
            None => (seconds.parse().ok()?, 0),
        },
        None => (0, 0),
    };
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_days = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if !(1..=12).contains(&month)
        || !(1..=month_days).contains(&day)
        || !(0..24).contains(&hour)
        || !(0..60).contains(&minute)
        || !(0..=60).contains(&second)
    {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60;
    u64::try_from(seconds * 1_000 + millis).ok()
}

/// A time in UTC for messages (`YYYY-MM-DD HH:MM:SS UTC`).
fn time_text(ms: u64) -> String {
    let seconds = (ms / 1_000) as i64;
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    // civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let mp = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC",
        rest / 3_600,
        rest % 3_600 / 60,
        rest % 60
    )
}

fn print(value: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn require_local(session: &Session) -> Outcome {
    if session.client.owner != Owner::Local {
        return Err((2, text().local_only.into()));
    }
    Ok(())
}

fn call(session: &mut Session, cmd: &str, params: Value) -> Result<Value, (i32, String)> {
    session.client.link.command(cmd, params).map_err(|error| session.failed(error))
}

/// `cmux chief send … --at WHEN`: queues `parts` instead of sending them.
pub(super) fn schedule(
    session: &mut Session,
    request: &Request,
    when: &str,
    parts: Vec<Value>,
    reply_to: Option<Value>,
    thread_root: Option<String>,
    json: bool,
) -> Outcome {
    require_local(session)?;
    if request.wait {
        return Err((2, text().no_wait.into()));
    }
    let send_at_ms = parse_when(when, now_ms()).map_err(|error| (2, error))?;
    let key = new_message_id();
    let mut send = json!({"kind": "message.send", "client_msg_id": key, "parts": parts});
    if let Some(reply_to) = reply_to {
        send["reply_to"] = reply_to;
    }
    if let Some(root) = thread_root {
        send["thread_root"] = json!(root);
    }
    let conversation = session.conversation.clone();
    let reply = call(
        session,
        "conversation-scheduled-op",
        json!({"op": {"kind": "scheduled.create", "conversation": conversation,
                      "send_at_ms": send_at_ms, "send": send}}),
    )?;
    let scheduled = reply.get("scheduled").cloned().unwrap_or(Value::Null);
    if json {
        print(&scheduled);
    } else {
        println!("{}", line(text().scheduled, &scheduled));
    }
    Ok(())
}

fn line(template: &str, scheduled: &Value) -> String {
    let id = scheduled.get("id").and_then(Value::as_str).unwrap_or("");
    let at = scheduled.get("send_at_ms").and_then(Value::as_u64).unwrap_or(0);
    template.replace("{id}", id).replace("{time}", &time_text(at))
}

/// The plain text of the message a scheduled item will send.
fn item_text(scheduled: &Value) -> String {
    let op = scheduled.get("op").cloned().unwrap_or(Value::Null);
    render::message_text(&json!({"parts": op.get("parts").cloned().unwrap_or(json!([]))}))
}

/// `cmux chief scheduled [list|edit|cancel|send-now]`.
pub(super) fn run(session: &mut Session, request: &Request, json: bool) -> Outcome {
    require_local(session)?;
    let words = &request.words;
    let id = || -> Result<String, (i32, String)> {
        words.get(1).cloned().ok_or_else(|| (2, text().needs_id.to_owned()))
    };
    match words.first().map(String::as_str) {
        None | Some("list") => list(session, json),
        Some("cancel") => {
            let id = id()?;
            let op = json!({"kind": "scheduled.cancel", "id": id});
            let reply = call(session, "conversation-scheduled-op", json!({"op": op}))?;
            if json {
                print(&reply);
            } else {
                println!("{}", text().cancelled.replace("{id}", &id));
            }
            Ok(())
        }
        Some("send-now") => {
            let id = id()?;
            let op = json!({"kind": "scheduled.send_now", "id": id});
            let reply = call(session, "conversation-scheduled-op", json!({"op": op}))?;
            if json {
                print(&reply);
                return Ok(());
            }
            if let Some(failed) = reply.get("scheduled").filter(|s| s["state"] == "failed") {
                let reason = failed.get("failure").and_then(Value::as_str).unwrap_or("");
                return Err((1, text().failed.replace("{id}", &id).replace("{reason}", reason)));
            }
            let seq = reply.pointer("/removed/seq").and_then(Value::as_u64).unwrap_or(0);
            println!("{}", text().sent.replace("{id}", &id).replace("{seq}", &seq.to_string()));
            Ok(())
        }
        Some("edit") => {
            let id = id()?;
            let mut op = json!({"kind": "scheduled.update", "id": id});
            if let Some(when) = &request.at {
                op["send_at_ms"] = json!(parse_when(when, now_ms()).map_err(|error| (2, error))?);
            }
            let body = words[2..].join(" ");
            if !body.trim().is_empty() {
                // New text replaces the text only: the files stay.
                let mut parts = vec![json!({"type": "text", "text": body})];
                parts.extend(kept_parts(session, &id)?);
                op["parts"] = json!(parts);
            }
            let reply = call(session, "conversation-scheduled-op", json!({"op": op}))?;
            let scheduled = reply.get("scheduled").cloned().unwrap_or(Value::Null);
            if json {
                print(&scheduled);
            } else {
                println!("{}", line(text().edited, &scheduled));
            }
            Ok(())
        }
        Some(_) => Err((2, text().bad_verb.into())),
    }
}

/// The parts of the caller's message `id` other than its text.
fn kept_parts(session: &mut Session, id: &str) -> Result<Vec<Value>, (i32, String)> {
    let reply = call(session, "conversation-scheduled-list", json!({}))?;
    let items = reply.get("scheduled").and_then(Value::as_array).cloned().unwrap_or_default();
    let Some(item) = items.iter().find(|item| item["id"] == id) else {
        return Ok(Vec::new());
    };
    let parts = item.pointer("/op/parts").and_then(Value::as_array).cloned().unwrap_or_default();
    Ok(parts.into_iter().filter(|part| part["type"] != "text").collect())
}

fn list(session: &mut Session, json: bool) -> Outcome {
    let conversation = session.conversation.clone();
    let reply =
        call(session, "conversation-scheduled-list", json!({"conversation": conversation}))?;
    let items = reply.get("scheduled").and_then(Value::as_array).cloned().unwrap_or_default();
    if json {
        print(&json!(items));
        return Ok(());
    }
    if items.is_empty() {
        println!("{}", text().none);
    }
    for item in &items {
        let id = item.get("id").and_then(Value::as_str).unwrap_or("");
        let at = item.get("send_at_ms").and_then(Value::as_u64).unwrap_or(0);
        let state = match item.get("failure").and_then(Value::as_str) {
            Some(reason) => format!("failed: {reason}"),
            None => "waiting".to_owned(),
        };
        println!("{id}  {}  {state}  {}", time_text(at), item_text(item));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_when;

    const NOW: u64 = 1_761_500_000_000;

    #[test]
    fn when_reads_relative_rfc3339_and_unix_times() {
        assert_eq!(parse_when("+2m", NOW), Ok(NOW + 120_000));
        assert_eq!(parse_when("+1d", NOW), Ok(NOW + 86_400_000));
        assert_eq!(parse_when("2026-10-27T09:00:00Z", NOW), Ok(1_793_091_600_000));
        assert_eq!(parse_when("2026-10-27T09:00-07:00", NOW), Ok(1_793_116_800_000));
        assert_eq!(parse_when("2028-02-29T00:00:00Z", NOW), Ok(1_835_395_200_000));
        // Unix seconds are not read as milliseconds (a 1970 time).
        assert_eq!(parse_when("1761500000", NOW), Ok(1_761_500_000_000));
        assert_eq!(parse_when("1761500000123", NOW), Ok(1_761_500_000_123));
    }

    #[test]
    fn when_refuses_impossible_dates_and_offsets() {
        for bad in [
            "2026-02-31T09:00:00Z",
            "2027-02-29T09:00:00Z",
            "2026-10-27-5T09:00:00Z",
            "2026-10-27T09:00:00+99:99",
            "2026-10-27T09:00:00+05:60",
            "+5x",
            "soon",
        ] {
            assert!(parse_when(bad, NOW).is_err(), "{bad} was accepted");
        }
    }
}
