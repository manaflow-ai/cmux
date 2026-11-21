# Notice to PL-acpmux: one file per audit notice (2026-11-09)

Owner W5-S, lead decision. Every PR that changes acpmux appended its notice to the end of
`plans/cmux-next/acpmux-audit.md`, so two PRs open at the same time always conflicted there,
and a rebase of a risk:high PR costs a new review. From now on, each notice is a file of its own
in this folder, `YYYY-MM-DD-<slug>.md`. `acpmux-audit.md` keeps the older notices and points
here. The guardrails owner warning still names `acpmux-audit.md` as the file to read first
(`plans/cmux-next/OWNERS.md`); no check reads the notices themselves.
