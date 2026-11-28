# Regression and Test Quality

The two-commit policy, wiring requirement, and quality rules are in [../SKILL.md](../SKILL.md). This covers the judgment call.

## Is the test behavioral?

Behavioral tests exercise unit, integration, E2E, CLI, or artifact-level paths of a built product. A test that reads source text, method signatures, AST fragments, grep patterns, or checked-in plist/project/config snippets asserts implementation shape, not behavior, and passes while the user-visible bug remains.

For a metadata change, test the built app bundle or the runtime behavior that depends on that metadata. If neither is practical, skip the test and state that in the handoff instead of adding a shape assertion.

## When tests missed a bug

When the user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete. Do not add a broad implementation-shape test that would have passed while the bug was live.
