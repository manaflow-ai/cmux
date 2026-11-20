import { experimentArm } from "../../../experiments/experiment";
import { t } from "../strings";
import { githubAppName } from "./githubAppName.experiment";

// Proper App names and GitHub logins from the naming proposal, not configured installation identities.
const candidates = {
  cmux: { name: "cmux", bot: "cmux[bot]" },
  agents: { name: "cmux agents", bot: "cmux-agents[bot]" },
  cloud: { name: "cmux Cloud", bot: "cmux-cloud[bot]" },
};

/** Presentation only: never changes the App slug or the host's connection actions. */
export function GitHubAppNamePreview() {
  const arm = experimentArm(githubAppName);
  if (arm === "off") return null;
  const candidate = candidates[arm];
  return (
    <div className="row accounts-row" data-github-name-preview={arm}>
      <div className="row-label">
        <span className="row-title">{t("settingsPage.githubNamePreview.title")}</span>
        <p className="row-help">{t("settingsPage.githubNamePreview.detail")}</p>
      </div>
      <div className="accounts-body">
        <span className="row-title">{candidate.name}</span>
        <p className="row-help" dir="ltr">
          {candidate.bot}
        </p>
      </div>
    </div>
  );
}
