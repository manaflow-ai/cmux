// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `CloudTeamActionCatalog` actions: team Cloud sessions (cloud multiplayer). The team's Cloud
//! chats and workspaces as every member sees them, the `cmux://cloud/session|workspace/<team>/<vm>/<id>`
//! link, Follow, Reassign to and Archive, and a cloud group's members. The Team section's rows and
//! buttons, the workspace and tab menus, the palette, `cmux cloud …` and its MCP tools all run these;
//! the handlers are CmuxNextCloudUI's CloudTeamFeature+Actions.swift. A session is `--session` (its
//! `cloud:<team>/<vm>/<id>` key or its link), else the Cloud workspace or chat tab the run targets,
//! else the focused one. Every run answers its record (or the link) to the CLI and MCP.

use crate::model::*;
use crate::text::t;

const GROUP: &str = "CloudTeamActionCatalog";

/// `--session`: a `cloud:<team>/<vm>/<id>` key or a `cmux://cloud/…` link.
#[rustfmt::skip]
pub const SESSION: Argument = Argument { name: "session", title: t("ActionCatalog", "argument.cloudTeam.session", "Session or Link"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
const SCOPES: &[EnumCase] = &[EnumCase { value: "mine", title: t("ActionCatalog", "argument.cloudTeam.scope.mine", "Assigned to Me") }, EnumCase { value: "team", title: t("ActionCatalog", "argument.cloudTeam.scope.team", "Team") }, EnumCase { value: "following", title: t("ActionCatalog", "argument.cloudTeam.scope.following", "Following") }];
#[rustfmt::skip]
pub const SCOPE: Argument = Argument { name: "scope", title: t("ActionCatalog", "argument.cloudTeam.scope", "Show"), kind: ArgKind::Enumeration(SCOPES), required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const BY: Argument = Argument { name: "by", title: t("ActionCatalog", "argument.cloudTeam.by", "Assigned To"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
/// The list's `--archived`, and Archive's (default true; false brings the session back).
#[rustfmt::skip]
pub const ARCHIVED: Argument = Argument { name: "archived", title: t("ActionCatalog", "argument.cloudTeam.archived", "Archived"), kind: ArgKind::Bool, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const CURSOR: Argument = Argument { name: "cursor", title: t("ActionCatalog", "argument.cloudTeam.cursor", "Cursor"), kind: ArgKind::String, required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const LIMIT: Argument = Argument { name: "limit", title: t("ActionCatalog", "argument.cloudTeam.limit", "Limit"), kind: ArgKind::Int(Some((1, 200))), required: false, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const TO: Argument = Argument { name: "to", title: t("ActionCatalog", "argument.cloudTeam.to", "Teammate"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const GROUP_ID: Argument = Argument { name: "group", title: t("ActionCatalog", "argument.cloudTeam.group", "Group"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
pub const USER: Argument = Argument { name: "user", title: t("ActionCatalog", "argument.cloudTeam.user", "Member"), kind: ArgKind::String, required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };
#[rustfmt::skip]
const ROLES: &[EnumCase] = &[EnumCase { value: "owner", title: t("ActionCatalog", "argument.cloudTeam.role.owner", "Owner") }, EnumCase { value: "edit", title: t("ActionCatalog", "argument.cloudTeam.role.edit", "Can edit") }, EnumCase { value: "view", title: t("ActionCatalog", "argument.cloudTeam.role.view", "Can view") }];
#[rustfmt::skip]
pub const ROLE: Argument = Argument { name: "role", title: t("ActionCatalog", "argument.cloudTeam.role", "Role"), kind: ArgKind::Enumeration(ROLES), required: true, suggestions: None, is_target_name: false, is_target_description: false, is_supplied_by_target: false, asked_in_palette: false };

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "cloud.team.sessions",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.sessions", "List Team Cloud Sessions"),
        description: Some("Lists the team's Cloud chats and workspaces, newest activity first: --scope mine (assigned to you), team (default: everyone's) or following; --by USER (assigned to that member); --archived (the archived ones instead); --limit 1-200 (default 50) and --cursor from next_cursor. Returns team, sessions [{key, vm, session, kind (chat, workspace), title, owner, owner_name, assignee, assignee_name, machine_state (running, asleep, waking, unresponsive, gone), activity (working, needs_attention, idle), last_activity_at (ms), created_at, archived, followers [USER], follower_count, following, assigned_to_you, viewers [USER] (who has it open now), can_reassign, can_archive, link}] and next_cursor. Errors: cloud.signed_out, auth.forbidden (not a member of the team, or a guest), validation.invalid, cloud.unreachable."),
        keywords: &["team", "cloud", "sessions", "workspaces", "chats", "shared", "teammates", "multiplayer"],
        category: "cloud",
        symbol: "person.2",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[SCOPE, BY, ARCHIVED, CURSOR, LIMIT],
        cli_name: "cloud team-sessions",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.session",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.session", "Show Team Cloud Session"),
        description: Some("Reads one team Cloud session (--session KEY|LINK, else the targeted or focused Cloud workspace or chat). Returns session, shaped as one row of cloud team-sessions. Errors: selector.not_found or cloud_session.not_found (closed or removed), cloud_session.not_cloud (the target is not a Cloud workspace or chat), cloud_session.invalid (--session is not a key or link), auth.forbidden or team.not_member, cloud.signed_out, cloud.unreachable."),
        keywords: &["team", "cloud", "session", "status", "who"],
        category: "cloud",
        symbol: "person.2",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[SESSION],
        targets: &["workspace", "tab"],
        cli_name: "cloud team-session",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.copyLink",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.copyLink", "Copy Cloud Session Link"),
        description: Some("Copies the link to a team Cloud session (--session, else the targeted or focused Cloud workspace or chat tab): cmux://cloud/workspace/TEAM/VM/WORKSPACE for a workspace, cmux://cloud/session/TEAM/VM/SESSION for a chat. Any member of the team opens it with `cmux link open`; anyone else is refused. Returns link, key (cloud:TEAM/VM/ID), kind and copied (false for a script's run, which prints it instead). Errors: cloud_session.not_cloud, cloud.signed_out."),
        keywords: &["link", "url", "copy", "share", "cloud", "team", "teammate"],
        category: "cloud",
        symbol: "link",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "inspect", 406).folder("copy"), Placement::at("tab", "inspect", 502).folder("copy")], ..SurfacePlan::DEFAULT },
        arguments: &[SESSION],
        targets: &["workspace", "tab"],
        cli_name: "cloud copy-session-link",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.follow",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.follow", "Follow"),
        description: Some("Follows a team Cloud session (--session, else the targeted or focused Cloud workspace or chat): it shows under Following in the Team section for you on every Mac. Following twice is a no-op. Returns session. Errors: cloud_session.assigned_to_you (your own work is already yours), cloud_session.not_found, cloud_session.not_cloud, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["follow", "watch", "eye", "team", "cloud", "subscribe"],
        category: "cloud",
        symbol: "eye",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 312).folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[SESSION],
        targets: &["workspace", "tab"],
        cli_name: "cloud follow",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.unfollow",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.unfollow", "Unfollow"),
        description: Some("Stops following a team Cloud session (--session, else the targeted or focused one). Unfollowing one you do not follow is a no-op. Returns session. Errors: as cloud follow."),
        keywords: &["unfollow", "stop watching", "eye", "team", "cloud"],
        category: "cloud",
        symbol: "eye.slash",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("workspaceRow", "identity", 313).folder("options")], ..SurfacePlan::DEFAULT },
        arguments: &[SESSION],
        targets: &["workspace", "tab"],
        cli_name: "cloud unfollow",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.reassign",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.reassign", "Reassign to…"),
        description: Some("Moves a team Cloud session (--session, else the targeted or focused one) to another member's assigned work (--to USER, a member's user id from cloud team-members or a row's owner). Its owner (who pays for the machine) does not change; followers keep following, and the previous assignee follows it. Only its assignee, its owner or a team admin may; a turn that is running goes on. Returns session. Errors: cloud_session.not_yours, cloud_session.assignee_not_member (a guest or someone outside the team), cloud_session.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["reassign", "assign", "hand off", "handoff", "transfer", "teammate", "team", "cloud"],
        category: "cloud",
        symbol: "person.crop.circle.badge.arrow.forward",
        surfaces: PALETTE,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[SESSION, TO],
        targets: &["workspace", "tab"],
        cli_name: "cloud reassign",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.archive",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.archive", "Archive Cloud Session"),
        description: Some("Archives a team Cloud session for the whole team (--session, else the targeted or focused one), or brings it back with --archived false. Its machine and files are untouched. Only its assignee, its owner or a team admin may. Returns session. Errors: cloud_session.not_yours, cloud_session.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["archive", "unarchive", "hide", "team", "cloud"],
        category: "cloud",
        symbol: "archivebox",
        surfaces: PALETTE,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        arguments: &[SESSION, ARCHIVED],
        targets: &["workspace", "tab"],
        cli_name: "cloud archive-session",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.showSection",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.showSection", "Show Team Section"),
        description: Some("Adds the Team section to the bottom of the sidebar: the team's Cloud workspaces and chats under Assigned to Me, Team, Following and Archived, each with its follow (eye) toggle and a menu with Reassign To, Copy Link and Archive. A sidebar that has it already keeps the one it has. Errors: cloud.signed_out."),
        keywords: &["team", "cloud", "sidebar", "section", "sessions", "shared"],
        category: "cloud",
        symbol: "person.2",
        surfaces: PALETTE,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menu_exemption: Some("noTargetSurface"), ..SurfacePlan::DEFAULT },
        cli_name: "cloud show-team-section",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.team.members",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.team.members", "List Team Members"),
        description: Some("Lists the members a team Cloud session can be reassigned to: members [{user, name, role (owner, admin, member, billing, guest), you}] of the active team, guests last. Errors: auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["team", "members", "people", "teammates"],
        category: "cloud",
        symbol: "person.3",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        cli_name: "cloud team-members",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.group.members",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.group.members", "List Cloud Group Members"),
        description: Some("Lists a cloud group's members (--group grp_…): group and members [{user, role (owner, edit, view), display_name, active (false for someone no longer in the team)}], owners first. Errors: group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["group", "members", "people", "roles"],
        category: "cloud",
        symbol: "person.3",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[GROUP_ID],
        cli_name: "cloud group-members",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.group.memberSet",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.group.memberSet", "Add Cloud Group Member"),
        description: Some("Adds a team member to a cloud group, or changes their role (--group grp_… --user USER --role owner|edit|view). Only a group owner may; the last owner cannot step down. Returns group. Errors: group.member_not_in_team (a guest or someone outside the team), group.last_owner, group.too_many_members (200), group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["group", "member", "add", "role", "share"],
        category: "cloud",
        symbol: "person.badge.plus",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[GROUP_ID, USER, ROLE],
        cli_name: "cloud group-member-set",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "cloud.group.memberRemove",
        group: GROUP,
        title: t("ActionCatalog", "action.cloud.group.memberRemove", "Remove Cloud Group Member"),
        description: Some("Removes a member from a cloud group (--group grp_… --user USER); anyone may remove themselves, only an owner may remove someone else, and the last owner stays. Returns group and removed. Errors: group.last_owner, group.not_found, auth.forbidden, cloud.signed_out, cloud.unreachable."),
        keywords: &["group", "member", "remove", "leave"],
        category: "cloud",
        symbol: "person.badge.minus",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[GROUP_ID, USER],
        cli_name: "cloud group-member-remove",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
