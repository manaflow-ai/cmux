// l10n-allow-file: synthetic repository contents and gallery-only controls.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudEnvironment, EnvironmentSection } from "./environmentModel";

type Props = {
  section: EnvironmentSection;
  failure?: boolean;
  full?: boolean;
  delivery?: boolean;
  many?: boolean;
  /** PACKAGE_TOKEN as stored before every secret needed a host: no hosts, so it loads invalid. */
  legacy?: boolean;
};
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
    return function EnvironmentGallery({ section, failure, full, delivery, many, legacy }: Props) {
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
          network: {
            mode: full ? "full" : "limited",
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
            environment = {
              ...environment,
              ...(patch.name !== undefined ? { name: patch.name } : {}),
              ...(patch.setup_script !== undefined ? { setup_script: patch.setup_script } : {}),
              ...(patch.env_vars ? { env_vars: patch.env_vars } : {}),
              ...(patch.network ? { network: patch.network } : {}),
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
    "save-failure": {
      note: "A failed save keeps the script draft and offers retry.",
      props: { section: "script", failure: true },
      play: saveFailure,
    },
  },
});
