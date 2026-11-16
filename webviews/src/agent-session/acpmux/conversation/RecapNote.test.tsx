// l10n-allow-file: recap fixture text.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { RecapNote } from "./RecapNote";
import { recapPoints } from "./recapPoints";

test("plain recap sentences become bullets without splitting file names", () => {
  expect(recapPoints("Update foo.rs. Review is blocked. Next: split the PR.", "en")).toEqual([
    "Update foo.rs.",
    "Review is blocked.",
    "Next: split the PR.",
  ]);
});

test("existing bullet points keep their text without a second marker", () => {
  expect(recapPoints("- Fix merged. Checks passed.\n- Run the app.", "en")).toEqual([
    "Fix merged. Checks passed.",
    "Run the app.",
  ]);
});

test("recaps use the current language's sentence boundaries", () => {
  expect(recapPoints("修正しました。次に確認します。", "ja")).toEqual(["修正しました。", "次に確認します。"]);
  expect(recapPoints(" \n ", "en")).toEqual([]);
});

test("a recap uses one accessible note, a list, and one dismiss control", () => {
  const html = renderToStaticMarkup(
    <RecapNote recap={{ key: "chat:1", text: "The fix is ready. Next: review it." }} onDismiss={() => {}} />,
  );
  expect(html.match(/role="note"/g)).toHaveLength(1);
  expect(html.match(/<li>/g)).toHaveLength(2);
  expect(html.match(/cv-recap__close/g)).toHaveLength(1);
});

test("the workbench recording folds four recaps into one current summary", async () => {
  const { recapRecording } = await import("../../../gallery/parity/awayRecap.gallery");
  const { rowsFromRecording } = await import("../../../gallery/fixtures/recording");
  const rows = await rowsFromRecording(await recapRecording.events(), "claude");
  const recaps = rows.filter((row) => row.kind === "recap");
  expect(recaps).toHaveLength(1);
  expect(recapPoints(recaps[0]!.recap!.text, "en")).toEqual([
    "Agents now open files in the correct workspace.",
    "Review is waiting on one routing fix.",
    "Next: split the PR or keep it together.",
  ]);
});
