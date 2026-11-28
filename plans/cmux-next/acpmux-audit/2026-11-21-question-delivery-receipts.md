# Chief Home question delivery receipts

PR: https://github.com/manaflow-ai/cmux/pull/33564

Home must not record an answer merely because it sent a request, or because the
agent no longer lists that question. A reply can be lost after delivery; a dead
asking task can also leave a settled permission without accepting its answer.

The cmux-tui daemon persists a delivery intent before sending. ACP persists a
bounded receipt claim before spending the decision proof or sending to the
asking task. Only a successful `pending.reply.send` produces `delivered`;
`agent_gone` produces a refusal. An interrupted or unpersisted result remains
unknown. Delivered means accepted by the asking task, not executed by a harness.

Every retry queries the same receipt and never resends. Home commits its answer
and idempotency result together only when the receipt matches the session,
permission, instance, nonce, request digest, option and answer digest. Decision
proofs and keys are never persisted. Unknown delivery preserves the intent and
returns `conversation_indeterminate`; a definitive refusal is visible as
`conversation_rejected`.

Native approval cards already answer through a person-proven connection. Their
record operation supplies `decision.native_record` with the unchanged question,
receipt ID, instance and nonce. This path only queries evidence; a caller's
`already_answered` flag or the absence of a pending question is never evidence.
Routes come from the stored Chief author and registered homes, not caller paths.

Home store and SQLite locks end before network operations. ACP's receipt writes
remain synchronous under the per-session permission lock because the durable
claim must precede delivery; they do not touch the token/log path. Each session
keeps at most 256 receipts, evicting terminal entries only. Unknown entries are
not evicted to manufacture permission to resend.

Regression detectors are `hub::permissions::delivery_tests`,
`hub::permissions::receipt_tests`, `conversation_deliveries::tests`, and
`conversation_question::delivery::tests`. They cover dropped receivers,
receipt mismatches, reopen/replay, lost acknowledgement, and refusal to infer
delivery from RPC success alone. `agent_session_link::tests` covers blocked
connection admission and deadline-bounded writes. These checks run through
`cmux-ci`; source review alone does not prove the native Home flow.

The Swift receipt producer and actual Home interaction must be verified before
removing this PR's hold. See https://github.com/manaflow-ai/cmux/issues/49025.
