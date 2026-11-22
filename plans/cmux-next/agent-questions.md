# Agent questions: one model, every harness, every surface

Status: lane chief-ask-gallery, 2026-10-07. Spec proposal for the coordinator.

An agent asks a person a question (Claude Code's AskUserQuestion, a Codex
user-input request, a generic ACP interactive permission, the Chief in Home).
Every surface shows the same card and every answer goes back in the asking
harness's own shape.

## 1. Model

`AgentQuestion` (Swift package `Packages/Shared/CmuxAgentQuestion`, TypeScript
mirror in `webviews/src/agent-session/acpmux/question/model.ts`):

- `id`, `source {harness: claude|codex|acp|chief, session, permission?,
  toolCall?, agentName?, answerOption?, rejectOption?}`.
- `items` (1 to 4): `{id, header?, prompt, options [{id, label, detail?,
  preview? {text, format: monospace|markdown}}], multiSelect, allowsOther}`.
- `state`: `{kind: pending}`, `{kind: cancelled}`, or `{kind: answered,
  answer {selections {itemId: {optionIDs, other?}}, respondent? {participant,
  displayName, device, isRemote}, answeredAtMs?}}`.

Fixtures: `Packages/Shared/CmuxAgentQuestion/Sources/CmuxAgentQuestion/Fixtures/`,
`<variant>.request.json` (an acpmux `permission_request` record) and
`<variant>.json` (the expected model). Swift tests, the web tests and the UI
galleries read the same files.

## 2. Owners

| Fact | Owner | Writes |
| --- | --- | --- |
| A pending ask in an agent tab | acpmux hub (the session's permission) | `permission_request`, `permission_decision` events |
| A question in a Home conversation | the conversation owner (local daemon or `ConversationDO`) | `question` part, `question.answer` op |
| Highlighted row, chosen options, Other draft | the client (card state, never persisted) | `AgentQuestionCardState` |

## 3. acpmux (agent tabs)

- The hub adds `toolCall._meta.acpmux.question` (camelCase, the model's
  `items`) to every permission request whose tool input holds `questions`
  (Claude: answers keyed by prompt; Codex: questions with `id`, answers keyed
  by id). A writer that already set it (the Chief) is kept.
- Policy never answers a question: approve-all, approve rules and the chat
  allowance skip it; deny-all and deny rules may decline it. Before this
  change approve-all selected `allow_once` for AskUserQuestion with no
  answers.
- `_acpmux/permission_respond {answers}` is accepted only for a question, and
  only when it answers every item and nothing else, in the harness's shape.
  Before, `answers` was copied into any tool's input.
- Remote answers follow the existing remote guard (`web_control_check`, Web
  answers allow once only).

## 4. Conversations (Home)

- `Part::Question` (`{"type": "question", harness, session, permission?,
  agent?, items, state}`, snake_case) is sent only by an agent, only pending.
- `question.answer {message_id, part_index, answer}`: human participants
  only (`human_only`), pending only (`question_closed`), complete and valid
  (`invalid_answer`). The owner stamps `respondent` from the connection's
  participant: a paired device (`remote_<install>` with `person`) answers as
  its person with `device` and `remote: true`.
- `message.edit` keeps each question part with the same content; it may only
  move pending to cancelled.
- The TypeScript core (backend/packages/home-core) is the behavior source;
  its corpus covers these rules and the Rust crate replays it.
- Paired installs (iOS remote relay) do not project question parts yet, so
  `question.answer` stays denied there until the projection lands.

## 5. Chief (not built here)

The Chief's own AskUserQuestion reaches the brain as `permission_pending`
for its session. Proposed core step (TypeScript first, corpus, then Rust):
post a `question` part (`permission` = the permission id, items from
`_meta.acpmux.question`), and on `conversation_changed` with that part
answered, call `_acpmux/permission_respond` with the encoded answer. A child
session's question is shown the same way, with the child's session.

## 6. Card (Mac)

`CmuxNextAgentQuestion.AgentQuestionCardView` (AppKit, one layout function
`AgentQuestionCardLayout` for measure and draw): header chip, agent and
pager, prompt, option rows with number keycaps and descriptions, checkmarks
for multi-select, a preview pane beside the options (below them under 520 pt),
an Other row with an inline field, Skip and Submit. Keys come from the shared
reducer: 1-9, arrows, Return, Space, Esc leaves (never answers). Answered
collapses to one line per item plus "Answered on <device>"; cancelled is a
one-line notice. VoiceOver: rows are radio buttons or checkboxes with their
position. Strings in 21 languages.

Home places it through MessagesLab's custom-row seam (`MessagePart.custom`)
once that lands; until then a placeholder row.

## 7. Open

- DECISION: should Skip decline (the agent sees "rejected") or only collapse
  the card locally? RECOMMEND: decline, because a hidden pending ask blocks
  the agent's turn forever.
- Codex end to end is UNVERIFIED: it depends on how the Codex ACP adapter
  forwards user-input requests.
