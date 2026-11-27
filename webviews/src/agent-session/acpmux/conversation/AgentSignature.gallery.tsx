// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent dot signature on the running line (appearance.agentSignature, off by default): the
// chat's glyph from acpmux `session/signature` before "Working for 42s". Leo (2026-11-19): "some of
// them maybe just as customizations lol if it affects default looks". Off is today's line.
// Tests: webviews/test/agent-dot-signature.test.tsx.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { AgentSignatureContext, type AgentSignatureSource, configureAgentSignature } from "./agentSignatureModel";
import { Thinking } from "./Thinking";

type Props = { on: boolean; glyph: "dust" | "ember" };

const GLYPHS = {
  dust: {
    seed: 0.37,
    variant: "Dust",
    accent: "#3D7BFF",
    drift: 1,
    dots: [
      { x: 0.31, y: 0.52, r: 0.11, phase: 0.4 },
      { x: 0.62, y: 0.35, r: 0.08, phase: 0.1 },
      { x: 0.55, y: 0.7, r: 0.13, phase: 0.9 },
      { x: 0.4, y: 0.25, r: 0.07, phase: 0.6 },
      { x: 0.72, y: 0.6, r: 0.09, phase: 0.2 },
    ],
  },
  ember: {
    seed: 0.81,
    variant: "Ember",
    accent: "#FF7A3D",
    drift: 1.6,
    dots: [
      { x: 0.5, y: 0.2, r: 0.09, phase: 0 },
      { x: 0.25, y: 0.4, r: 0.12, phase: 0.15 },
      { x: 0.75, y: 0.42, r: 0.1, phase: 0.3 },
      { x: 0.35, y: 0.72, r: 0.08, phase: 0.45 },
      { x: 0.65, y: 0.75, r: 0.14, phase: 0.6 },
      { x: 0.5, y: 0.5, r: 0.06, phase: 0.75 },
      { x: 0.2, y: 0.62, r: 0.07, phase: 0.9 },
    ],
  },
};

function Fixture({ on, glyph }: Props) {
  // The host's theme push, before the line first renders.
  useState(() => configureAgentSignature(on));
  const [since] = useState(() => Date.now() - 42_000);
  const [source] = useState<AgentSignatureSource>(() => ({
    sessionId: `gallery-signature-${glyph}`,
    fetch: async () => ({ signatures: { [`gallery-signature-${glyph}`]: GLYPHS[glyph] } }),
  }));
  return (
    <div style={{ padding: 24, maxWidth: 640 }}>
      <AgentSignatureContext.Provider value={source}>
        <Thinking since={since} doing="Read conversation.css" doingAt={since + 30_000} below turnTotal />
      </AgentSignatureContext.Provider>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.agent-signature",
  title: "Live line: agent dot signature",
  area: "Agent pane",
  pane: true,
  height: 90,
  widths: { narrow: 360, normal: 560 },
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  covers: ["agent-session/acpmux/conversation/AgentSignature.tsx#AgentSignature"],
  variants: {
    off: {
      props: { on: false, glyph: "dust" },
      note: "The default: the setting is off, so the line is today's and acpmux is asked nothing.",
    },
    dust: {
      props: { on: true, glyph: "dust" },
      note: "On: five dots in the chat's Dust accent at 0.85 before the words, each drifting on its own phase.",
    },
    ember: {
      props: { on: true, glyph: "ember" },
      note: "Another chat: seven dots in its Ember accent, a wider drift.",
    },
  },
  load: () => Promise.resolve(Fixture),
});
