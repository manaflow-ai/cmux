# Relay message class

Notice to PL-acpmux: [PR #43105](https://github.com/manaflow-ai/cmux/pull/43105) preserves an explicit class in CLI and MCP sends that use `sendRelay`. `RelayMetadata` carries the existing sender labels and a typed `PromptClass`; the child gets `ACPMUX_SEND_CLASS`, normalized for aliases, or has the variable removed when the send has no explicit class. The relay argv and receiver wake policy stay as before.

The CLI and MCP regression tests exercise four classes, aliases, omitted classes with stale inherited metadata, and invalid input. The sender-label and deadline changes owned by #39847 and #40105 are separate; this change does not modify their behavior. Deployment requires a relay consumer that forwards the optional metadata. This PR stops at review and fleet proof, with no daemon restart or deployment.
