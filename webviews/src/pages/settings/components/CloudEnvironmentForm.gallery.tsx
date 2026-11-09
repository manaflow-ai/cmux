// l10n-allow-file: gallery fixtures (sample repositories, scripts and variable names), not shipped UI.
// Settings > Cloud Environments' editor (CloudEnvironmentsCard.tsx#EnvironmentForm), the ChatGPT
// desktop app's environment editor (Leo, 2026-11-09: "as for cloud, how about configuring
// "environments" or whatever that stuff is in chatgpt desktop app"). Each state the person meets:
// a new environment, an edit with plain and vault variables, and a long multi-line setup script.
import { componentEntry } from "../../../gallery/format";
import type { CloudEnvironmentRow } from "../ops";

type Props = { row?: CloudEnvironmentRow };

const web: CloudEnvironmentRow = {
  id: "env_00000000000000000001",
  name: "web",
  repo: "manaflow-ai/cmux@feat-cmux-next",
  setup_script: "cd web && bun install",
  env: [
    { name: "NODE_ENV", value: "development" },
    { name: "OPENAI_API_KEY", secret: "openai" },
  ],
  status: "ready",
  error: null,
  log_tail: null,
};

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { EnvironmentForm } = await import("./CloudEnvironmentsCard");
  return function EnvironmentForms({ row }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="cloudEnvironments">
          <div className="rows">
            <div className="row">
              <EnvironmentForm row={row} busy={false} onSave={() => {}} onCancel={() => {}} />
            </div>
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.cloud-environment-form",
  title: "Cloud environment editor",
  area: "Settings",
  height: 460,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/CloudEnvironmentsCard.tsx#EnvironmentForm"],
  load,
  styles: () => import("../page.css"),
  variants: {
    add: { note: "Add Environment: empty fields, no variables yet.", props: {} },
    edit: { note: "Edit: the saved repository, script and a plain and a vault variable.", props: { row: web } },
    script: {
      note: "A long setup script keeps its lines; the field grows by dragging, not the card.",
      props: {
        row: {
          ...web,
          name: "api",
          setup_script:
            "set -euo pipefail\ncd backend\npnpm install --frozen-lockfile\npnpm prisma generate\npnpm build\ncp .env.example .env",
          env: [
            { name: "DATABASE_URL", secret: "staging-db" },
            { name: "LOG_LEVEL", value: "debug" },
            { name: "PORT", value: "3000" },
          ],
        },
      },
    },
  },
});
