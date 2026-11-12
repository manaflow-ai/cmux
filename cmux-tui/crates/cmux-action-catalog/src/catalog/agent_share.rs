// cmux NEXT action catalog data. Edit by hand: this is the source of truth.
//! The `AgentShareActionCatalog` actions.

use super::args;
use crate::model::*;
use crate::text::t;

const GROUP: &str = "AgentShareActionCatalog";

#[rustfmt::skip]
pub static ACTIONS: &[Action] = &[
    Action {
        id: "agent.share",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share", "Share Chat with Guest…"),
        description: Some("Makes a guest link to an agent chat (--target tab:<id>, --surface N, else the chat that runs the command, else the focused chat): the guest sees the chat as you do, including command output and the agent's reasoning, and each message they send waits for you. --ttl (seconds, or 30m, 24h, 7d; default 24h) and --uses (1 to 8; default 1). --role (view or talk) gives the link a role; a guest who opens it without signing in only watches either way. --signed-in-role (talk, the default, or view) says whether a guest signed in to cmux may also send. `cmux share chat --view-only` sends both as view: a link where nobody sends. Returns share_id, url (null when no share service is configured), expires_at (ms), uses_left, session and surface. Errors: share.needs_sign_in, share.room_unreachable (try again), share.room_refused, share.not_a_chat, share.limit."),
        keywords: &["share", "guest", "invite", "link", "multiplayer", "agent", "chat", "collaborate"],
        category: "agents",
        symbol: "person.badge.plus",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 590).label(t("ActionCatalog", "action.agent.share.menu", "Share with Guest…"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::SURFACE.optional(), args::TTL.optional(), args::USES.optional(), args::ROLE.optional(), args::SIGNED_IN_ROLE.optional()],
        targets: &["tab"],
        cli_name: "share chat",
        waits_for_result: true,
        waits_for_person: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agent.share.list",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share.list", "List Guest Links"),
        description: Some("Lists this Mac's guest links (all, or one chat's with --target tab:<id> or --surface N): shares, each with share_id, state (provisioning, active, revoked, expired, closed), session, surface, expires_at, expires_in_secs, uses_left, room, guests [{guest_id, name, joined_at, state, account?, role?}] and invitees [{account, role (view, talk), invited_at, state (invited, removed)}]. Never a link's secret."),
        keywords: &["share", "guest", "link", "list"],
        category: "agents",
        symbol: "list.bullet",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SURFACE.optional()],
        targets: &["tab"],
        cli_name: "share list",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agent.share.revoke",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share.revoke", "Revoke Guest Link"),
        description: Some("Ends a guest link (--share-id from `cmux share list`): it stops working and every guest on it leaves at once. Returns share_id and state."),
        keywords: &["share", "guest", "link", "revoke", "end", "stop"],
        category: "agents",
        symbol: "link.badge.minus",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SHARE_ID],
        cli_name: "share revoke",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agent.share.kick",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share.kick", "Remove Guest"),
        description: Some("Removes one guest (--share-id and --guest-id from `cmux share list`) from a guest link: their page ends and they cannot join again. Returns share_id, guest_id and state."),
        keywords: &["share", "guest", "remove", "kick"],
        category: "agents",
        symbol: "person.badge.minus",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::SHARE_ID, args::GUEST_ID],
        cli_name: "share kick",
        waits_for_result: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agent.share.invite",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share.invite", "Invite People to Chat…"),
        description: Some("Invites a cmux account (--account, an email or @handle; a person's own run without one opens the chat's Invite People sheet) to an agent chat (--target tab:<id>, --surface N, else the chat that runs the command, else the focused chat): once they sign in they see the chat as you do. --role talk (default: they may also send messages, each held for you) or view (watch only). Invites go on the chat's invite share, made first when the chat has none (--ttl, default 7d). Returns share_id, account, role, state and created_share. Errors: share.declined, share.invited (already invited with the other role: uninvite first), share.needs_sign_in, share.limit, share.not_a_chat, share.bad_request (not an email or @handle)."),
        keywords: &["share", "invite", "teammate", "people", "account", "email", "multiplayer", "agent", "chat", "collaborate"],
        category: "agents",
        symbol: "person.crop.circle.badge.plus",
        surfaces: PALETTE | CONTEXT_MENU,
        surface_plan: SurfacePlan { cli: Some(Decision::Offered), context_menus: &[Placement::at("tab", "identity", 591).label(t("ActionCatalog", "action.agent.share.invite.menu", "Invite People…"))], ..SurfacePlan::DEFAULT },
        arguments: &[args::ACCOUNT.optional(), args::ROLE.optional(), args::SURFACE.optional(), args::TTL.optional()],
        targets: &["tab"],
        cli_name: "share invite",
        waits_for_result: true,
        waits_for_person: true,
        ..Action::DEFAULT
    },
    Action {
        id: "agent.share.uninvite",
        group: GROUP,
        title: t("ActionCatalog", "action.agent.share.uninvite", "Remove Invited Person"),
        description: Some("Removes an invited cmux account (--account) from an agent chat's shares (--surface N or --target tab:<id>, else the chat that runs the command, else the focused chat; or one share with --share-id): it can no longer join, and every device it joined from leaves at once. Returns account, state and share_ids. Errors: share.not_invited."),
        keywords: &["share", "invite", "remove", "uninvite", "account"],
        category: "agents",
        symbol: "person.crop.circle.badge.minus",
        surface_plan: SurfacePlan { palette: Decision::Exempt("familyMember"), cli: Some(Decision::Offered), context_menu_exemption: Some("familyMember"), ..SurfacePlan::DEFAULT },
        arguments: &[args::ACCOUNT, args::SURFACE.optional(), args::SHARE_ID.optional()],
        targets: &["tab"],
        cli_name: "share uninvite",
        waits_for_result: true,
        ..Action::DEFAULT
    },
];
