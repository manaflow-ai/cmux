# Notice to PL-acpmux: two env predicates are public for cmux-tui (2026-11-08)

W5-R (#39027, bench round 4 A6; lead decision: one rule, as W5-N did). What changed in acpmux:
- `config/nested_env.rs`: `is_nested_claude_key` and `is_caller_scoped_key` are now `pub` and
  re-exported from `acpmux::config`. No behavior change in acpmux.
- The cmux-tui session owner calls them (`cmux-tui/src/startup_env.rs::agent_caller_keys`) to
  drop the starting agent's session env from its own environment, which every terminal it hosts
  inherits. It drops `is_caller_scoped_key` keys always, and `is_nested_claude_key` keys when
  `CLAUDECODE` is set. So a change to either predicate also changes what the cmux-tui owner
  removes: tell the cmux-tui owner when you change them.
- Kept on purpose: `ACPMUX_HOME` and `ACPMUX_SOCKET` (which acpmux a build uses, per-build
  isolation, not a session).
