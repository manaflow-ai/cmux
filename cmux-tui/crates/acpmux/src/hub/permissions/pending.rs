//! A person's switch to bypass also answers tool requests already waiting on that person.
use super::*;

impl Hub {
    /// A daemon default change applies only to chats inheriting that policy.
    pub(crate) async fn approve_pending_default_tools(&self) {
        for session in self.sessions() {
            if session.meta().permission_policy.is_none() && session.moving().is_none() {
                self.approve_pending_tools(&session).await;
            }
        }
    }

    pub(in crate::hub) async fn approve_pending_tools(&self, session: &Session) {
        let off = self.off_latch();
        // The local switch limits modes, not an explicit approve-all policy. MDM's forced
        // off still caps both, as it does when a new permission arrives.
        let mode_allowed = off.allows_full_access();
        let cfg = self.config.read().await;
        let replies = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            // Turn attestations take turn before meta; do not invert that order here.
            if Self::web_turn(session) {
                return;
            }
            // Use the same locks as a new permission request and policy edits. Keep the mode
            // locked through selection, so a concurrent harness drift cannot lend stale bypass.
            let policy = Self::stored_policy_for(session, cfg.permission_policy);
            let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let mode = full_access_mode(&meta).filter(|_| mode_allowed);
            if off.off()
                || policy == PermissionPolicy::DenyAll
                || (mode.is_none() && policy != PermissionPolicy::ApproveAll)
            {
                return;
            }
            let selected: Vec<_> = state
                .pending
                .iter()
                .filter_map(|(id, pending)| {
                    let request = &pending.request;
                    // Explicit rules still decide, and questions, plans and trust are still
                    // interactive. Never create a lasting harness grant from a mode switch.
                    if !super::super::permission_groups::plain_tool_ask(request)
                        || meta
                            .permission_rules
                            .as_ref()
                            .and_then(|rules| super::super::rules::decide(rules, request))
                            .is_some()
                    {
                        return None;
                    }
                    let option = super::super::permission_groups::option(request, "allow_once")?;
                    Some((id.clone(), option))
                })
                .collect();
            let mut approved = Vec::new();
            for (id, option) in selected {
                if off.off() {
                    break;
                }
                let Some(pending) = state.pending.remove(&id) else { continue };
                let outcome = json!({"outcome": "selected", "optionId": option});
                state.settled.remember(&id, None, &outcome);
                approved.push((id, option, pending, outcome));
            }
            drop(meta);
            let mut replies = Vec::new();
            for (id, option, pending, outcome) in approved {
                if let Some(group) = state.finish_item(&session.id, &id, false) {
                    self.append(session, "mux", "permission_group", json!({"group": group}));
                }
                let mut record = json!({
                    "permissionId": id, "policy": policy.to_string(), "optionId": option,
                    "request": pending.request, "rule": null, "chatAllowance": false,
                });
                if let Some(mode) = &mode {
                    record.set("fullAccess", json!(mode));
                }
                self.append(session, "mux", "permission_auto", record);
                replies.push((pending.reply, outcome));
            }
            replies
        };
        // The original request task writes permission_decision and restores the running state,
        // exactly as it does for a button answer. Clients therefore clear live and replayed cards.
        for (reply, outcome) in replies {
            let _ = reply.send(outcome);
        }
    }
}
