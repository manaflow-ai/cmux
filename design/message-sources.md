# Message sources

Leo-Ask-Trace: ask-bdba7066a6

A quiet 24px Sources disclosure under the reply action row, using the existing web Sources visual language. Closed: Sources and the count. Open: a compact list with the document title, optional immutable revision, and an explicit backlink link when supplied by the wiki. No animation beyond the existing disclosure chevron, no cards or added decoration.

Reference: private design references `apps/claude/live/transcript-reply-action-row-gaps.png`; maintain the existing reply actions and spacing. The panel says “Read during this reply”: it records successful tool access, not sentence-level evidence or every search result. Missing provenance draws no button. Files use the existing scoped host path policy; remote/shared sessions cannot open a local file accidentally.

## Identity and wiki hosting

Rust emits bounded per-turn `turn_sources` records bound to an exact reply segment. Each source records kind, canonical URI/path, title, tool call id, and optional revision/backlink URI supplied by the document provider. Search hits, failed reads and arbitrary answer links never become sources. Hosted and self-hosted wiki providers should use the same document identity and source-use edge: session, turn, reply, tool call, URI, revision. Backlink queries must enforce session/team access. This change preserves provider metadata; a deployed backlink service is a separate integration, not inferred from URLs.

## Document-to-reply slice

A local Markdown document opened from a chat carries a native-only capability for that originating chat. A quiet “Replies using this page” disclosure reads `_acpmux/source_uses` on demand from persisted `turn_sources` journal records. Pages are bounded and continue through an empty page when the returned cursor says more records remain. A click returns to the exact stamped assistant reply segment, including when later replies exist. The segment is not a harness message id.

The document cannot nominate a session, machine or socket. The native bridge checks the currently displayed file, the originating session before and after each read, and a real click on a reply previously returned for this document. A reused viewer updates this capability without reloading or replacing unsaved text. Navigating to another document does not transfer it. Remote and shared chats have no local fallback. Hosted/team wiki providers and arbitrary independently opened wiki pages remain outside this first slice; they need an authenticated provider bridge.

URI lookup uses the tool's exact recorded file identity with uppercase percent encoding, including spaces, hashes, percent signs and Unicode. Symlink aliases and different lexical path spellings are not merged. The design follows the existing Markdown toolbar and small disclosure/list controls, with no animation or new card surface.
