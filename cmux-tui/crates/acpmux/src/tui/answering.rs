//! The answer flow for a pending agent question. Every allow entry point
//! (y, digits, Action::Allow, the Allow button) on a question opens it
//! instead of sending a blank allow: the card shows one item at a time,
//! digits pick (a single select advances; a multi select toggles), Up/Down
//! and Space move and toggle, Enter confirms the item (typed composer text
//! becomes the Other answer), Esc leaves without answering. After the last
//! item the flow sends `permission_respond` with the harness-shaped answers.

use super::*;
use crate::question_answer::{self, Choice};

/// One question being answered in the composer.
#[derive(Debug, Clone)]
pub struct Answering {
    pub session: String,
    pub permission: String,
    pub allow_option: String,
    /// The normalized question (`toolCall._meta.acpmux.question`).
    pub question: Value,
    /// The active item.
    pub item: usize,
    /// The highlighted option of the active item.
    pub highlight: usize,
    /// The active multi-select item's toggled options.
    pub picked: Vec<usize>,
    /// Confirmed items, in order.
    pub choices: Vec<Choice>,
}

impl Answering {
    pub fn active(&self) -> Option<&Value> {
        question_answer::items(&self.question).get(self.item)
    }

    fn option_count(&self) -> usize {
        self.active().and_then(|i| i["options"].as_array()).map_or(0, Vec::len)
    }

    fn multi(&self) -> bool {
        self.active().and_then(|i| i["multiSelect"].as_bool()).unwrap_or(false)
    }
}

impl App {
    /// The selected session's pending question: (permission id, its
    /// options, the question).
    fn pending_question(&self) -> Option<(String, Vec<(String, String, String)>, Value)> {
        let id = self.selected_id()?;
        match self.transcripts.get(&id)?.pending_permission()? {
            Item::Permission { id, options, question: Some(question), .. } => {
                Some((id.clone(), options.clone(), question.clone()))
            }
            _ => None,
        }
    }

    /// The flow, while it still belongs to the selected session's pending
    /// permission; a flow whose question was answered elsewhere is dropped.
    pub(super) fn live_answering(&mut self) -> Option<&mut Answering> {
        let current = self.pending_question().map(|(pid, ..)| pid);
        let selected = self.selected_id();
        let live = self.answering.as_ref().is_some_and(|a| {
            Some(&a.permission) == current.as_ref() && Some(&a.session) == selected.as_ref()
        });
        if !live {
            self.answering = None;
        }
        self.answering.as_mut()
    }

    /// Routes a permission choice on a pending question. Returns false when
    /// the pending permission is not a question or the choice declines it,
    /// so `answer_permission` handles it as before. In the flow, an index
    /// picks an option of the active item and Allow confirms the item.
    pub(super) fn question_choice(&mut self, choice: &PermChoice) -> bool {
        let Some((pid, options, question)) = self.pending_question() else {
            self.answering = None;
            return false;
        };
        let flowing = self.live_answering().is_some();
        let declines = match choice {
            PermChoice::Deny => true,
            PermChoice::Index(i) => {
                !flowing && options.get(*i).is_some_and(|o| o.2.starts_with("reject"))
            }
            PermChoice::Allow => false,
        };
        if declines {
            self.answering = None;
            return false;
        }
        if flowing {
            match choice {
                PermChoice::Index(i) => self.answer_pick(*i),
                _ => self.answer_confirm(),
            }
            return true;
        }
        let allow = options
            .iter()
            .find(|o| o.2 == "allow_once")
            .or_else(|| options.iter().find(|o| o.2.starts_with("allow")));
        let Some(allow_option) = allow.map(|o| o.0.clone()) else {
            self.status = "the question offers no allow option".into();
            return true;
        };
        let Some(session) = self.selected_id() else { return true };
        self.answering = Some(Answering {
            session,
            permission: pid,
            allow_option,
            question,
            item: 0,
            highlight: 0,
            picked: vec![],
            choices: vec![],
        });
        self.focus = Focus::Input;
        self.status = "answering the question  (digits pick · Enter confirms · Esc leaves)".into();
        true
    }

    /// Keys while the flow is open in the composer. Returns true when the
    /// key was the flow's; typing falls through to the composer (the Other
    /// text).
    pub(super) fn on_answering_key(&mut self, key: KeyEvent) -> bool {
        let empty = self.editor().is_empty();
        let Some(flow) = self.live_answering() else { return false };
        let (multi, highlight, count) = (flow.multi(), flow.highlight, flow.option_count());
        let plain = !key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Esc => {
                self.answering = None;
                self.status = "question left unanswered  (y answers · n declines)".into();
            }
            KeyCode::Enter if plain && !shift => self.answer_confirm(),
            KeyCode::Char(c) if plain && empty && c.is_ascii_digit() && c != '0' => {
                self.answer_pick(c as usize - '1' as usize)
            }
            KeyCode::Char(' ') if plain && empty && multi => self.answer_pick(highlight),
            KeyCode::Up if empty => self.answer_highlight(highlight.saturating_sub(1)),
            KeyCode::Down if empty => {
                self.answer_highlight((highlight + 1).min(count.saturating_sub(1)))
            }
            _ => return false,
        }
        true
    }

    fn answer_highlight(&mut self, to: usize) {
        if let Some(flow) = self.answering.as_mut() {
            flow.highlight = to;
        }
    }

    /// Picks option `i` of the active item: a single select records it and
    /// advances; a multi select toggles it.
    fn answer_pick(&mut self, i: usize) {
        let Some(flow) = self.live_answering() else { return };
        if i >= flow.option_count() {
            self.status = format!("no option {}", i + 1);
            return;
        }
        flow.highlight = i;
        if flow.multi() {
            if let Some(at) = flow.picked.iter().position(|&p| p == i) {
                flow.picked.remove(at);
            } else {
                flow.picked.push(i);
                flow.picked.sort_unstable();
            }
            return;
        }
        self.answer_item(Choice { options: vec![i], other: None });
    }

    /// Enter: confirms the active item from its toggles, the composer text
    /// (Other) or, for a single select, the highlighted option.
    fn answer_confirm(&mut self) {
        let text = self.editor().text().trim().to_owned();
        let Some(flow) = self.live_answering() else { return };
        let other = (!text.is_empty()).then_some(text);
        let options = if flow.multi() {
            flow.picked.clone()
        } else if other.is_none() && flow.option_count() > 0 {
            vec![flow.highlight]
        } else {
            vec![]
        };
        self.answer_item(Choice { options, other });
    }

    /// Records `choice` for the active item after checking it, then moves on;
    /// after the last item, sends the answers.
    fn answer_item(&mut self, choice: Choice) {
        let Some(flow) = self.live_answering() else { return };
        let Some(item) = flow.active().cloned() else { return };
        if let Err(why) = question_answer::check_choice(&item, &choice) {
            self.status = why;
            return;
        }
        let used_text = choice.other.is_some();
        flow.choices.push(choice);
        flow.item += 1;
        flow.highlight = 0;
        flow.picked.clear();
        let done = flow.active().is_none();
        if used_text {
            self.editor_mut().clear();
        }
        if !done {
            return;
        }
        let Some(flow) = self.answering.take() else { return };
        let answers = question_answer::encode(&flow.question, &flow.choices);
        self.request_bg(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": flow.session, "permissionId": flow.permission,
                "optionId": flow.allow_option, "answers": answers}),
            Some("answered".into()),
        );
    }
}
