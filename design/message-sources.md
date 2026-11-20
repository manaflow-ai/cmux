# Message sources

Leo-Ask-Trace: ask-bdba7066a6

A quiet 24px Sources disclosure under the reply action row, using the existing web Sources visual language. Closed: Sources and the count. Open: a compact list with the document title, optional immutable revision, and an explicit backlink link when supplied by the wiki. No animation beyond the existing disclosure chevron, no cards or added decoration.

Reference: private design references `apps/claude/live/transcript-reply-action-row-gaps.png`; maintain the existing reply actions and spacing. The panel says “Read during this reply”: it records successful tool access, not sentence-level evidence or every search result. Missing provenance draws no button. Files use the existing scoped host path policy; remote/shared sessions cannot open a local file accidentally.

## Identity and wiki hosting

Rust emits bounded per-turn `turn_sources` records bound to an exact reply segment. Each source records kind, canonical URI/path, title, tool call id, and optional revision/backlink URI supplied by the document provider. Search hits, failed reads and arbitrary answer links never become sources. Hosted and self-hosted wiki providers should use the same document identity and source-use edge: session, turn, reply, tool call, URI, revision. Backlink queries must enforce session/team access. This change preserves provider metadata; a deployed backlink service is a separate integration, not inferred from URLs.
