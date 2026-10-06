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
        };
        let text = question(&pending);
        let key = format!(
            "approval:{}:{}",
            self.state.turn.as_ref().map_or("", |t| t.key.as_str()),
            pending.permission_id
        );
        self.approvals.push_back(pending);
        if let Some(conversation) = self.state.conversation.clone() {
            self.state
                .outbox
                .push(reply_entry(conversation, &key, &text));
            self.save();
            self.flush_outbox();
        }
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

    /// Denies every pending approval (`why` is the trace's approver).
    pub(super) fn deny_pending(&mut self, why: &str) {
        while let Some(pending) = self.approvals.pop_front() {
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
