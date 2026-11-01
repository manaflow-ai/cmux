// l10n-allow-file: synthetic repository contents and gallery-only controls.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudEnvironment, EnvironmentSection } from "./environmentModel";

type Props = { section: EnvironmentSection; failure?: boolean; full?: boolean };
const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cloud-environment-sheet .env-fields"));
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
    return function EnvironmentGallery({ section, failure, full }: Props) {
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
          secrets: [{ name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }],
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
                ...(patch.set_secrets ?? []).map(({ name }) => ({ name, updated_at: "2026-11-01T00:01:00Z" })),
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
