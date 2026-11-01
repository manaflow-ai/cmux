import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { setChatDisplay } from "../chatDisplay";
import { translate } from "../i18n";
import { presentationRow } from "./presentationRow";
import { presentationOf, resetPresentations } from "../conversation/presentation";
import { resetTranscriptViews, setTranscriptView, transcriptViewOf } from "../conversation/transcriptView";
import { AssistantPresentation, PresentationContext } from "../conversation/PresentationContext";

afterEach(() => {
  resetPresentations();
  resetTranscriptViews();
  setChatDisplay({});
});

test("the existing menu switches presentation while retaining this session's transcript disclosure choice", () => {
  setTranscriptView("chat", "verbose");
  const row = presentationRow("chat", translate)!;
  expect(row.key).toBe("transcriptView");
  expect(row.children!.find((child) => child.key === "presentation.transcript")?.checked).toBe(true);
  row.children!.find((child) => child.key === "presentation.messages")!.onSelect();
  expect(presentationOf("chat")).toBe("messages");
  expect(presentationOf("another-chat")).toBe("transcript");
  expect(transcriptViewOf("chat")).toBe("verbose");
  const messages = presentationRow("chat", translate)!;
  expect(messages.children!.find((child) => child.key === "presentation.messages")?.checked).toBe(true);
  messages.children!.find((child) => child.key === "presentation.transcript")!.onSelect();
  expect(transcriptViewOf("chat")).toBe("verbose");
  expect(presentationRow(undefined, translate)).toBeUndefined();
});

test("Messages wraps the same rich reply in shared bubble glass; Transcript keeps the existing markup", () => {
  const reply = (
    <p>
      Read the <strong>result</strong>.
    </p>
  );
  const render = (value: "messages" | "transcript") =>
    renderToStaticMarkup(
      <PresentationContext.Provider value={value}>
        <AssistantPresentation>{reply}</AssistantPresentation>
      </PresentationContext.Provider>,
    );
  const transcript = render("transcript");
  expect(transcript).toBe("<p>Read the <strong>result</strong>.</p>");
  expect(render("messages")).toBe(`<div class="cv-user__bubble ui-glass cv-assistant-bubble">${transcript}</div>`);
});
