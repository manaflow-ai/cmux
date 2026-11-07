// l10n-allow-file: synthetic checks, rules and people for overflow scenes.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import { PullRequestChip } from "../agent-session/acpmux/header/PullRequestChip";
import { RulesNotice, type ForumRule } from "../agent-session/acpmux/RulesNotice";
import { PeoplePicker } from "../pages/home-channels/PeoplePicker";
import { createStrings } from "../pages/shared/i18n";
import table from "../pages/home-channels/generated/strings.json";

type Props = { kind: "checks" | "rules" | "people" };
const strings = createStrings(table, ["en"]);
const rules: ForumRule[] = Array.from({ length: 40 }, (_, index) => ({
  id: `rule-${index}`,
  key: `review-${index}`,
  body: `Review step ${index} before submitting the change.`,
  author: { kind: "person", account: "demo" },
  created: index,
  acks: [],
}));
const people = rules.map((rule, index) => ({
  id: rule.id,
  name: `Person ${index}`,
  kind: "human" as const,
  chief: false,
}));

function Overflow({ kind }: Props) {
  const [picked, setPicked] = useState<string[]>([]);
  return (
    <section className="acpmux-shell" style={{ height: "100%", padding: 16 }}>
      {kind === "checks" && (
        <PullRequestChip
          pullRequest={{
            url: "https://github.com/example/project/pull/42",
            number: 42,
            title: "Review scroll edges",
            state: "open",
            review: "approved",
            mergeable: "mergeable",
            checks: { state: "passing", passed: 40, total: 40 },
            checkList: rules.map((rule) => ({ name: rule.key, state: "passed" })),
          }}
        />
      )}
      {kind === "rules" && <RulesNotice rules={rules} />}
      {kind === "people" && <PeoplePicker people={people} picked={picked} onPicked={setPicked} strings={strings} />}
    </section>
  );
}

export default componentEntry<Props>({
  id: "ui.secondary-list-overflow",
  title: "Capped checks, rules and people",
  area: "Lists",
  pane: true,
  height: 420,
  widths: { normal: 640 },
  covers: [
    "agent-session/acpmux/header/PullRequestChip.tsx#PullRequestChip",
    "agent-session/acpmux/RulesNotice.tsx#RulesNotice",
    "pages/home-channels/PeoplePicker.tsx#PeoplePicker",
  ],
  load: async () => Overflow,
  styles: () =>
    Promise.all([
      import("../agent-session/acpmux/styles.css"),
      import("../agent-session/acpmux/header/header.css"),
      import("../pages/home-channels/styles.css"),
      import("../pages/home-channels/ledger.css"),
    ]),
  variants: {
    checks: {
      props: { kind: "checks" },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-header-pr" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pr-status"));
      },
    },
    rules: {
      props: { kind: "rules" },
      play: async (ctx) => {
        await ctx.click({ selector: '[data-notice-action="rules"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-rules-list"));
      },
    },
    people: { props: { kind: "people" } },
  },
});
