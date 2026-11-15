// l10n-allow-file: gallery fixtures (sample key names, purposes and sites), not shipped UI.
// Settings > Keys (KeysCard, design/settings-keys.md): the keys agents keep on this Mac and the
// requests waiting for the person, with Store, Decline and Revoke. No fixture holds a value.
import { GALLERY_NOW } from "../../gallery/clock";
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockKeys } from "./mockProvider";
import type { KeyRecordWire, KeysState } from "./ops";

const day = 86_400_000;
const at = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const shown: PageFixtureStep = { selector: '[data-card="keys"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "keys",
  steps: [shown],
  ...patch,
});
const base = mockKeys(GALLERY_NOW);

const local = (name: string, patch: Partial<KeyRecordWire>): KeyRecordWire => ({
  id: `local-${name.toLowerCase()}`,
  label: name,
  name,
  provider: "local",
  kind: "secret",
  source: "stdin",
  purpose: null,
  hosts: [],
  stores: [],
  uses: [],
  by: "CLAUDE_CODE_SESSION_ID=9b1c2d3e-0000-4000-8000-000000000001",
  asked_by: null,
  created_at: at(GALLERY_NOW - day),
  expires_at: at(GALLERY_NOW + 30 * day),
  state: "live",
  ...patch,
});

const many: KeysState = {
  available: true,
  requests: [],
  keys: [
    ...base.keys,
    local("ERRORS_AUTH_TOKEN", {
      purpose: "Upload source maps on release",
      hosts: ["errors.example.com", "eu.errors.example.com"],
      stores: ["gh-secret:example/web:ERRORS_AUTH_TOKEN", "file:/Users/you/example/web/.env.local"],
      uses: [{ target: "errors.example.com", last_used_at: at(GALLERY_NOW - 600_000), count: 3 }],
      created_at: at(GALLERY_NOW - 5 * 60_000),
    }),
    local("REPO_TOKEN", {
      source: "generated",
      hosts: ["api.example.org"],
      by: "CODEX_SESSION_ID=0c9d8e7f-1111-4000-8000-000000000002",
      created_at: at(GALLERY_NOW - 40 * day),
      expires_at: at(GALLERY_NOW - 10 * day),
      state: "expired",
    }),
    local("DATABASE_URL", {
      source: "person",
      purpose: "Read-only replica for the analytics notebook",
      hosts: ["db.internal.example.com"],
      by: "user=you",
      asked_by: "CMUX_SESSION_ID=s-7781",
      expires_at: null,
      created_at: at(GALLERY_NOW - 2 * day),
    }),
    local("OLD_DEPLOY_KEY", {
      created_at: at(GALLERY_NOW - 90 * day),
      expires_at: at(GALLERY_NOW - 60 * day),
      state: "revoked",
    }),
  ],
};

const longPurpose: KeysState = {
  ...base,
  requests: [
    {
      id: "kr_0002",
      name: "PREVIEW_DEPLOYS_ACCOUNT_API_TOKEN_FOR_EVERY_PULL_REQUEST",
      purpose:
        "Deploy the preview site for every pull request in example/web, purge its cache after each deploy, and read the account's storage buckets so the preview can serve the same images as production without copying them",
      hosts: ["api.example.net", "dash.example.net", "preview.example.dev"],
      requester: "CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0-4d1a-9e3b-0c5d6e7f8a9b",
      asked_at: at(GALLERY_NOW - 30_000),
    },
    ...base.requests,
  ],
};

export default settingsPageEntry({
  id: "pages.settings-keys",
  title: "Settings Keys",
  area: "Settings",
  height: 640,
  covers: ["pages/settings/components/KeysCard.tsx#KeysCard"],
  anchors: [{ selector: '[data-card="keys"]' }],
  variants: {
    shipped: variant({
      note: "One request waits (who asked, what for, the site it may go to); three keys: live, expired, revoked.",
    }),
    empty: variant({
      keys: { available: true, requests: [], keys: [] },
      note: "No keys and no requests: one line that names cmux keys put.",
    }),
    many: variant({
      keys: many,
      note: "Seven keys: copies written to a repository secret and a file, uses with counts, generated and typed keys, expired and revoked last.",
    }),
    "long-purpose": variant({
      keys: longPurpose,
      note: "Two requests; a long name and purpose wrap inside the row, the field and buttons stay on one line.",
    }),
    "revoke-confirm": variant({
      steps: [shown, { selector: '[data-key="local-search_api_key"] [data-key-action="revoke"]', action: "click" }],
      note: "Revoke asks first, inline, and says what happens to a key kept on this Mac.",
    }),
    typed: variant({
      steps: [shown, { selector: "[data-key-request-field]", action: "input", value: "example-value" }],
      note: "A value typed into the request: masked, Store turns on.",
    }),
    unavailable: variant({
      keys: { available: false, requests: [], keys: [] },
      note: "This build's cmux could not list keys: one short line instead of the list.",
    }),
  },
});
