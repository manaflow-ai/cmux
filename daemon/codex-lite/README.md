# cmux-codex-lite

Experimental Rust coding-agent daemon.

Design goals:

1. One long-lived loopback app server for many parked sessions.
2. One upstream OpenAI Responses WebSocket by default, serialized by the daemon.
3. No persistent shell per agent. Commands run as structured `argv`.
4. Every tool output is stored losslessly on disk. The model receives compact manifests and can read or search exact slices by ref.

Run:

```bash
cargo run --manifest-path daemon/codex-lite/Cargo.toml -- serve \
  --listen 127.0.0.1:17680 \
  --state-dir .codex-lite \
  --model gpt-5.3-codex
```

The daemon reads `OPENAI_API_KEY`. Optional `OPENAI_ORGANIZATION` and
`OPENAI_PROJECT` are forwarded when present.

API:

```bash
curl -s http://127.0.0.1:17680/healthz

curl -s http://127.0.0.1:17680/v1/sessions \
  -H 'content-type: application/json' \
  -d '{"cwd":"."}'

curl -N http://127.0.0.1:17680/v1/sessions/<session-id>/turns/stream \
  -H 'content-type: application/json' \
  -d '{"input":"Find the app entrypoint and summarize it"}'
```

Protocol notes from OpenAI Codex:

1. The upstream socket sends `response.create` to `/responses`.
2. Continuations send only new input items plus `previous_response_id`.
3. Requests include `stream: true`, `store: false`, and a per-session prompt cache key.
4. Codex sends `OpenAI-Beta: responses_websockets=2026-02-06`.
5. Codex sends best-effort `response.processed` after a completed response.
6. A single socket has one active response stream, so this daemon queues turns when configured for one upstream connection.
