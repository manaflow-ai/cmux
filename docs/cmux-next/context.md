# Session context

Open a session's **…** menu and choose **Context**. The Context tab shows
the harness's reported context categories and the cmux additions captured when
the session was created. Expand a row to see its source text when available.

Token counts are labelled **measured**, **estimated**, or **unavailable**.
Harness category rows can include their tool, memory, and skill detail rows;
they are not added together. A reported total is shown separately from the
estimate for cmux-owned text. Provider-managed prompts and runtime hook output
may not be exposed by the harness.

Use **Next session** to replace cmux guidance for your account or the
current project. For a local Claude preset with a cmux-owned system prompt,
the **Part** menu also lets you edit that preset’s prompt independently.
Preset edits apply only to the selected preset. Project settings take precedence over account settings. An
empty saved override disables the selected cmux addition at that scope; **Reset** restores
inheritance. These settings apply when a new session is created. The effective
context of an existing session remains unchanged.

Remote clients without permission to edit settings show the available context
report without an editor.

MCP instructions, tool contracts, skill descriptions, and provider-owned prompts
are read-only. Text the harness does not expose remains unavailable.
