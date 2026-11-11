// The `/` list in a Chief chat's message box (MessageComposer SkillMenu, chiefSkills.ts): the
// Chief's skills for a typed `/`, filtered by what follows, and its loading and failed rows.
import { useEffect, useMemo, useRef } from "react";
import { componentEntry } from "../../../gallery/format";
import type { MarkdownFieldElement } from "../../../agent-session/acpmux/MarkdownField";
import type { PageClient } from "../../shared/pageClient";
import "../../home-channels/paneStrings";
import { ChiefSkills, CHIEF_SKILLS_OP } from "./chiefSkills";
import { MessageComposer } from "./MessageComposer";
import { createTranscriptStrings } from "./strings";

type Props = { typed: string; answer: "skills" | "loading" | "failed" | "none" };

const SKILLS = [
  { name: "cmux-views", description: "Open and arrange cmux views from the Chief", source: "chief" },
  { name: "triage", description: "Sort the inbox into needs-you, waiting and done", source: "chief" },
  { name: "emil-prototype", description: "Prototype a UI with Emil's motion rules", source: "claude" },
  { name: "verify-implementation", description: "Check a change against its acceptance criteria", source: "claude" },
  { name: "ai-sdk", description: "Answer questions about the Vercel AI SDK", source: "plugin:vercel" },
];

const strings = createTranscriptStrings(["en"]);

/** A host whose `chief.skills` answers as the variant says (a loading one never answers). */
function galleryHost(answer: Props["answer"]): PageClient {
  return {
    call: (op: string) => {
      if (op !== CHIEF_SKILLS_OP) return Promise.reject(new Error(op));
      if (answer === "loading") return new Promise(() => {});
      if (answer === "failed") return Promise.reject(new Error("the Chief is not running"));
      return Promise.resolve({ skills: answer === "none" ? [] : SKILLS });
    },
    subscribe: () => Promise.reject(new Error("none")),
    handle: () => () => {},
  } as unknown as PageClient;
}

function ChiefSlashGallery({ typed, answer }: Props) {
  const box = useRef<HTMLDivElement | null>(null);
  const skills = useMemo(() => new ChiefSkills(galleryHost(answer), "gallery"), [answer]);
  // Types the variant's text once the field is made, as the person would.
  useEffect(() => {
    const node = box.current;
    if (!node) return;
    let done = false;
    const type = () => {
      const field = node.querySelector<MarkdownFieldElement>(".acpmux-md-field")?.acpmuxMarkdownField;
      if (done || !field || !node.querySelector(".ProseMirror")) return;
      done = true;
      field.focus();
      field.insertTyped(typed);
    };
    const watch = new MutationObserver(type);
    watch.observe(node, { childList: true, subtree: true });
    type();
    return () => watch.disconnect();
  }, [typed]);
  return (
    <div ref={box} style={{ display: "flex", height: "100%", flexDirection: "column", justifyContent: "flex-end" }}>
      <MessageComposer
        strings={strings}
        sendEnabled
        onSend={async () => true}
        chief={{ working: false, continueAvailable: false, onStop: () => {}, onContinue: () => {}, skills }}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "home.messages-chief-slash",
  title: "Chief chat: / skills list",
  area: "Home and Chief",
  height: 420,
  widths: { narrow: 360, normal: 560, wide: 820 },
  covers: ["pages/home-messages/transcript/MessageComposer.tsx#MessageComposer"],
  load: async () => ChiefSlashGallery,
  styles: () => Promise.all([import("../../home-channels/styles.css"), import("./transcript.css")]),
  variants: {
    all: {
      note: "/ at the message's start: every skill the Chief's host offers, the Chief's own first, where each comes from.",
      props: { typed: "/", answer: "skills" },
    },
    filtered: { note: "/tri keeps the skills it matches, the typed letters in bold.", props: { typed: "/tri", answer: "skills" } },
    loading: { note: "The list is on its way: Loading skills…", props: { typed: "/", answer: "loading" } },
    failed: { note: "The Chief's host did not answer: it says so, never an empty list.", props: { typed: "/", answer: "failed" } },
    none: { note: "A Chief with no skills yet.", props: { typed: "/", answer: "none" } },
  },
});
