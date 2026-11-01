// l10n-allow-file: Markdown rendering regression fixtures.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const reply = [
  'key="$(hybrid_ref_capture.py key .)", then gh api name=hybrid-ref-capture-$key',
  "$PATH and $HOME; cost $5 and $10; $(cmd); ${HOME}",
  "Real math still typesets: $x^2$ and $\\alpha$ and \\(E=mc^2\\).",
  "Code stays literal: `$x^2$` and `echo $PATH`.",
].join("\n\n");

export default agentPaneEntry({
  id: "agent-pane.shell-math",
  title: "Shell dollar signs beside math",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/Markdown.tsx"],
  variants: {
    transcript: {
      note: "Shell substitution, variables and currency remain text; explicit equations still use KaTeX.",
      snapshot: chat([user("Keep this shell command readable beside the equations.", 4), assistant(reply, 2)]),
    },
  },
});
