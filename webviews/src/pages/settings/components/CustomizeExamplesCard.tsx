import { useStore } from "../context";
import { ActionRow } from "./ActionRow";
import { Button } from "../../../ui/Button";
import { t } from "../strings";

type Example = {
  id: string;
  title: string;
  description: string;
  file: string;
  app?: string;
};

const EXAMPLES: Example[] = [
  {
    id: "my-prs",
    title: "My PRs",
    description: "Pull requests and review requests in the sidebar.",
    file: "skills/cmux-customization/templates/my-prs",
  },
  {
    id: "threads",
    title: "Agent threads",
    description: "Live agent state, grouped with needs-you first.",
    file: "skills/cmux-customization/templates/threads",
  },
  {
    id: "quick-links",
    title: "Quick links",
    description: "Saved links as a sidebar section and a pane.",
    file: "samples/apps/quick-links",
    app: "manaflow-ai/quick-links",
  },
  {
    id: "github-prs",
    title: "GitHub PRs",
    description: "A live pull-request list with browser actions.",
    file: "samples/apps/github-prs",
    app: "cmux/github-prs",
  },
  {
    id: "session-prs",
    title: "Session branch PRs",
    description: "Pull requests for the current chat's branch.",
    file: "samples/apps/session-prs",
    app: "cmux/session-prs",
  },
  {
    id: "running-agents",
    title: "Running agents",
    description: "Agent state with a click to focus its terminal.",
    file: "samples/apps/running-agents",
    app: "cmux/running-agents",
  },
  {
    id: "command-buttons",
    title: "Command buttons",
    description: "Your cmux-next.json actions in a sidebar section.",
    file: "skills/cmux-customization/templates/command-button",
  },
  {
    id: "design-links",
    title: "Design links",
    description: "Figma, Linear, Notion, and Docs links saved locally.",
    file: "skills/cmux-customization/templates/design-links",
  },
  {
    id: "clock-weather",
    title: "Clock and weather",
    description: "Timers, storage, and a scoped weather request.",
    file: "skills/cmux-customization/templates/clock-weather",
  },
  {
    id: "standup",
    title: "Standup notes",
    description: "Storage-backed add, list, and clear commands.",
    file: "samples/apps/standup",
    app: "manaflow-ai/standup",
  },
];

export function CustomizeExamplesCard() {
  const store = useStore();
  return (
    <section className="group" data-card="customization-examples">
      <h3 className="group-title">{t("settingsPage.customization.examples")}</h3>
      <p className="row-help">{t("settingsPage.customization.help")}</p>
      <div className="rows">
        {EXAMPLES.map((example) => (
          <ActionRow key={example.id} title={example.title} help={`${example.description} · ${example.file}`}>
            {example.app ? (
              <Button type="button" className="button" onClick={() => store.openAppStore(example.app!)}>
                {t("settingsPage.customization.install")}
              </Button>
            ) : (
              <Button type="button" className="button" onClick={() => store.openNative("cmuxJSON")}>
                {t("settingsPage.customization.openSource")}
              </Button>
            )}
          </ActionRow>
        ))}
      </div>
    </section>
  );
}
