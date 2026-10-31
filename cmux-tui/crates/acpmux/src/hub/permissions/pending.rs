//! A person's switch to bypass also answers tool requests already waiting on that person.
use super::*;

impl Hub {
    pub(in crate::hub) async fn approve_pending_tools(&self, session: &Session) {
        let off = self.off_latch();
        if !off.allows_full_access() {
            return;
        }
        let cfg = self.config.read().await;
        let replies = {
            let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            // Use the same locks as a new permission request and policy edits. Keep the mode
            // locked through selection, so a concurrent harness drift cannot lend stale bypass.
            let policy = Self::stored_policy_for(session, cfg.permission_policy);
            let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let mode = full_access_mode(&meta);
            if off.off()
                || Self::web_turn(session)
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
                let pending = state.pending.remove(&id).unwrap();
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
