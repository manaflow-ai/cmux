// l10n-allow-file: synthetic gallery receipts and comparison marks, never a real conversation.
// Session Info's Outputs with what the chat produced (producedLinks.ts): the pull requests, issues and
// commits it opened, merged, filed or pushed, beside the files it made (Leo, 2026-11-07: "at least do
// what [the reference] has here with outputs. i think that'd be real good. esp since we have so many
// linked things here"). Three layouts compared on one busy session (eight produced, three files) plus
// the reference's short list and the empty state.
import { componentEntry } from "../../../gallery/format";
import type { ProducedLink } from "./producedLinks";
import type { OutputFile } from "./chatOutputs";

type Layout = "links-first" | "files-first" | "state";
type Props = { layout: Layout; produced?: number; files?: number; repository?: string };

const pr = (repo: string, number: number, merged = false): ProducedLink => ({
  key: `${repo}#${number}`,
  kind: "pullRequest",
  repo,
  number,
  url: `https://github.com/${repo}/pull/${number}`,
  ...(merged ? { merged: true as const } : {}),
});
const issue = (repo: string, number: number): ProducedLink => ({
  key: `${repo}#${number}`,
  kind: "issue",
  repo,
  number,
  url: `https://github.com/${repo}/issues/${number}`,
});
const PRODUCED: ProducedLink[] = [
  pr("manaflow-ai/cmux", 37147, true),
  pr("manaflow-ai/cmuxterm-hq", 923),
  issue("manaflow-ai/cmuxterm-hq", 7395),
  pr("manaflow-ai/cmux", 37917),
  issue("manaflow-ai/cmux", 36996),
  {
    key: "commit:manaflow-ai/cmux@5d6e7f8",
    kind: "commit",
    repo: "manaflow-ai/cmux",
    sha: "5d6e7f81c2a9",
    url: "https://github.com/manaflow-ai/cmux/commit/5d6e7f81c2a9",
  },
  pr("manaflow-ai/leo-workspace", 917, true),
  issue("manaflow-ai/leo-workspace", 915),
];
const FILES: OutputFile[] = [
  { path: "/demo/repo/report.pdf", displayPath: "report.pdf" },
  { path: "/demo/repo/out/latency.csv", displayPath: "out/latency.csv" },
  { path: "/Users/me/Desktop/chart.png", displayPath: "~/Desktop/chart.png" },
];

export default componentEntry<Props>({
  id: "agent-pane.session-info-produced-outputs",
  title: "Session Info Outputs: pull requests, issues and commits",
  area: "Agent pane",
  pane: true,
  covers: [
    "agent-session/acpmux/session-info/OutputsSection.tsx#OutputsSection",
    "agent-session/acpmux/session-info/OutputsSection.tsx#ProducedRow",
  ],
  load: async () => {
    const [{ useState }, { OutputsSection, ProducedRow }, { SessionInfoSection }, { FileKindIcon }] = await Promise.all(
      [import("react"), import("./OutputsSection"), import("./SessionInfoSection"), import("../chips/FileKindIcon")],
    );
    return function ProducedOutputs({ layout, produced = PRODUCED.length, files = FILES.length, repository }: Props) {
      const [open, setOpen] = useState(true);
      const [opened, setOpened] = useState("");
      const links = PRODUCED.slice(0, produced);
      const made = FILES.slice(0, files);
      const count = links.length + made.length;
      // The comparisons draw their own list; the chosen layout is the shipped section.
      const compared =
        layout === "links-first" ? undefined : (
          <ul className="acpmux-session-info-list" data-section="outputs">
            {layout === "files-first" &&
              made.map((file) => (
                <li key={file.path}>
                  <div className="acpmux-session-info-row">
                    <FileKindIcon path={file.path} size={12} className="acpmux-row-glyph" />
                    <span className="acpmux-session-info-row__name">{file.displayPath}</span>
                  </div>
                </li>
              ))}
            {links.map((link) => (
              <li key={link.key} style={{ display: "flex", alignItems: "center" }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <ProducedRow link={link} repository={repository} onOpen={setOpened} />
                </div>
                {layout === "state" && link.kind === "pullRequest" && (
                  <span className="acpmux-session-info-row__end">{link.merged ? "Merged" : "Open"}</span>
                )}
              </li>
            ))}
            {layout === "state" &&
              made.map((file) => (
                <li key={file.path}>
                  <div className="acpmux-session-info-row">
                    <FileKindIcon path={file.path} size={12} className="acpmux-row-glyph" />
                    <span className="acpmux-session-info-row__name">{file.displayPath}</span>
                  </div>
                </li>
              ))}
          </ul>
        );
      return (
        <div data-produced-outputs={layout} style={{ padding: 16 }}>
          {count === 0 ? (
            <p data-empty-outputs="" style={{ opacity: 0.6, margin: 0 }}>
              No Outputs section: the chat produced nothing.
            </p>
          ) : (
            <SessionInfoSection id="outputs" title="Outputs" open={open} onOpenChange={setOpen}>
              {compared ?? (
                <OutputsSection
                  produced={links}
                  repository={repository}
                  onOpenProduced={setOpened}
                  files={made}
                  artifacts={0}
                  onOpenFile={setOpened}
                />
              )}
            </SessionInfoSection>
          )}
          <output data-opened="">{opened}</output>
        </div>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./sessionInfo.css")]),
  widths: { narrow: 320, normal: 420, wide: 560 },
  height: 520,
  variants: {
    "links-first": {
      props: { layout: "links-first", repository: "manaflow-ai/cmux" },
      note: "Chosen. What the chat published leads: eight pull requests, issues and a commit, then its three files, five shown and Show 6 more on the house fold. A row is the link glyph and a short label (PR #37147, #7395, 5d6e7f8); another repository's row names it, muted. A click opens the App's GitHub page for a pull request, else github.com in a cmux tab. No state word: the transcript only knows what the chat did, so a state would go stale once someone else merges.",
    },
    "links-first-open": {
      props: { layout: "links-first", repository: "manaflow-ai/cmux" },
      note: "The chosen layout after Show more: every row, the box grown on the settle curve.",
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-session-info-fold" });
        await ctx.waitFor(() => ctx.document.querySelectorAll('[data-section="outputs"] > li').length >= 11);
      },
    },
    "files-first": {
      props: { layout: "files-first", repository: "manaflow-ai/cmux" },
      note: "Comparison: the files first, then the links. In a coding session the files are rare and the pull requests are the work, so the work lands behind Show more.",
    },
    state: {
      props: { layout: "state", repository: "manaflow-ai/cmux" },
      note: "Comparison: a trailing Merged / Open on pull requests. Changes already shows live state with checks; here it is only what the transcript saw, so it goes stale.",
    },
    reference: {
      props: { layout: "links-first", produced: 6, files: 0, repository: "manaflow-ai/cmux" },
      note: "The reference's shape: six produced rows. A fold that would hold back one row shows it instead, so all six show.",
    },
    empty: {
      props: { layout: "links-first", produced: 0, files: 0 },
      note: "Empty: a chat that produced nothing draws no Outputs section (the panel lists only what has rows).",
    },
  },
});
