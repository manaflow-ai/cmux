# Scoped platform schema updates

`PLATFORM_REF` names the full selected spec's baseline. A scoped update below
names its published source without claiming the entire spec was refreshed.
The next full `scripts/update-spec.sh` refresh supersedes these entries.

- `JoinRedeem.properties.platform`: copied the enum and description from
  `manaflow-ai/cmux-platform` `openapi.json` at
  `e0fca27f21018fea6e44e72264b8a3b77a65b683` (PR #1487, merged
  2026-11-17; web enrollment originated in #1483). The request and response
  fields and redeem endpoint already match that contract. Browser enrollment
  sends `platform: "web"` and `capabilities: []`; it does not request vault
  access, replacement privileges, or a daemon identity.
- `POST /v1/machines/{id}/fork` request body `size`: the optional ladder
  enum (`sm`, `md`, `lg`, `xl`, `2xl`) from `manaflow-ai/cmux-platform`
  `openapi.json` at PR #2323 (RFD 0144 piece 8). The copy starts at that size,
  never smaller than the source. An older hub refuses the field with 400; the
  run VM then runs here, as any refused fork does.

`tests/web_redeem.rs` exercises the generated client's actual HTTP request,
success response, old-hub refusals and redirects. A merged platform schema is
not deployment evidence: an older hub may reject web with 400 or 404, and an
unavailable hub may return 503. These remain errors from the generated client;
acpmux's device enrollment maps them to `device.enroll_refused`, without
returning the upstream body or falling back to a native platform.
