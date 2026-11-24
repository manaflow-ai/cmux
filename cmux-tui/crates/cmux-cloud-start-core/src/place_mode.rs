//! Where a new chat starts: its place mode (Auto, Cloud, or one machine), this Mac's room, and
//! the account, to one answer and a short why (Leo, 2026-11-24: "let's just use our existing
//! dropdown and have it be able to have a chevron that opens into more options for... our options
//! we want to serve for cloud"; "ab that + the cloud thing bc we have multi cloud even thought it's
//! auto.. ish."). Pure: the caller reads acpmux's placement verdict (`_acpmux/place`) and the
//! account, and starts the chat where [`decide`] says.
//!
//! The modes:
//! - [`Mode::Auto`], every new chat's mode unless the person picks another for that chat: this
//!   Mac when acpmux's placement says it has room, else a new Cloud VM (a hybrid start where
//!   [`hybrid::enabled`] says so), never another of the person's machines. With Cloud off or
//!   signed out, this Mac all the same: placement's load and caps only warn.
//! - [`Mode::Cloud`]: a new Cloud VM for this chat, of the size picked (none: the Cloud start's
//!   own default, what Auto gets).
//! - [`Mode::Machine`]: that machine, pinned; one that is not connected starts nothing.
//!
//! A pick is the chat's own and never becomes the default: the store keeps it per chat
//! (acpmux `_acpmux/chat_place_set`), and a chat with none is Auto.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::hybrid::{self, Account};

/// A Cloud VM's size, as the picker offers it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Size {
    S,
    M,
    L,
}

impl Size {
    /// `s`, `m`, `l`, or the VM API's words `small`, `medium`, `large` (any case).
    pub fn parse(word: &str) -> Option<Self> {
        match word.trim().to_ascii_lowercase().as_str() {
            "s" | "small" => Some(Self::S),
            "m" | "medium" => Some(Self::M),
            "l" | "large" => Some(Self::L),
            _ => None,
        }
    }

    /// The VM API's word (`cmux vm new --size`).
    pub fn word(self) -> &'static str {
        match self {
            Self::S => "small",
            Self::M => "medium",
            Self::L => "large",
        }
    }

    fn letter(self) -> &'static str {
        match self {
            Self::S => "S",
            Self::M => "M",
            Self::L => "L",
        }
    }
}

/// A chat's place mode.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "kebab-case")]
pub enum Mode {
    #[default]
    Auto,
    Cloud {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        size: Option<Size>,
    },
    Machine {
        id: String,
    },
}

impl Mode {
    /// The mode a picker row sends: `{"mode": "auto"}`, `{"mode": "cloud", "size": "m"}` (size
    /// optional) or `{"mode": "machine", "machine": ID}` (`id` too). `Err` says what is wrong.
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).map(str::trim);
        match text("mode") {
            Some("auto") => Ok(Self::Auto),
            Some("cloud") => match params.get("size") {
                None | Some(Value::Null) => Ok(Self::Cloud { size: None }),
                Some(v) => v
                    .as_str()
                    .and_then(Size::parse)
                    .map(|size| Self::Cloud { size: Some(size) })
                    .ok_or_else(|| format!("size {v} is not s, m or l")),
            },
            Some("machine") => match text("machine").or_else(|| text("id")) {
                Some(id) if !id.is_empty() => Ok(Self::Machine { id: id.to_owned() }),
                _ => Err("mode machine needs the machine's id (`machine`)".into()),
            },
            Some(other) => Err(format!("mode {other:?} is not auto, cloud or machine")),
            None => Err("mode is missing: auto, cloud or machine".into()),
        }
    }
}

/// This Mac as acpmux's placement weighed it ([`local_of`]).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Local {
    /// This machine's name, as placement and the peers know it.
    pub name: String,
    /// Why placement turns this Mac away for its load, room or swap. None: it has room, or its
    /// numbers are unknown (an unread host starts work here, as before).
    pub busy: Option<String>,
    /// Its room in lanes, when read.
    pub room: Option<f64>,
    /// Its free RAM in bytes, when read.
    pub ram_free: Option<f64>,
}

/// This Mac from a `_acpmux/place` verdict: its host row (`local: true`). A row refused only
/// for load, room or swap (`load: true`) is busy; one refused for its role (not a lane host)
/// is not: that says nothing of its room, and a chat started here before.
pub fn local_of(verdict: &Value) -> Local {
    let row = verdict
        .get("hosts")
        .and_then(Value::as_array)
        .and_then(|hosts| hosts.iter().find(|h| h.get("local") == Some(&Value::Bool(true))));
    let Some(row) = row else { return Local::default() };
    let busy = (row.get("load") == Some(&Value::Bool(true)))
        .then(|| row.get("refused").and_then(Value::as_str).unwrap_or("no room").to_owned());
    Local {
        name: row.get("name").and_then(Value::as_str).unwrap_or_default().to_owned(),
        busy,
        room: row.get("room").and_then(Value::as_f64),
        ram_free: row.get("ramFree").and_then(Value::as_f64),
    }
}

/// What [`decide`] weighs.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub local: Local,
    pub account: Account,
    /// The machines a pinned chat may start on now (connected), by id.
    pub machines: Vec<String>,
}

/// Where the chat starts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "kebab-case")]
pub enum Place {
    ThisMac,
    /// A new Cloud VM. `hybrid`: the chat answers here while it boots, then moves there.
    Cloud {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        size: Option<Size>,
        hybrid: bool,
    },
    Machine {
        id: String,
    },
    /// Nothing starts; `why` says what to pick instead.
    Nowhere,
}

/// [`decide`]'s answer: where, why, and the composer chip's line.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    pub place: Place,
    pub why: String,
    pub chip: String,
}

const GB: f64 = 1e9;

/// Why Cloud cannot take a chat for this account, or None when it can.
fn cloud_off(account: &Account) -> Option<&'static str> {
    if account.cloud_disabled {
        Some("Cloud is turned off for this account")
    } else if !account.signed_in {
        Some("Cloud needs you signed in")
    } else {
        None
    }
}

fn free(local: &Local) -> Option<String> {
    local.ram_free.map(|b| format!("{:.0} GB free", b / GB))
}

fn cloud_place(size: Option<Size>, account: &Account) -> Place {
    Place::Cloud { size, hybrid: hybrid::enabled(account).is_ok() }
}

fn hybrid_note(place: &Place) -> &'static str {
    match place {
        Place::Cloud { hybrid: true, .. } => ", answering here while it boots",
        _ => "",
    }
}

/// Where a new chat in `mode` starts, given `facts`, and why.
pub fn decide(mode: &Mode, facts: &Facts) -> Decision {
    let local = &facts.local;
    match mode {
        Mode::Auto => match (&local.busy, cloud_off(&facts.account)) {
            (None, _) => {
                let room = free(local);
                Decision {
                    place: Place::ThisMac,
                    why: match local.room {
                        Some(r) => format!("this Mac has room (for {r:.0} more)"),
                        None => "this Mac's room is not read, so it starts here".into(),
                    },
                    chip: match room {
                        Some(room) => format!("Auto · This Mac: {room}"),
                        None => "Auto · This Mac".into(),
                    },
                }
            }
            (Some(busy), None) => {
                let place = cloud_place(None, &facts.account);
                Decision {
                    why: format!("this Mac is busy ({busy}): a new Cloud VM{}", hybrid_note(&place)),
                    place,
                    chip: "Auto · Cloud: this Mac is busy".into(),
                }
            }
            (Some(busy), Some(off)) => Decision {
                place: Place::ThisMac,
                why: format!(
                    "this Mac is busy ({busy}) and {}: it starts here anyway (load only warns)",
                    lower_first(off)
                ),
                chip: "Auto · This Mac: busy".into(),
            },
        },
        Mode::Cloud { size } => match cloud_off(&facts.account) {
            None => {
                let place = cloud_place(*size, &facts.account);
                let sized = size.map(|s| format!(" ({})", s.letter())).unwrap_or_default();
                Decision {
                    why: format!("Cloud picked: a new VM for this chat{sized}{}", hybrid_note(&place)),
                    place,
                    chip: format!("Cloud · New VM{sized}"),
                }
            }
            Some(off) => Decision {
                place: Place::Nowhere,
                why: format!("{off}: sign in, or pick Auto or a machine"),
                chip: "Cloud · unavailable".into(),
            },
        },
        Mode::Machine { id } if same(id, &local.name) => Decision {
            place: Place::ThisMac,
            why: "pinned to this Mac".into(),
            chip: "This Mac".into(),
        },
        Mode::Machine { id } if facts.machines.iter().any(|m| same(m, id)) => Decision {
            place: Place::Machine { id: id.clone() },
            why: format!("pinned to {id}"),
            chip: id.clone(),
        },
        Mode::Machine { id } => Decision {
            place: Place::Nowhere,
            why: format!("{id} is not connected: connect it, or pick Auto or another machine"),
            chip: format!("{id} · not connected"),
        },
    }
}

/// Machine names compare as placement compares them: any case, without `.local`.
fn same(a: &str, b: &str) -> bool {
    let c = |s: &str| {
        let s = s.trim().to_ascii_lowercase();
        s.strip_suffix(".local").map(str::to_owned).unwrap_or(s)
    };
    !a.trim().is_empty() && c(a) == c(b)
}

fn lower_first(s: &str) -> String {
    let mut chars = s.chars();
    chars.next().map(|c| c.to_lowercase().chain(chars).collect()).unwrap_or_default()
}

#[cfg(test)]
mod tests;
