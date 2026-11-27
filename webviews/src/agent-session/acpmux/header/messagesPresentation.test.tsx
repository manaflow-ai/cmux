import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "../i18n";
import { AssistantPresentation } from "../conversation/PresentationContext";
import { PresentationContext } from "../conversation/presentationContextModel";
import { TurnFooter } from "../conversation/TurnRows";
import { TurnActionsContext } from "../conversation/turnActions";

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

test("Messages keeps failure recovery without its worked-for metadata", () => {
  const markup = renderToStaticMarkup(
    <PresentationContext.Provider value="messages">
      <TurnActionsContext.Provider value={{ retryFailed: async () => undefined }}>
        <TurnFooter
          row={{
            id: "failed",
            kind: "turnSummary",
            version: 1,
            at: 1000,
            status: "failed",
            error: "The request failed",
            durationMs: 5000,
            retryable: true,
          }}
        />
      </TurnActionsContext.Provider>
    </PresentationContext.Provider>,
  );
  expect(markup).toContain("cv-turn-error");
  expect(markup).toContain(`aria-label="${translate("turn.retry")}"`);
  expect(markup).not.toContain("cv-turn-summary");
  expect(markup).not.toContain("cv-turn-time");
});
