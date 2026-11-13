# Advisory model menus

Notice to PL-acpmux: an ACP harness can report a short suggestion list while accepting explicit
release ids outside it. The catalog merge now keeps that harness's curated releases and uses
catalog order for its picker menu. Other ACP harnesses retain their report-based filtering;
profile declarations and unknown reported ids remain available. No extra I/O or background work.

The bundled catalogs and versioned ledger price table include the two current releases with
launch pricing and context metadata. The catalog generator keeps the same family names and
order when regenerating those snapshots from its feed. An explicit family-order array survives
database serialization; a data migration updates existing seed rows and preserves curator rows.
Regression coverage exercises the actual hub reply and the NEXT picker join with a stale menu.
Reference surface: `manaflow-ai/cmux-design-references/apps/claude/live/NOTES.md` (model menu):
compact rows, stable check slots and the existing More models section; no layout changes.
