// l10n-allow-file: synthetic repository contents and gallery-only controls.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudEnvironment, EnvironmentSection, SetupRun, SnapshotStatus } from "./environmentModel";

type Props = {
  section: EnvironmentSection;
  failure?: boolean;
  full?: boolean;
  delivery?: boolean;
  many?: boolean;
  /** PACKAGE_TOKEN as stored before every secret needed a host: no hosts, so it loads invalid. */
  legacy?: boolean;
  /** The Codex-style fields (repository, maintenance script, files, image allowlist, Off): absent is a
   *  service from before them; `empty` answers them unset; `filled` and `long` set them. */
  config?: "empty" | "filled" | "long";
  /** The stored network mode, when not the Limited the fixture starts with. */
  network?: "full" | "limited" | "off";
  /** A stored image the allowlist no longer names. */
  unlistedImage?: boolean;
  /** Another window saves the variables first, so this save meets a revision conflict on them. */
  conflict?: boolean;
  /** The last run and the snapshot's state, for the Setup output page. */
  run?: "cached" | "rebuilding" | "failed" | "maintenance" | "long";
};

const LONG_LOG = Array.from(
  { length: 60 },
  (_, line) =>
    `[${String(line).padStart(2, "0")}] npm warn deprecated package-${line}@1.0.${line}: use a newer release`,
).join("\n");
const steps = (state: "done" | "running" | "failed"): SetupRun["steps"] => [
  { id: "machine", state: "done", detail: null },
  { id: "repo", state: "done", detail: "example/field-notes@main" },
  { id: "files", state: "done", detail: ".npmrc, .env.local" },
  { id: "install", state: state === "failed" ? "failed" : "done", detail: "npm ci" },
  {
    id: "verify",
    state: state === "running" ? "running" : state === "failed" ? "skipped" : "done",
    detail: "npm test",
  },
  { id: "snapshot", state: state === "done" ? "done" : state === "running" ? "pending" : "skipped", detail: null },
];
const runs: Record<NonNullable<Props["run"]>, { last_run: SetupRun; snapshot_status: SnapshotStatus }> = {
  cached: {
    last_run: {
      kind: "setup",
      status: "succeeded",
      steps: steps("done"),
      log_tail: "added 812 packages in 21s\nready",
    },
    snapshot_status: { state: "cached" },
  },
  rebuilding: {
    last_run: { kind: "setup", status: "running", steps: steps("running"), log_tail: "added 812 packages in 21s" },
    snapshot_status: { state: "rebuilding", reason: "setup_script" },
  },
  failed: {
    last_run: {
      kind: "setup",
      status: "failed",
      steps: steps("failed"),
      log_tail:
        "npm error code ERESOLVE\nnpm error ERESOLVE could not resolve\nnpm error peer react@18 from react-dom@18.3.1",
      error: { code: "environment.install_failed", message: "The install command exited with status 1." },
    },
    snapshot_status: { state: "none" },
  },
  maintenance: {
    last_run: {
      kind: "maintenance",
      status: "succeeded",
      steps: [
        { id: "repo", state: "done", detail: "git pull --ff-only" },
        { id: "maintenance", state: "done", detail: "npm install" },
      ],
      log_tail: "up to date, audited 812 packages in 2s",
    },
    snapshot_status: { state: "cached" },
  },
  long: {
    last_run: { kind: "setup", status: "running", steps: steps("running"), log_tail: LONG_LOG },
    snapshot_status: { state: "rebuilding", reason: "expired" },
  },
};
const configs = {
  empty: { repo: null, ref: null, maintenance_script: null, files: [], image: "default" },
  filled: {
    repo: "example/field-notes",
    ref: "main",
    maintenance_script: "#!/bin/bash\nset -euo pipefail\nnpm install\n",
    files: [
      { path: ".npmrc", content: "registry=https://registry.npmjs.org/\n" },
      { path: ".env.local", content: "NEXT_PUBLIC_API=https://api.example.com\n" },
    ],
    image: "default",
  },
  long: {
    repo: "an-organization-with-a-long-name/a-repository-whose-name-goes-on-and-on-for-a-while",
    ref: "feature/very-long-branch-name-that-keeps-going-past-the-field",
    maintenance_script: Array.from({ length: 40 }, (_, line) => `echo "maintenance step ${line + 1}"`).join("\n"),
    files: Array.from({ length: 8 }, (_, index) => ({
      path: `config/deeply/nested/directory/for/settings/file-${index + 1}.json`,
      content: JSON.stringify({ index, enabled: true, hosts: ["api.example.com", "uploads.example.com"] }, null, 2),
    })),
    image: "ubuntu-24.04-node22-python3.12-rust1.90-with-browsers",
    // A service that lists more than its one image (the current one names only `default`).
    available_images: [
      "default",
      { id: "ubuntu-24.04-node22", name: "Ubuntu 24.04 · Node 22" },
      {
        id: "ubuntu-24.04-node22-python3.12-rust1.90-with-browsers",
        name: "Ubuntu 24.04 · Node 22, Python 3.12, Rust 1.90 and browsers",
      },
    ],
  },
} satisfies Record<string, Partial<CloudEnvironment>>;
const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cloud-environment-sheet .env-fields"));
};
const hostsField = (index: number) => ({ selector: `.env-secret:nth-of-type(${index + 1}) .env-secret-hosts input` });
const headerOpen: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: ".env-secret:nth-of-type(3) .env-disclosure" });
  await ctx.waitFor(() => ctx.document.querySelector('.env-disclosure[aria-expanded="true"]'));
};
const invalidHost: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type(", https://api.example.com/v1", hostsField(0));
  await ctx.click({ selector: ".env-primary" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-secret .env-error"));
};
const deliveryEdit: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type(", uploads.github.com", hostsField(1));
  await ctx.waitFor(() =>
    Array.from(ctx.document.querySelectorAll<HTMLInputElement>(".env-secret-hosts input")).some((input) =>
      input.value.includes("uploads.github.com"),
    ),
  );
};
const newHostless: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: ".env-add" });
  await ctx.type("DEPLOY_KEY", { selector: '.env-secret:last-of-type input[aria-label="Secret name"]' });
  await ctx.type("deploy-key-value", { selector: '.env-secret:last-of-type input[type="password"]' });
  await ctx.click({ selector: ".env-primary" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-secret:last-of-type .env-error"));
};
const firstHosts: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type("registry.npmjs.org", hostsField(0));
  await ctx.click({ selector: ".env-heading h2" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-secret .env-error"));
};
const manyExpanded: Play = async (ctx) => {
  await ready(ctx);
  const selector = '.env-secret > .env-disclosure[aria-expanded="false"]';
  const closed = () => ctx.document.querySelector(selector);
  while (closed()) await ctx.click({ selector });
  await ctx.waitFor(() => !closed());
};
const saveFailure: Play = async (ctx) => {
  await ready(ctx);
  await ctx.type("\necho ready", { selector: ".env-code textarea" });
  await ctx.click({ selector: ".env-primary" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-error"));
};

const badRepository: Play = async (ctx) => {
  await ready(ctx);
  const field = { selector: 'input[aria-label="Repository"]' };
  await ctx.type("not a repository", field);
  await ctx.click({ selector: ".env-heading h2" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-repository input[aria-invalid]"));
};
const badFiles: Play = async (ctx) => {
  await ready(ctx);
  await ctx.click({ selector: ".env-add" });
  await ctx.type("../outside/.npmrc", { selector: '.env-file-row:last-of-type input[aria-label="Path"]' });
  await ctx.click({ selector: ".env-primary" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-file-row .env-error"));
};

const changedElsewhere: Play = async (ctx) => {
  await ready(ctx);
  const value = { selector: '.env-value-row:nth-of-type(2) input[aria-label="Value"]' };
  await ctx.type("-verbose", value);
  await ctx.click({ selector: ".env-primary" });
  await ctx.waitFor(() => ctx.document.querySelector(".env-conflict"));
};

export default componentEntry<Props>({
  id: "cloud.environment-sheet",
  title: "Edit cloud environment",
  area: "Pages",
  height: 760,
  widths: { narrow: 360, normal: 700, wide: 1000 },
  covers: ["pages/cloud/EnvironmentSheet.tsx", "pages/cloud/EnvironmentFields.tsx"],
  load: async () => {
    const [{ EnvironmentSheet }, { EnvironmentStore }, { createStrings }, { default: table }] = await Promise.all([
      import("./EnvironmentSheet"),
      import("./environmentStore"),
      import("../shared/i18n"),
      import("./generated/strings.json"),
    ]);
    return function EnvironmentGallery({
      section,
      failure,
      full,
      delivery,
      many,
      legacy,
      config,
      network,
      unlistedImage,
      run,
      conflict,
    }: Props) {
      const [strings] = useState(() => createStrings(table));
      const [store] = useState(() => {
        let environment: CloudEnvironment = {
          id: "env_gallery",
          scope: "personal",
          name: "Default",
          is_default: true,
          setup_script: null,
          env_vars: [
            { name: "NODE_ENV", value: "development" },
            { name: "LOG_LEVEL", value: "info" },
          ],
          secrets: [
            legacy
              ? { name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }
              : { name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["registry.npmjs.org"] },
            ...(delivery
              ? [
                  // The default header (absent): Authorization: Bearer {value}.
                  { name: "GITHUB_TOKEN", updated_at: "2026-11-01T00:00:00Z", hosts: ["api.github.com"] },
                  {
                    name: "SEARCH_KEY",
                    updated_at: "2026-11-01T00:00:00Z",
                    hosts: ["search.example.com", "search-eu.example.com"],
                    header: { name: "x-api-key", format: "{value}" },
                  },
                ]
              : []),
            ...(many
              ? ["STRIPE_KEY", "SENTRY_TOKEN", "OPENAI_KEY", "LINEAR_TOKEN", "SLACK_TOKEN", "VERCEL_TOKEN"].map(
                  (name, index) => ({
                    name,
                    updated_at: "2026-11-01T00:00:00Z",
                    hosts: [`api${index}.example.com`, `uploads${index}.example.com`],
                  }),
                )
              : []),
          ],
          // This service keeps where each secret goes (cmux-platform#1008), so the delivery controls show.
          secret_routes: true,
          ...(config ? configs[config] : {}),
          ...(unlistedImage ? { image: "debian-11-legacy" } : {}),
          ...(run ? runs[run] : {}),
          ...(conflict ? { revision: 1 } : {}),
          network: {
            mode: network ?? (full ? "full" : "limited"),
            package_managers: true,
            domains: ["github.com", "registry.npmjs.org"],
          },
          created_at: "2026-11-01T00:00:00Z",
          updated_at: "2026-11-01T00:00:00Z",
          updated_by: "user_example",
        };
        return new EnvironmentStore({
          list: async () => [environment],
          get: async () => environment,
          update: async (_id, patch) => {
            if (failure) throw new Error("Simulated save failure");
            if (conflict && patch.expected_revision === 1) {
              // Saved elsewhere first: LOG_LEVEL changed there too.
              environment = {
                ...environment,
                revision: 2,
                env_vars: [
                  { name: "NODE_ENV", value: "development" },
                  { name: "LOG_LEVEL", value: "debug" },
                ],
              };
              throw Object.assign(new Error("Changed elsewhere"), { code: "cloud_environment.revision_conflict" });
            }
            environment = {
              ...environment,
              ...(patch.name !== undefined ? { name: patch.name } : {}),
              ...(patch.setup_script !== undefined ? { setup_script: patch.setup_script } : {}),
              ...(patch.env_vars ? { env_vars: patch.env_vars } : {}),
              ...(patch.network ? { network: patch.network } : {}),
              ...(patch.repo !== undefined ? { repo: patch.repo } : {}),
              ...(patch.ref !== undefined ? { ref: patch.ref } : {}),
              ...(patch.maintenance_script !== undefined ? { maintenance_script: patch.maintenance_script } : {}),
              ...(patch.files ? { files: patch.files } : {}),
              ...(patch.image !== undefined ? { image: patch.image } : {}),
              secrets: [
                ...environment.secrets.filter(
                  (secret) =>
                    !patch.remove_secrets?.includes(secret.name) &&
                    !patch.set_secrets?.some((set) => set.name === secret.name),
                ),
                ...(patch.set_secrets ?? []).map(({ name, hosts, header }) => ({
                  name,
                  updated_at: "2026-11-01T00:01:00Z",
                  ...(hosts ? { hosts } : {}),
                  ...(header ? { header } : {}),
                })),
              ],
            };
            return environment;
          },
          derive: async () => ({ setup: { script: "#!/bin/bash\nset -euo pipefail\nnpm ci\nnpm run build\n" } }),
        });
      });
      useEffect(() => {
        void store.open({ section, repo: "example/field-notes" });
        return () => store.close();
      }, [section, store]);
      return <EnvironmentSheet store={store} strings={strings} />;
    };
  },
  styles: () => Promise.all([import("../shared/pageBase.css"), import("../../ui/ui.css"), import("./environment.css")]),
  variants: {
    overview: {
      note: "The locked personal Default and the four shared drill-in pages.",
      props: { section: "overview" },
      play: ready,
    },
    script: {
      note: "The repository-derived Bash script remains automatic until edited.",
      props: { section: "script" },
      play: ready,
    },
    network: {
      note: "Limited network access, package managers and allowed domains.",
      props: { section: "network" },
      play: ready,
    },
    "network-full": {
      note: "Full network access preserves the saved Limited settings.",
      props: { section: "network", full: true },
      play: ready,
    },
    secrets: {
      note: "Existing names are visible; values are blank and write-only.",
      props: { section: "secrets" },
      play: ready,
    },
    "secret-hosts": {
      note: "Secrets sent only to their hosts: the default Authorization header, and a custom one.",
      props: { section: "secrets", delivery: true },
      play: ready,
    },
    "secret-header-open": {
      note: "The Header disclosure open on a secret with a custom header name and format.",
      props: { section: "secrets", delivery: true },
      play: headerOpen,
    },
    "secret-invalid-host": {
      note: "A URL typed as a host: the inline error under the row, and Save refuses it.",
      props: { section: "secrets", delivery: true },
      play: invalidHost,
    },
    "secret-delivery-edit": {
      note: "A host added to a stored secret with its value left empty: Save sends only where it goes.",
      props: { section: "secrets", delivery: true },
      play: deliveryEdit,
    },
    "secret-no-hosts": {
      note: "A secret stored before every secret needed a host: it loads invalid until it gets one.",
      props: { section: "secrets", delivery: true, legacy: true },
      play: ready,
    },
    "secret-new-no-hosts": {
      note: "A new secret with a name and value but no host: the inline error, and Save refuses it.",
      props: { section: "secrets", delivery: true },
      play: newHostless,
    },
    "secret-first-hosts": {
      note: "A secret stored without hosts given its first host: the row asks for its value again.",
      props: { section: "secrets", delivery: true, legacy: true },
      play: firstHosts,
    },
    "secret-many-expanded": {
      note: "Nine secrets, every header open: the fields scroll between the fixed heading and actions.",
      props: { section: "secrets", delivery: true, many: true },
      play: manyExpanded,
    },
    variables: {
      note: "Environment variable names and editable values.",
      props: { section: "variables" },
      play: ready,
    },
    "overview-configured": {
      note: "A service with the Codex-style fields: the image picker, then Repository, Maintenance script, Files and Setup output rows beside the others.",
      props: { section: "overview", config: "filled", run: "cached" },
      play: ready,
    },
    "overview-older-service": {
      note: "A service from before the new fields: no image picker and only the original rows, so nothing it would refuse is offered.",
      props: { section: "overview" },
      play: ready,
    },
    "overview-long": {
      note: "Long repository, branch, image and file names: summaries wrap to two lines and the picker keeps its width.",
      props: { section: "overview", config: "long", run: "long" },
      play: ready,
    },
    "repository-empty": {
      note: "No repository yet: owner/name and Default branch placeholders.",
      props: { section: "repository", config: "empty" },
      play: ready,
    },
    "repository-filled": {
      note: "A repository and branch set.",
      props: { section: "repository", config: "filled" },
      play: ready,
    },
    "repository-error": {
      note: "A repository typed without owner/name: both fields invalid, the message folds open under them.",
      props: { section: "repository", config: "empty" },
      play: badRepository,
    },
    "repository-long": {
      note: "Long owner, name and branch: the fields keep their columns and scroll their text.",
      props: { section: "repository", config: "long" },
      play: ready,
    },
    "maintenance-empty": {
      note: "No maintenance script: the same editor as Setup script, with no repository suggestion.",
      props: { section: "maintenance", config: "empty" },
      play: ready,
    },
    "maintenance-filled": {
      note: "A maintenance script that updates dependencies when a machine resumes from the snapshot.",
      props: { section: "maintenance", config: "filled" },
      play: ready,
    },
    "maintenance-long": {
      note: "A forty-line maintenance script: the editor scrolls, the gutter follows.",
      props: { section: "maintenance", config: "long" },
      play: ready,
    },
    "files-empty": {
      note: "No files: the note and Add file.",
      props: { section: "files", config: "empty" },
      play: ready,
    },
    "files-filled": {
      note: "Two files, each a path and its contents.",
      props: { section: "files", config: "filled" },
      play: ready,
    },
    "files-error": {
      note: "A file path with ..: the row's message folds open and Save stops.",
      props: { section: "files", config: "filled" },
      play: badFiles,
    },
    "files-long": {
      note: "Eight files with long paths and contents: the fields scroll between the fixed heading and actions.",
      props: { section: "files", config: "long" },
      play: ready,
    },
    "image-unlisted": {
      note: "A stored image the allowlist no longer names stays picked and listed, never swapped for another.",
      props: { section: "overview", config: "long", unlistedImage: true },
      play: ready,
    },
    "network-off": {
      note: "Network access Off, beside Full and Limited, with its note and the honest one: a chat can't start on it yet.",
      props: { section: "network", config: "filled", network: "off" },
      play: ready,
    },
    "output-empty": {
      note: "Setup output before any setup ran.",
      props: { section: "output", config: "empty" },
      play: ready,
    },
    "output-cached": {
      note: "The last setup succeeded: Snapshot cached, every step Done, the log's last lines.",
      props: { section: "output", config: "filled", run: "cached" },
      play: ready,
    },
    "output-rebuilding": {
      note: "The setup script changed: Snapshot rebuilding and why, the run's steps so far.",
      props: { section: "output", config: "filled", run: "rebuilding" },
      play: ready,
    },
    "output-failed": {
      note: "The install failed: the failed step, the service's message and the log tail.",
      props: { section: "output", config: "filled", run: "failed" },
      play: ready,
    },
    "output-maintenance": {
      note: "The last run was the maintenance script on a resumed machine; the snapshot stays cached.",
      props: { section: "output", config: "filled", run: "maintenance" },
      play: ready,
    },
    "output-long": {
      note: "Sixty log lines: the log scrolls in its own box, capped in height.",
      props: { section: "output", config: "long", run: "long" },
      play: ready,
    },
    "phone-overview": {
      note: "iPhone width (the narrow preset): the configured overview; summaries wrap, nothing overflows the sheet.",
      props: { section: "overview", config: "long", run: "rebuilding" },
      play: ready,
    },
    "phone-repository": {
      note: "iPhone width: the repository and branch fields stack.",
      props: { section: "repository", config: "long" },
      play: ready,
    },
    "phone-output": {
      note: "iPhone width: each step's detail goes under its name; the log scrolls in its box.",
      props: { section: "output", config: "long", run: "failed" },
      play: ready,
    },
    conflict: {
      note: "Saved elsewhere first, on the same variable: the sheet names Environment variables, keeps the edit, and offers Keep my edits or Use the newest.",
      props: { section: "variables", config: "filled", conflict: true },
      play: changedElsewhere,
    },
    "save-failure": {
      note: "A failed save keeps the script draft and offers retry.",
      props: { section: "script", failure: true },
      play: saveFailure,
    },
  },
});
