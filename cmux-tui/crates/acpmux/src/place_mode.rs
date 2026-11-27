//! Where a new chat starts: its place mode (Auto, Cloud, or one machine), this Mac's room, and
//! the account, to one answer and a short why (Leo, 2026-11-24: "let's just use our existing
//! dropdown and have it be able to have a chevron that opens into more options for... our options
//! we want to serve for cloud"; "ab that + the cloud thing bc we have multi cloud even thought it's
//! auto.. ish."). Pure: the caller reads the placement verdict (`_acpmux/place`, [`placement`])
//! and the account, and starts the chat where [`decide`] says.
//!
//! The modes ([`PlaceMode`]):
//! - `Auto`, every new chat's mode unless the person picks another for that chat, in [`Tier`]
//!   order: this Mac when placement says it has room and it fits the work; else a machine its
//!   owner enrolled in AutoCloud ([`crate::autocloud_enroll`]) that is accepting (owner away,
//!   inside its hours), whose policy allows this work and that fits it, the folder already
//!   there first, then the most room; else a new Cloud VM (our pool, then Freestyle, as the
//!   Cloud start picks; a hybrid start where [`hybrid::enabled`] says so). Never a machine that
//!   is not enrolled: plain Remote stays as it was. Work that needs a Mac ([`MAC_CAPS`]) never
//!   goes to the cloud: enrolled Macs are its tier. With Cloud off or signed out, this Mac all
//!   the same: placement's load and caps only warn.
//! - `Cloud`: a new Cloud VM for this chat. The person picks no size (Leo, 2026-11-24: "i mean
//!   cloud only idk if we even want a choice tho. do we ?"); the Cloud start sizes it as it
//!   sizes Auto's.
//! - `Machine { id }`: that machine, pinned; one that is not connected starts nothing.
//!
//! A pick is the chat's own pin and never becomes the default: `_acpmux/chat_place_set` keeps it
//! per chat, and a chat with none is Auto.
//!
//! [`placement`]: crate::placement

use serde::{Deserialize, Serialize};
use serde_json::Value;

use cmux_cloud_start_core::hybrid::{self, Account};

use crate::autocloud_enroll::{MAC_CAPS, Report};

/// A chat's place mode. On the wire `{"mode": "auto"}`, `{"mode": "cloud"}` or
/// `{"mode": "machine", "machine": ID}`; stored per chat as its pin.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "kebab-case")]
pub enum PlaceMode {
    #[default]
    Auto,
    Cloud,
    Machine {
        #[serde(rename = "machine")]
        id: String,
    },
}

impl PlaceMode {
    /// The mode a picker row sends ([`PlaceMode`]'s wire shape); other keys in `params` are
    /// ignored. `Err` says what is wrong.
    pub fn from_params(params: &Value) -> Result<Self, String> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).map(str::trim);
        match text("mode") {
            Some("auto") => Ok(Self::Auto),
            Some("cloud") => Ok(Self::Cloud),
            Some("machine") => match text("machine") {
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
    /// What it can run ([`crate::autocloud_enroll::caps_now`]). Empty: unread, so it fits any
    /// work, as before.
    pub caps: Vec<String>,
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
        caps: Report::of_health(row).caps,
    }
}

/// The enrolled machines in a `_acpmux/place` verdict: every other host row that carries an
/// `autoCloud` block (`placement.rs` copies it from the machine's own health), less those
/// placement turns away for load, room or swap. A verdict from an older acpmux has no such
/// block: none, and Auto is what it was. The folder is not in the verdict; a caller that knows
/// it sets [`EnrolledMachine::folder`].
pub fn enrolled_of(verdict: &Value) -> Vec<EnrolledMachine> {
    let rows = verdict.get("hosts").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    rows.iter()
        .filter(|h| h.get("local") != Some(&Value::Bool(true)))
        .filter(|h| h.get("load") != Some(&Value::Bool(true)))
        .filter(|h| h.get("autoCloud").is_some_and(Value::is_object))
        .filter_map(|h| {
            Some(EnrolledMachine {
                name: h.get("name")?.as_str()?.to_owned(),
                auto_cloud: Report::of_health(h),
                room: h.get("room").and_then(Value::as_f64),
                ram_free: h.get("ramFree").and_then(Value::as_f64),
                folder: false,
            })
        })
        .collect()
}

/// A machine its owner enrolled in AutoCloud, as the placer weighs it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EnrolledMachine {
    pub name: String,
    /// Its `autoCloud` health block.
    pub auto_cloud: Report,
    /// Its room in lanes and free RAM, from the placement verdict's row for it, when read.
    pub room: Option<f64>,
    pub ram_free: Option<f64>,
    /// Whether the chat's folder is already there.
    pub folder: bool,
}

/// What the work needs and whose it is.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Need {
    /// Capabilities it needs ([`Report::caps`]'s words).
    pub caps: Vec<String>,
    /// The team the work is for; None: the person's own.
    pub team: Option<String>,
    /// The agent (harness) that runs it.
    pub agent: Option<String>,
}

impl Need {
    fn needs_mac(&self) -> bool {
        self.caps.iter().any(|c| MAC_CAPS.iter().any(|m| m.eq_ignore_ascii_case(c)))
    }
}

/// Auto's placement order, first to last.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Tier {
    /// This Mac.
    ThisMac,
    /// The person's or team's enrolled machines: idle, allowed and fit.
    Enrolled,
    /// A new Cloud VM: our pool, then Freestyle (the Cloud start's provider order).
    Cloud,
}

/// What [`decide`] weighs.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    pub local: Local,
    pub account: Account,
    /// The machines a pinned chat may start on now (connected), by id.
    pub machines: Vec<String>,
    /// Connected machines whose health carries an `autoCloud` block (enrolled or not; Auto
    /// weighs only the accepting ones).
    pub enrolled: Vec<EnrolledMachine>,
    /// What the work needs.
    pub need: Need,
}

/// Where the chat starts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "kebab-case")]
pub enum Place {
    ThisMac,
    /// A new Cloud VM. `hybrid`: the chat answers here while it boots, then moves there.
    Cloud {
        hybrid: bool,
    },
    Machine {
        id: String,
    },
    /// Nothing starts; `why` says what to pick instead.
    Nowhere,
}

/// [`decide`]'s answer: where, why, the composer chip's line, and Auto's tier.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    pub place: Place,
    pub why: String,
    pub chip: String,
    /// The [`Tier`] Auto placed it in; None for a picked mode or nowhere. An older reader
    /// without it reads the rest as before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier: Option<Tier>,
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

fn cloud_place(account: &Account) -> Place {
    Place::Cloud { hybrid: hybrid::enabled(account).is_ok() }
}

fn hybrid_note(place: &Place) -> &'static str {
    match place {
        Place::Cloud { hybrid: true, .. } => ", answering here while it boots",
        _ => "",
    }
}

/// Where a new chat in `mode` starts, given `facts`, and why.
pub fn decide(mode: &PlaceMode, facts: &Facts) -> Decision {
    let local = &facts.local;
    match mode {
        PlaceMode::Auto => auto(facts),
        PlaceMode::Cloud => match cloud_off(&facts.account) {
            None => {
                let place = cloud_place(&facts.account);
                Decision {
                    why: format!("Cloud picked: a new VM for this chat{}", hybrid_note(&place)),
                    place,
                    chip: "Cloud · New VM".into(),
                    tier: None,
                }
            }
            Some(off) => Decision {
                place: Place::Nowhere,
                why: format!("{off}: sign in, or pick Auto or a machine"),
                chip: "Cloud · unavailable".into(),
                tier: None,
            },
        },
        PlaceMode::Machine { id } if same(id, &local.name) => Decision {
            place: Place::ThisMac,
            why: "pinned to this Mac".into(),
            chip: "This Mac".into(),
            tier: None,
        },
        PlaceMode::Machine { id } if facts.machines.iter().any(|m| same(m, id)) => Decision {
            place: Place::Machine { id: id.clone() },
            why: format!("pinned to {id}"),
            chip: id.clone(),
            tier: None,
        },
        PlaceMode::Machine { id } => Decision {
            place: Place::Nowhere,
            why: format!("{id} is not connected: connect it, or pick Auto or another machine"),
            chip: format!("{id} · not connected"),
            tier: None,
        },
    }
}

/// Auto, in [`Tier`] order: this Mac, an enrolled machine, a new Cloud VM.
fn auto(facts: &Facts) -> Decision {
    let (local, need) = (&facts.local, &facts.need);
    let here_fits = local.caps.is_empty()
        || need.caps.iter().all(|n| local.caps.iter().any(|c| c.eq_ignore_ascii_case(n)));
    if local.busy.is_none() && here_fits {
        let room = free(local);
        return Decision {
            place: Place::ThisMac,
            why: match local.room {
                Some(r) => format!("this Mac has room (for {r:.0} more)"),
                None => "this Mac's room is not read, so it starts here".into(),
            },
            chip: match room {
                Some(room) => format!("Auto · This Mac: {room}"),
                None => "Auto · This Mac".into(),
            },
            tier: Some(Tier::ThisMac),
        };
    }
    let not_here = match &local.busy {
        _ if !here_fits => format!("this Mac cannot run it (it needs {})", need.caps.join(", ")),
        Some(busy) => format!("this Mac is busy ({busy})"),
        None => "this Mac cannot run it".into(),
    };
    if let Some(m) = best_enrolled(facts) {
        let folder = if m.folder { ", the folder already there" } else { "" };
        return Decision {
            place: Place::Machine { id: m.name.clone() },
            why: format!("{not_here}: {}, enrolled in AutoCloud and idle{folder}", m.name),
            chip: match m.ram_free {
                Some(b) => format!("Auto · {}: {:.0} GB free", m.name, b / GB),
                None => format!("Auto · {}", m.name),
            },
            tier: Some(Tier::Enrolled),
        };
    }
    let starts_here_anyway = |why: String, chip: &str| Decision {
        place: Place::ThisMac,
        why,
        chip: chip.into(),
        tier: Some(Tier::ThisMac),
    };
    if need.needs_mac() {
        // No cloud runs Mac work: enrolled Macs are its tier.
        return if here_fits {
            starts_here_anyway(
                format!(
                    "{not_here} and no enrolled Mac is free: it starts here anyway (load only warns)"
                ),
                "Auto · This Mac: busy",
            )
        } else {
            Decision {
                place: Place::Nowhere,
                why: format!("{not_here} and no enrolled Mac is free: enroll a Mac or pick one"),
                chip: "Auto · needs a Mac".into(),
                tier: None,
            }
        };
    }
    match cloud_off(&facts.account) {
        None => {
            let place = cloud_place(&facts.account);
            Decision {
                why: format!("{not_here}: a new Cloud VM{}", hybrid_note(&place)),
                place,
                chip: if here_fits {
                    "Auto · Cloud: this Mac is busy".into()
                } else {
                    "Auto · Cloud".into()
                },
                tier: Some(Tier::Cloud),
            }
        }
        Some(off) if here_fits => starts_here_anyway(
            format!("{not_here} and {}: it starts here anyway (load only warns)", lower_first(off)),
            "Auto · This Mac: busy",
        ),
        Some(off) => Decision {
            place: Place::Nowhere,
            why: format!("{not_here} and {}: sign in, or pick a machine", lower_first(off)),
            chip: "Auto · unavailable".into(),
            tier: None,
        },
    }
}

/// The enrolled machine Auto picks: accepting, its policy allowing this work, fitting it, with
/// room; the folder already there first, then the most room, then by name.
fn best_enrolled(facts: &Facts) -> Option<&EnrolledMachine> {
    let need = &facts.need;
    let mut fit: Vec<&EnrolledMachine> = facts
        .enrolled
        .iter()
        .filter(|m| !same(&m.name, &facts.local.name))
        .filter(|m| m.auto_cloud.enrolled && m.auto_cloud.accepting)
        .filter(|m| m.auto_cloud.policy.allows(need.team.as_deref(), need.agent.as_deref()))
        .filter(|m| m.auto_cloud.fits(&need.caps))
        .filter(|m| m.room.is_none_or(|r| r > 0.0))
        .collect();
    fit.sort_by(|a, b| {
        b.folder
            .cmp(&a.folder)
            .then(b.room.unwrap_or(0.0).total_cmp(&a.room.unwrap_or(0.0)))
            .then_with(|| a.name.cmp(&b.name))
    });
    fit.first().copied()
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
