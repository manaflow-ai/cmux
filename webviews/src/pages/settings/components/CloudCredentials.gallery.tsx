// l10n-allow-file: gallery fixtures (a sample team's issuer URLs), not shipped UI.
// Settings > Cloud > Cloud Credentials (CloudCredentialsCard.tsx, https://github.com/manaflow-ai/cmux/issues/48427):
// the team's cmux OIDC issuer and each cloud's setup steps. Two layouts for review (a new design gets two
// variants): `rows` (each cloud a disclosure row, the shipped default) and `tabs` (one cloud at a time behind a
// segmented control), plus signed out and a refused read.
import { componentEntry } from "../../../gallery/format";
import type { CloudCredentialsState } from "../ops";
import type { CloudCredentialsLayout } from "./CloudCredentialsCard";

type Props = { state: CloudCredentialsState | null; layout?: CloudCredentialsLayout };

const team = "team_0123456789abcdef0123";
const issuer = `https://cloud-api.example.test/oidc/teams/${team}`;
const ready: CloudCredentialsState = {
  available: true,
  info: {
    team,
    issuer,
    discovery_url: `${issuer}/.well-known/openid-configuration`,
    jwks_url: `${issuer}/.well-known/jwks.json`,
    signing_alg: "RS256",
    subject_format: `team:${team}:machine:<machine>`,
    default_ttl_seconds: 600,
    max_ttl_seconds: 3600,
  },
};

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { CloudCredentialsView } = await import("./CloudCredentialsCard");
  return function CloudCredentials({ state, layout }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <CloudCredentialsView state={state} layout={layout} onRefresh={() => {}} />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.cloud-credentials",
  title: "Cloud credentials",
  area: "Settings",
  height: 720,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/CloudCredentialsCard.tsx#CloudCredentialsView"],
  load,
  // The app loads the page's Tailwind beside its sheets (main.tsx); the card's code blocks, spacing and
  // overflow are utilities, so without it the gallery shows them unstyled. Its rules sit in cascade
  // layers, so the order against page.css does not matter.
  styles: () => Promise.all([import("../page.css"), import("../tailwind.css")]),
  variants: {
    rows: { note: "Layout A: the issuer's URLs, then each cloud as a disclosure row.", props: { state: ready } },
    tabs: {
      note: "Layout B: the issuer's URLs, then one cloud's steps at a time behind a segmented control.",
      props: { state: ready, layout: "tabs" },
    },
    "signed-out": { note: "Signed out of cmux Cloud: the card explains.", props: { state: { available: false } } },
    error: {
      note: "The issuer read was refused or unreachable: the error and Try Again.",
      props: { state: { available: true, error: "unreachable" } },
    },
  },
});
