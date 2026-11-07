// l10n-allow-file: gallery fixtures, not shipped UI.
// The GitHub page (cmux-page://cmux.github/): the same GitHubPage main.tsx mounts, over the mock
// `cmux.github.*` provider instead of the host bridge.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { GitHubPage } from "./GitHubPage";
import { MockGitHubProvider, mockPullRequest, MOCK_URL } from "./mockProvider";
import { GitHubStore } from "./store";
import type { PullRequestReply } from "./types";

type Props = { answer?: PullRequestReply };

function GitHubGallery({ answer }: Props) {
  const [store] = useState(() => new GitHubStore(new MockGitHubProvider(answer), () => false));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.route(`#/pull?url=${encodeURIComponent(MOCK_URL)}`);
    return () => store.stop();
  }, [store]);
  // A fixed clock, so every capture says the same age.
  return <GitHubPage store={store} strings={strings} now={() => Date.parse("2026-11-05T03:00:00Z")} />;
}

export default componentEntry<Props>({
  id: "pages.github",
  title: "GitHub pull request",
  area: "Pages",
  experimental: true,
  height: 760,
  widths: { narrow: 360, normal: 640, wide: 900 },
  covers: ["page:cmux.github", "pages/github/GitHubPage.tsx"],
  load: async () => GitHubGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    open: { note: "An open pull request with failing, pending and base-red checks.", props: {} },
    merged: {
      note: "Merged and approved, every check passed.",
      props: {
        answer: {
          pullRequest: {
            ...mockPullRequest,
            state: "merged",
            review: "approved",
            checks: { state: "passed", passed: 7, total: 7 },
            checkList: mockPullRequest.checkList.map((check) => ({ ...check, state: "passed", onBase: false })),
          },
          fetchedAt: 1,
        },
      },
    },
    reading: { note: "The first read, before gh answered.", props: { answer: { pullRequest: null, reading: true } } },
    unavailable: {
      note: "gh could not read it (not signed in).",
      props: { answer: { pullRequest: null, reading: false } },
    },
  },
});
