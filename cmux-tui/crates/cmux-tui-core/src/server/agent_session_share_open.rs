//! Opening a share: `agent-session-share-create` (a guest link) and
//! `agent-session-share-invite-chat` (an account invited to the chat on a surface, on the chat's
//! invite share, which it makes first when the chat has none). Both pin the chat's session, check
//! their terms before any record is made, and provision a new share in the hosted room with the
//! owner's token (`room::provision`).
//!
//! An invite-chat is one step under the shares lock: it finds the chat's invite share (the newest
//! active share of the session that has ever had an invitee; a guest link without any is the
//! link's own) and invites the account there, or makes a new share with the account already on
//! it. Any refusal (an account that is neither an email nor an `@handle`, another role already
//! invited, `share.limit`, a new share without the owner's token) changes nothing, so no share is
//! left open with nobody on it. A new share the room refuses or never answers ends with its
//! invite, as a link's create does. The new share's link secret is never answered: an invite share
//! is joined by account.

use super::*;
use zeroize::Zeroizing;

/// `agent-session-share-invite-chat`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct InviteChat {
    surface: u64,
    /// The session the caller saw on `surface` (`share.chat_moved` when it shows another by now).
    #[serde(default)]
    session: Option<String>,
    account: String,
    #[serde(default)]
    role: Option<Role>,
    /// How long a share this makes lasts (the longest a share may, by default); an existing share
    /// keeps its own.
    #[serde(default)]
    ttl_secs: Option<u64>,
    /// The caller's id for a share this makes (`LinkShare::create_id`).
    #[serde(default)]
    create_id: Option<String>,
    /// The owner's cmux token, spent only when a share is made in a hosted room.
    #[serde(default)]
    owner_token: Option<String>,
}

/// The ids a new share takes: its id, its link secret and its room provision key.
pub(super) struct NewIds(String, String, String);

impl NewIds {
    pub(super) fn draw() -> Result<Self, &'static str> {
        Ok(Self(token::<16>()?, token::<16>()?, token::<16>()?))
    }
}

/// A create's or an invite-chat's terms, checked: a TTL of 1 minute to 7 days, 1 to 8 uses (to
/// 1000 for a link made with a role, `view` or `talk`), and a `create_id` of 1 to 64 bytes when
/// there is one. Drive is never a link role.
fn terms(
    ttl_secs: u64,
    uses: u32,
    create_id: Option<String>,
    role: Option<Role>,
    signed_in_role: Option<Role>,
) -> Result<ShareTerms, &'static str> {
    let id_ok =
        create_id.as_ref().is_none_or(|id| !id.is_empty() && id.len() <= MAX_CREATE_ID_BYTES);
    if role == Some(Role::Drive)
        || signed_in_role == Some(Role::Drive)
        || !(MIN_TTL_SECS..=MAX_TTL_SECS).contains(&ttl_secs)
        || !(1..=if role.is_some() { MAX_LINK_USES } else { MAX_USES }).contains(&uses)
        || !id_ok
    {
        return Err("share.bad_request");
    }
    Ok(ShareTerms { ttl_secs, uses, create_id, role, signed_in_role, team_id: None })
}

/// The session `surface` shows, refused when the caller named another one.
fn chat(mux: &Mux, surface: u64, named: Option<&str>) -> Result<String, &'static str> {
    let session = tab_session(mux, surface).ok_or("share.not_a_chat")?;
    if named.is_some_and(|named| named != session) {
        return Err("share.chat_moved");
    }
    Ok(session)
}

/// Where a new share opens: `None` without a hosted room, else the room and the owner's token
/// (`share.needs_sign_in` without one, `share.room_unreachable` for a room configured wrong).
fn room_for_new(
    shares: &LinkShares,
    owner_token: Option<String>,
) -> Result<Option<(room::Room, Zeroizing<String>)>, &'static str> {
    if shares.bridge.invalid() {
        return Err("share.room_unreachable");
    }
    let Some(room) = shares.bridge.room() else { return Ok(None) };
    let token = owner_token.map(Zeroizing::new).filter(|t| !t.is_empty() && t.len() <= 8192);
    Ok(Some((room, token.ok_or("share.needs_sign_in")?)))
}

/// `agent-session-share-create`: a guest link or a team address. Team access needs a hosted room.
pub(super) fn create(
    mux: &Arc<Mux>,
    shares: &LinkShares,
    directory: Option<&Path>,
    p: Create,
) -> Result<Value, &'static str> {
    if let Some(team) = &p.team_id
        && (!valid_id(team)
            || !team.bytes().all(|byte| byte.is_ascii_graphic())
            || p.uses.is_some()
            || p.signed_in_role.is_some())
    {
        return Err("share.bad_request");
    }
    let mut terms = terms(
        p.ttl_secs.unwrap_or(DEFAULT_TTL_SECS),
        p.uses.unwrap_or(1),
        p.create_id,
        p.role,
        p.signed_in_role,
    )?;
    if p.team_id.is_some() {
        terms.role = Some(p.role.unwrap_or(Role::View));
        terms.team_id = p.team_id;
    }
    let session = chat(mux, p.surface, p.session.as_deref())?;
    match room_for_new(shares, p.owner_token)? {
        None if terms.team_id.is_some() => Err("share.room_unreachable"),
        None => shares.insert(directory, session, p.surface, terms, false),
        Some((room, token)) => {
            let created = shares.insert(directory, session, p.surface, terms, true)?;
            room::provision(mux, created, room, token)
        }
    }
}

/// `agent-session-share-invite-chat`: see the module's doc.
pub(super) fn invite_chat(
    mux: &Arc<Mux>,
    shares: &LinkShares,
    directory: Option<&Path>,
    p: InviteChat,
) -> Result<Value, &'static str> {
    let account = normal_account(&p.account)?;
    let role = p.role.unwrap_or(Role::Talk);
    let terms = terms(p.ttl_secs.unwrap_or(MAX_TTL_SECS), 1, p.create_id, None, None)?;
    let session = chat(mux, p.surface, p.session.as_deref())?;
    let ids = NewIds::draw()?;
    // Asked before the lock: the room a new share would open in, or why none may be made.
    let new_room = room_for_new(shares, p.owner_token);
    let connected = || shares.present();
    let (mut answer, made) = shares.with(directory, |all, now| {
        let existing = all
            .iter()
            .filter(|s| s.session == session && s.state == ShareState::Active)
            .filter(|s| !s.invitees.is_empty())
            // A team share admits by membership, never by a named invitation.
            .filter(|s| s.team_id.is_none())
            .max_by_key(|s| s.created_at)
            .map(|s| s.share_id.clone());
        let (made, share_id) = match existing {
            Some(share_id) => (None, share_id),
            None => {
                let provisioning = new_room.as_ref().map_err(|code| *code)?.is_some();
                let created = push(
                    all,
                    now,
                    &connected,
                    ids,
                    session.clone(),
                    p.surface,
                    terms,
                    provisioning,
                )?;
                let share_id =
                    created.get("share_id").and_then(Value::as_str).unwrap_or_default().to_owned();
                (Some(created), share_id)
            }
        };
        let fresh = made.is_some();
        // The chat's other shares that invite the account take the role too: one role per
        // person on a chat, however many invite shares it has.
        let others: Vec<String> = all
            .iter()
            .filter(|s| s.session == session && s.share_id != share_id && s.live().is_ok())
            .filter(|s| {
                s.invitees.iter().any(|i| i.account == account && i.state == InviteState::Invited)
            })
            .map(|s| s.share_id.clone())
            .collect();
        let (mut answer, mut changed) =
            invite_in(all, &share_id, account.clone(), role, now, &connected)?;
        for other in others {
            changed |= invite_in(all, &other, account.clone(), role, now, &connected)?.1;
        }
        answer.set("created_share", json!(fresh));
        let expires_at = find(all, &share_id)?.expires_at;
        answer.set("expires_at", json!(expires_at));
        Ok(((answer, made), changed || fresh))
    })?;
    if let (Some(created), Ok(Some((room, token)))) = (made, new_room) {
        let share_id =
            created.get("share_id").and_then(Value::as_str).unwrap_or_default().to_owned();
        // A refusal or no answer ends the share (and its invite) the way a link's create does.
        let provisioned = room::provision(mux, created, room, token)?;
        let invite_url = match provisioned.get("room").and_then(Value::as_str) {
            Some(origin) => json!(format!("{origin}/i/{share_id}")),
            None => Value::Null,
        };
        answer.set("invite_url", invite_url);
    }
    Ok(answer)
}

/// Adds a new share of `session` to `shares` (an ended one goes first when room is needed) and
/// returns its create result. Only a share with link access returns its secret.
#[allow(clippy::too_many_arguments)]
pub(super) fn push(
    shares: &mut Vec<LinkShare>,
    now: u64,
    connected: Connected<'_>,
    ids: NewIds,
    session: String,
    surface: u64,
    terms: ShareTerms,
    provisioning: bool,
) -> Result<Value, &'static str> {
    let ShareTerms { ttl_secs, uses, create_id, role, signed_in_role, team_id } = terms;
    let NewIds(share_id, secret, provision_key) = ids;
    if shares.len() >= MAX_SHARES {
        prune(shares);
    }
    if shares.len() >= MAX_SHARES {
        return Err("share.limit");
    }
    let expires_at = now.saturating_add(ttl_secs.saturating_mul(1000));
    shares.push(LinkShare {
        share_id: share_id.clone(),
        session: session.clone(),
        surface,
        created_at: now,
        expires_at,
        uses_left: uses,
        state: if provisioning { ShareState::Provisioning } else { ShareState::Active },
        secret_sha256: hex(&digest(&[&secret])),
        provision_key: Some(provision_key),
        create_id,
        room: None,
        pending_room_ops: Vec::new(),
        guests: Vec::new(),
        invitees: Vec::new(),
        requests: Vec::new(),
        role,
        signed_in_role,
        team_id: team_id.clone(),
    });
    // The records there may fit while the new one does not: ended ones go first.
    if !fits_or_prune(shares, now, connected) {
        return Err("share.limit");
    }
    let mut answer = json!({"share_id": share_id, "url": null, "expires_at": expires_at,
        "session": session, "surface": surface, "uses_left": uses, "role": role,
        "signed_in_role": signed_in_role});
    if let Some(team) = team_id {
        answer.set("team_id", json!(team));
    } else {
        answer.set("secret", json!(secret));
    }
    Ok(answer)
}

/// Invites `account` to share `share_id` of `shares` (see [`LinkShares::invite`]); answers the
/// invite and whether anything changed.
pub(super) fn invite_in(
    shares: &mut Vec<LinkShare>,
    share_id: &str,
    account: String,
    role: Role,
    now: u64,
    connected: Connected<'_>,
) -> Result<(Value, bool), &'static str> {
    let share = find(shares, share_id)?;
    if share.state != ShareState::Provisioning {
        share.live()?;
    }
    let answer = json!({"share_id": share.share_id, "account": account, "role": role,
        "state": InviteState::Invited, "invite_url": share.invite_url()});
    // An account the owner invites no longer asks: its request (pending or declined) goes.
    share.requests.retain(|r| r.account != account);
    if let Some(invitee) = share.invitees.iter_mut().find(|i| i.account == account) {
        if invitee.state == InviteState::Invited {
            if invitee.role == role {
                return Ok((answer, false));
            }
            // Another role: the invite keeps its place (the account never loses access on the
            // way), and the guests it joined as take the new role. Their connections close at
            // the next `settle` (`LinkShares::note_ended`), so each binds again with an author
            // of that role; none keeps one its role no longer matches.
            invitee.role = role;
            for guest in share.guests.iter_mut() {
                if guest.invited() && guest.account.as_ref() == Some(&account) {
                    guest.role = Some(role);
                }
            }
            return Ok((answer, true));
        }
        *invitee = Invitee {
            account: account.clone(),
            role,
            invited_at: now,
            state: InviteState::Invited,
        };
        retire_general_access_guests(share, &account, role);
        return Ok((answer, true));
    }
    retire_general_access_guests(share, &account, role);
    if share.team_id.is_none() && share.invitees.len() >= MAX_INVITEES {
        // Team shares keep removals: forgetting one would readmit the account through the team.
        share.invitees.retain(|i| i.state == InviteState::Invited);
    }
    if share.invitees.len() >= MAX_INVITEES {
        return Err("share.limit");
    }
    share.invitees.push(Invitee { account, role, invited_at: now, state: InviteState::Invited });
    if !fits_or_prune(shares, now, connected) {
        return Err("share.limit");
    }
    Ok((answer, true))
}

/// Inviting an account ends its previous link or team grants. The earlier connections close
/// at the next `settle`. A Drive invite preserves the old general-access attempt so it cannot
/// be replayed as accepting the invitation.
fn retire_general_access_guests(share: &mut LinkShare, account: &str, role: Role) {
    let general_access = |g: &Guest| g.via.is_some() && g.account.as_deref() == Some(account);
    for guest in share.guests.iter_mut().filter(|g| general_access(g)) {
        if guest.state == GuestState::Active {
            guest.state = GuestState::Left;
        }
        if role != Role::Drive {
            guest.attempt_id_sha256.clear();
        }
    }
}
