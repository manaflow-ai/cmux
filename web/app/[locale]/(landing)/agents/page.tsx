import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";
import { buildAlternates } from "../../../../i18n/seo";
import { LandingCTA } from "../landing-ui";
import { LandingFaq, LandingSchema } from "../landing-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/agents"),
  };
}

const AGENTS: { href: string; key: string }[] = [
  { href: "/claude-code-terminal", key: "claude" },
  { href: "/codex-cli", key: "codex" },
  { href: "/opencode", key: "opencode" },
  { href: "/gemini-cli", key: "geminiCli" },
  { href: "/aider", key: "aider" },
  { href: "/amp", key: "amp" },
  { href: "/cursor-cli", key: "cursorCli" },
];

export default function AgentsPage() {
  const t = useTranslations("landing.agents");
  const tl = useTranslations("landing.links");
  return (
    <>
      <LandingSchema
        namespace="landing.agents"
        path="/agents"
        agentsCrumb={false}
      />
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("agentsTitle")}</h2>
      <p>{t("agentsBody")}</p>
      <ul>
        {AGENTS.map((a) => (
          <li key={a.href}>
            <Link href={a.href} className="underline underline-offset-2">
              {tl(a.key)}
            </Link>
          </li>
        ))}
      </ul>

      <h2>{t("organizeTitle")}</h2>
      <p>{t("organizeBody")}</p>

      <h2>{t("notifyTitle")}</h2>
      <p>{t("notifyBody")}</p>

      <h2>{t("scriptTitle")}</h2>
      <p>{t("scriptBody")}</p>

      <LandingFaq namespace="landing.agents" />

      <LandingCTA
        related={[
          { href: "/claude-code-terminal", label: tl("claude") },
          { href: "/codex-cli", label: tl("codex") },
          { href: "/opencode", label: tl("opencode") },
          { href: "/docs/getting-started", label: tl("getStarted") },
        ]}
      />
    </>
  );
}
