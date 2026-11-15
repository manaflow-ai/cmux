//! Who may start app chats on a team Cloud machine, and sharing that (Leo, 2026-10-31: "but what's
//! the sharing flow? we can't simply block always. we need to be able to get stuff running asap."):
//! cmux-platform's `/v1/machines/{id}/chat-access` and `/v1/machines/{id}/chat-grants/{user}`
//! (`machines.chatAccess`, `machines.shareChat`, `machines.unshareChat`), through the generated
//! client with worker auth. Every answer is the platform's `MachineChatAccess`: `machineId`,
//! `creator`, `chatStart` (`owner`, `granted` or `none`, for the caller), `canShare` and `grants`.
//!
//! - `machine.chat_access` (`machine`): the caller's access.
//! - `machine.share_chat` (`machine`, `user`, optional `revoke`, optional `me`): shares the
//!   machine's chat starts with `user`, or takes the share back (`revoke: true`). Only the creator
//!   or a team admin may (`403 machine.creator_or_admin`), and only on a team machine
//!   (`403 machine.private`); `user` must be a member (`400 machine.not_member`).
//!
//!   `me: true` is Share with Me: `user` is the caller. A creator-or-admin refusal then reads the
//!   caller's access, and when the creator already shared it with them (`chatStart` is not `none`)
//!   that access is the answer, so the card's Retry after Ask the Owner picks the share up.

use serde_json::{Map, Value, json};

use super::previews::{answered, client};
use super::{Failure, Request, text};

/// How long one chat access or grant call may take.
const CHAT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// The refusal of someone who is neither the machine's creator nor a team admin.
pub(crate) const NOT_CREATOR_OR_ADMIN: &str = "machine.creator_or_admin";

/// The calls this module answers.
pub(crate) const CALLS: [&str; 2] = ["machine.chat_access", "machine.share_chat"];

/// A machine or user id, the only path parts that vary: 1 to 256 letters, digits, `_` or `-`
/// (the platform's `MachineId`), so nothing else ever lands in the URL.
pub(crate) fn is_path_id(id: &str) -> bool {
    (1..=256).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn id<'a>(args: &'a Map<String, Value>, name: &str) -> Result<&'a str, Failure> {
    let value = text(args, name)?;
    if is_path_id(value) { Ok(value) } else { Err(Failure::Transport(format!("not a {name} id"))) }
}

/// `value` as the generated client's path parameter type (its 1 to 256 character string), which
/// `is_path_id` already holds to.
fn typed<T: std::str::FromStr>(value: &str) -> Result<T, Failure> {
    value.parse().map_err(|_| Failure::Transport(format!("not a path id: {value}")))
}

fn flag(args: &Map<String, Value>, name: &str) -> bool {
    args.get(name).and_then(Value::as_bool).unwrap_or(false)
}

pub(crate) async fn run(
    request: &Request,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    let machine = id(args, "machine")?;
    match call {
        "machine.chat_access" => access(request, machine).await,
        "machine.share_chat" => {
            let user = id(args, "user")?;
            let (revoke, me) = (flag(args, "revoke"), flag(args, "me"));
            if revoke && me {
                return Err(Failure::Transport("Share with Me never takes a share back".into()));
            }
            let client = client(request)?;
            let path = format!("/v1/machines/{machine}/chat-grants");
            let answer = if revoke {
                let (on, to) = (typed(machine)?, typed(user)?);
                let sent = async {
                    client.machines_unshare_chat(&on, &to).await.map(|r| json!(r.into_inner()))
                };
                answered(request, CHAT_TIMEOUT, path, sent).await
            } else {
                let (on, to) = (typed(machine)?, typed(user)?);
                let sent = async {
                    client.machines_share_chat(&on, &to).await.map(|r| json!(r.into_inner()))
                };
                answered(request, CHAT_TIMEOUT, path, sent).await
            };
            match answer {
                Err(refusal) if me && is_not_creator_or_admin(&refusal) => {
                    match access(request, machine).await {
                        Ok(found) if starts_chats(&found) => Ok(found),
                        _ => Err(refusal),
                    }
                }
                answer => answer,
            }
        }
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

/// `GET /v1/machines/{machine}/chat-access`.
async fn access(request: &Request, machine: &str) -> Result<Value, Failure> {
    let client = client(request)?;
    let on = typed(machine)?;
    let sent = async { client.machines_chat_access(&on).await.map(|r| json!(r.into_inner())) };
    answered(request, CHAT_TIMEOUT, format!("/v1/machines/{machine}/chat-access"), sent).await
}

fn is_not_creator_or_admin(failure: &Failure) -> bool {
    matches!(failure, Failure::Http { status: 403, code: Some(code), .. } if code == NOT_CREATOR_OR_ADMIN)
}

/// The caller may start app chats on the machine: its creator, or a member it was shared with.
pub(crate) fn starts_chats(access: &Value) -> bool {
    matches!(access.get("chatStart").and_then(Value::as_str), Some("owner" | "granted"))
}
