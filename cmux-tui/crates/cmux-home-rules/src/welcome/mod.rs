//! The `welcome` area's ops: first run and the Chief's small tools.
//!
//! - [`script`]: the welcome's three messages, their pacing, the import request and the about text with
//!   the person's shortcuts (`ChiefWelcome`, `ChiefWelcome+Shortcuts`, `ChiefWelcomePlayer`'s steps).
//! - [`intro`]: which intro an empty Chief conversation shows and what showing it records
//!   (`ChiefIntroStore`, `ChiefIntroKind`), and whether the Switching card shows (`HomeSwitchKeysSource`).
//! - [`pet`]: each Chief's pet character (`ChiefMascotPicks`) and the pet's notice from a daemon
//!   notification (`ChiefPetNotice+Daemon`).
//! - [`views`]: the Chief view gallery's Fleet and Landing reads and its agent rows (`ChiefViewsFeeds`,
//!   `ChiefViewsAgent`).
//! - [`tools`]: the `optchat-chief` usage and memory tools' lookup and arguments (`ChiefUsageTool`,
//!   `ChiefMemoryTool`).
//! - [`memory`]: the Memory Inspector's rules and its answers' decoding (`ChiefMemoryInspectorModel`
//!   and its `ChiefMemory*` values).
//! - [`colors`]: each chat's own bubble colours (`HomeChatColorStore`, `HomeColor(hex:)`).
//! - [`attachments`]: the attachment cache's file names, thumbnail source and eviction
//!   (`HomeAttachmentCache`).
//!
//! I/O (defaults, files, processes, the network, timers) stays in Swift: it reads, asks the op, and does
//! what the reply says.

pub mod attachments;
pub mod colors;
pub mod intro;
pub mod memory;
pub mod pet;
pub mod script;
pub mod text;
pub mod tools;
pub mod views;

use crate::ops::OpError;
use serde_json::Value;

/// This area's op names (without the `welcome.` prefix).
pub const OPS: &[&str] = &[
    // script
    "beats",
    "typingTime",
    "readingPause",
    "playSteps",
    "importRequest",
    "shortcut",
    "shortcutActions",
    "aboutText",
    // intro
    "intro",
    "markShown",
    "switchKeys",
    // pet
    "mascotPicksLoad",
    "mascot",
    "mascotPicked",
    "mascotRemember",
    "petNotice",
    // views
    "fleetDataUrl",
    "validFleetUrl",
    "fleetReply",
    "landingSearchUrls",
    "searchDay",
    "landingPrs",
    "landingReply",
    "validPullRequestUrl",
    "agentRows",
    // tools
    "usageToolCandidates",
    "usageToolArgs",
    "usageToolFailure",
    "memoryToolPath",
    "memoryToolArgs",
    "memoryToolFailure",
    // memory
    "memoryDecode",
    "memoryReloadCalls",
    "memoryOpen",
    "memoryBack",
    "memorySearch",
    "memoryTextOf",
    "memoryChangeCall",
    "memoryUndoLast",
    "memoryIsStale",
    "memoryDescribe",
    "memoryTargetQuery",
    // colors
    "colorHex",
    "chatColorsLoad",
    "chatColorsSet",
    "chatColorsApply",
    "chatColorsFromHexes",
    "chatColorsSummary",
    // attachments
    "attachmentFileName",
    "attachmentThumbnailSource",
    "attachmentTrim",
];

/// Runs `welcome.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "beats" | "typingTime" | "readingPause" | "playSteps" | "importRequest" | "shortcut"
        | "shortcutActions" | "aboutText" => script::call(name, request),
        "intro" | "markShown" | "switchKeys" => intro::call(name, request),
        "mascotPicksLoad" | "mascot" | "mascotPicked" | "mascotRemember" | "petNotice" => {
            pet::call(name, request)
        }
        "fleetDataUrl"
        | "validFleetUrl"
        | "fleetReply"
        | "landingSearchUrls"
        | "searchDay"
        | "landingPrs"
        | "landingReply"
        | "validPullRequestUrl"
        | "agentRows" => views::call(name, request),
        "usageToolCandidates"
        | "usageToolArgs"
        | "usageToolFailure"
        | "memoryToolPath"
        | "memoryToolArgs"
        | "memoryToolFailure" => tools::call(name, request),
        "memoryDecode" | "memoryReloadCalls" | "memoryOpen" | "memoryBack" | "memorySearch"
        | "memoryTextOf" | "memoryChangeCall" | "memoryUndoLast" | "memoryIsStale"
        | "memoryDescribe" | "memoryTargetQuery" => memory::call(name, request),
        "colorHex"
        | "chatColorsLoad"
        | "chatColorsSet"
        | "chatColorsApply"
        | "chatColorsFromHexes"
        | "chatColorsSummary" => colors::call(name, request),
        "attachmentFileName" | "attachmentThumbnailSource" | "attachmentTrim" => {
            attachments::call(name, request)
        }
        _ => Err(OpError::Unknown),
    }
}
