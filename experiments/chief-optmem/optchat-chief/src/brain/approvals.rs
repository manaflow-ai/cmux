//! A remote-origin turn's approvals (README "Remote-origin messages"): the
//! turn session's permission requests, answered at once for the memory
//! tools and otherwise asked in the Chief chat; each answer is recorded in
//! the trace with the approving device.

use cmux_conversation::{Message, Origin};
use serde_json::{Value, json};

use super::{Brain, reply_entry};
use crate::approval::{Answer, Pending, is_memory_tool, option_for, question, tool_name};

impl Brain {
    /// Whether `session_id` is the running turn's session.
    pub(super) fn is_turn_session(&self, session_id: &str) -> bool {
        self.state
            .turn
            .as_ref()
            .and_then(|t| t.session_id.as_deref())
            == Some(session_id)
    }

    /// A permission request of the running turn's session.
    pub(super) fn turn_permission(
        &mut self,
        session_id: String,
        permission_id: String,
        request: Value,
    ) {
        let tool = tool_name(&request);
        if is_memory_tool(&request) {
            // Reading the memory has no local effect.
            let option = option_for(&request, Answer::Allow);
            if let Err(e) =
                self.agents
                    .respond_permission(&session_id, &permission_id, option.as_deref())
            {
                (self.log)(&format!("allowing {tool}: {e}"));
            }
            return;
        }
        if !self.turn_ask {
            (self.log)(&format!(
                "turn session asked for {tool} outside an ask turn; left to its harness"
            ));
            return;
        }
        let pending = Pending {
            session_id,
            permission_id,
            tool,
            request,
            child: None,
        };
        let key = format!(
            "approval:{}:{}",
            self.state.turn.as_ref().map_or("", |t| t.key.as_str()),
            pending.permission_id
        );
        self.ask_person(pending, &key);
    }

    /// A permission request of a child that runs with policy `ask` (spawned
    /// under the ask floor): asked in the Chief chat with the child's name,
    /// never answered by the Chief itself.
    pub(super) fn child_permission(
        &mut self,
        child: &cmux_chief::acp::SessionSummary,
        permission_id: String,
        request: Value,
    ) {
        let key = format!("approval:{}:{}", child.session_id, permission_id);
        let pending = Pending {
            session_id: child.session_id.clone(),
            permission_id,
            tool: tool_name(&request),
            request,
            child: Some(child.name.clone()),
        };
        self.ask_person(pending, &key);
    }

    fn ask_person(&mut self, pending: Pending, key: &str) {
        let text = question(&pending);
        self.approvals.push_back(pending);
        if let Some(conversation) = self.state.conversation.clone() {
            self.state.outbox.push(reply_entry(conversation, key, &text));
            self.save();
            self.flush_outbox();
        }
    }

    /// Whether a child that runs with policy `ask` is still live: the spawn
    /// floor stays `ask` while one is (anything it spawns asks too).
    pub(super) fn ask_child_live(&self) -> bool {
        use cmux_chief::acp::SessionStatus;
        self.sessions.values().any(|s| {
            s.tags.get(crate::approval::POLICY_TAG).map(String::as_str) == Some(crate::approval::ASK)
                && !matches!(s.status, SessionStatus::Closed | SessionStatus::Disconnected)
        })
    }

    /// The policy floor for a child spawned now (`chief agents spawn` asks
    /// the host): `ask` during an ask turn or while an ask child is live,
    /// unless the Mac turned on remote.autoApprove.
    pub fn spawn_policy(&self) -> Option<&'static str> {
        if self.chief.remote_auto_approve {
            return None;
        }
        (self.turn_ask || self.ask_child_live()).then_some(crate::approval::ASK)
    }

    /// Drops the running turn's own pending approvals (its session ends);
    /// children's stay.
    pub(super) fn clear_turn_approvals(&mut self) {
        self.approvals.retain(|p| p.child.is_some());
    }

    /// A person answered the oldest pending approval with `message`.
    pub(super) fn answer_approval(&mut self, answer: Answer, message: &Message) {
        let Some(pending) = self.approvals.pop_front() else {
            return;
        };
        let install = message
            .origin
            .as_ref()
            .map(|Origin::Remote { install }| install.clone());
        self.respond(&pending, answer, &message.author, install.as_deref());
    }

    /// Denies the running turn's pending approvals (`why` is the trace's
    /// approver); children's stay for a person.
    pub(super) fn deny_pending(&mut self, why: &str) {
        let (turn, children): (Vec<Pending>, Vec<Pending>) =
            self.approvals.drain(..).partition(|p| p.child.is_none());
        self.approvals.extend(children);
        for pending in turn {
            self.respond(&pending, Answer::Deny, why, None);
        }
    }

    fn respond(
        &mut self,
        pending: &Pending,
        answer: Answer,
        approver: &str,
        install: Option<&str>,
    ) {
        let option = option_for(&pending.request, answer);
        let result = self.agents.respond_permission(
            &pending.session_id,
            &pending.permission_id,
            option.as_deref(),
        );
        (self.log)(&format!(
            "approval {}: {} {} by {approver}{}",
            pending.permission_id,
            answer.as_str(),
            pending.tool,
            match &result {
                Ok(()) => String::new(),
                Err(e) => format!(" (not delivered: {e})"),
            }
        ));
        if let Some(dir) = &self.settings.trace_dir {
            let fields = json!({
                "turn": self.state.turn.as_ref().map(|t| t.key.clone()),
                "session": pending.session_id,
                "permission": pending.permission_id,
                "tool": pending.tool,
                "child": pending.child,
                "decision": answer.as_str(),
                "option": option,
                "approver": approver,
                "install": install,
                "delivered": result.is_ok(),
            });
            if let Err(e) = crate::approval::record(dir, fields) {
                (self.log)(&format!("recording an approval in the trace: {e}"));
            }
        }
    }
}
