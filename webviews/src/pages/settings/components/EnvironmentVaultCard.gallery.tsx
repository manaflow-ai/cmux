// l10n-allow-file: gallery fixtures (sample variable names, hosts and machine ids), not shipped UI.
// Settings > Cloud > Environment (RFD 0222 (c)1): the person's vault lists. Each state the person
// meets: nothing saved yet, a few variables and secrets with machine grants, and a key-shaped name
// refused as a variable with its one-click move to Secrets.
import { componentEntry } from "../../../gallery/format";
import type { VaultEntry, VaultGrant } from "../ops";

type Props = { entries?: VaultEntry[]; grants?: VaultGrant[]; keyShaped?: string };

const day = 86_400_000;
const now = Date.UTC(2026, 10, 28, 16, 0);
const entries: VaultEntry[] = [
  { name: "NODE_ENV", revision: 2, updatedAt: now - 3 * day, delivery: "env", allowedHosts: [] },
  { name: "LOG_LEVEL", revision: 1, updatedAt: now - day, delivery: "env", allowedHosts: [] },
  {
    name: "GITHUB_TOKEN",
    revision: 4,
    updatedAt: now - 2 * day,
    delivery: "proxy",
    allowedHosts: ["api.github.com", "*.githubusercontent.com"],
  },
  { name: "STRIPE_SECRET_KEY", revision: 1, updatedAt: now - 600_000, delivery: "proxy", allowedHosts: [] },
];
const grants: VaultGrant[] = [
  { kind: "joined", id: "mac-studio", expiresAt: now + 30 * day, grantedAt: now - 5 * day },
  { kind: "cloud", id: "vm_7f3a", entries: ["GITHUB_TOKEN"], expiresAt: 0, grantedAt: now - day },
];

async function load() {
  const { installCatalog, t } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { VaultLists } = await import("./EnvironmentVaultCard");
  const { useEffect } = await import("react");
  return function EnvironmentVault({ entries = [], grants = [], keyShaped }: Props) {
    // The app mounts Settings in the refined look (mount.tsx); the gallery shows that, not the base sheet.
    useEffect(() => {
      const previous = document.documentElement.dataset.settingsLook;
      document.documentElement.dataset.settingsLook = "refined";
      return () => {
        if (previous === undefined) delete document.documentElement.dataset.settingsLook;
        else document.documentElement.dataset.settingsLook = previous;
      };
    }, []);
    return (
      <div className="settings" style={{ display: "block" }}>
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="environmentVault">
          <div className="rows models-rows">
            <VaultLists
              entries={entries}
              grants={grants}
              busy={false}
              failure={keyShaped ? { message: t("settingsPage.vault.keyShaped", keyShaped), keyShaped } : null}
              clearFailure={() => {}}
              run={async () => true}
              refuse={() => {}}
            />
          </div>
        </section>
      </section>
      </div>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.environment-vault",
  title: "Environment variables and secrets",
  area: "Settings",
  height: 620,
  widths: { narrow: 446, normal: 720 },
  covers: ["pages/settings/components/EnvironmentVaultCard.tsx#VaultLists"],
  load,
  styles: () => import("../page.css"),
  variants: {
    empty: { note: "Nothing saved yet: each list says so and offers Add.", props: {} },
    "a-few": {
      note: "Two variables, a secret with hosts, one with none yet, a joined Mac and a revoked Cloud grant.",
      props: { entries, grants },
    },
    "key-shaped-refused": {
      note: "OPENAI_API_KEY refused as a variable before sending; Add as Secret keeps what was typed.",
      props: { entries, grants, keyShaped: "OPENAI_API_KEY" },
    },
  },
});
