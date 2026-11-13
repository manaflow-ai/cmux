# Advisory model menus

Notice to PL-acpmux: an ACP harness can report a short suggestion list while accepting explicit
release ids outside it. The catalog merge now keeps that harness's curated releases and uses
catalog order for its picker menu. Other ACP harnesses retain their report-based filtering;
profile declarations and unknown reported ids remain available. No extra I/O or background work.

The bundled catalogs and versioned ledger price table include the two current releases with
launch pricing and context metadata. NEXT merges live catalog entries with missing bundled
entries in Rust, keeping bundled family order and live ordering within each family. Live names,
prices, defaults and deprecations win; probe contracts and live aliases are preserved. The same
merge applies to live refresh and stored reload. These release snapshots are edited directly;
the classic projector, seed migrations and database are unchanged.
Regression coverage exercises live refresh/reload, the actual hub reply and the NEXT picker join.
Reference surface: `manaflow-ai/cmux-design-references/apps/claude/live/NOTES.md` (model menu):
compact rows, stable check slots and the existing More models section; no layout changes.
