// The host's `availability` (Swift `SettingsAvailability`): the page leaves out a
// row whose feature is off (Energy Saver while `energySaver` is off) and a choice this Mac cannot use
// (Energy Saver's On Battery on a Mac with no battery), keeps the current value, and search never
// finds a hidden row. The schema keeps every row and choice.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { withShownChoices } from "./availability";
import { categoryById } from "./categories";
import type { SchemaRow } from "./schema";
import { filterRows } from "./search";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle } = await import("./testing");

const generalRows = categoryById("general").groups.flatMap((group) => group.rows);
/** A General choice row with several values: the page draws each one as a radio or an option. */
const choiceRow = generalRows.find(
  (row) => row.kind === "choice" && (row.choices?.length ?? 0) >= 2 && row.default !== null,
) as SchemaRow;
const otherChoice = choiceRow.choices!.find((choice) => choice.value !== choiceRow.default)!.value;

const offered = (container: HTMLElement, key: string) =>
  [...container.querySelectorAll(`[data-row-key="${key}"] input[type="radio"], [data-row-key="${key}"] option`)].map(
    (element) => (element as HTMLInputElement | HTMLOptionElement).value,
  );

test("a hidden choice is left out, the current value is always kept, and nothing hidden is the same row", () => {
  const values = choiceRow.choices!.map((choice) => choice.value);
  const shown = withShownChoices(choiceRow, [otherChoice], choiceRow.default);
  expect(shown.choices!.map((choice) => choice.value)).toEqual(values.filter((value) => value !== otherChoice));
  expect(withShownChoices(choiceRow, [otherChoice], otherChoice).choices!.map((choice) => choice.value)).toEqual(
    values,
  );
  expect(withShownChoices(choiceRow, [], choiceRow.default)).toBe(choiceRow);
  expect(withShownChoices(choiceRow, ["__not_a_choice__"], choiceRow.default)).toBe(choiceRow);
});

test("search never lists a hidden row", () => {
  const query = choiceRow.key;
  const found = (hidden?: ReadonlySet<string>) =>
    filterRows({ query, valueOf: () => undefined, hidden }).flatMap((group) => group.rows.map((row) => row.key));
  expect(found()).toContain(choiceRow.key);
  expect(found(new Set([choiceRow.key]))).not.toContain(choiceRow.key);
});

test("the page follows the host: a hidden row goes, a hidden choice goes, and both come back", async () => {
  const page = await renderPage({ path: "/settings/general" });
  const row = () => page.container.querySelector(`[data-row-key="${choiceRow.key}"]`);
  expect(row()).not.toBeNull();
  expect(offered(page.container, choiceRow.key)).toContain(otherChoice);

  await act(async () => {
    page.provider.setHost({
      ...page.provider.host,
      availability: { hidden_choices: { [choiceRow.key]: [otherChoice] } },
    });
  });
  await settle();
  expect(row()).not.toBeNull();
  expect(offered(page.container, choiceRow.key)).not.toContain(otherChoice);

  await act(async () => {
    page.provider.setHost({ ...page.provider.host, availability: { hidden_rows: [choiceRow.key] } });
  });
  await settle();
  expect(row()).toBeNull();

  await act(async () => {
    page.provider.setHost({ ...page.provider.host, availability: null });
  });
  await settle();
  expect(offered(page.container, choiceRow.key)).toContain(otherChoice);
  page.unmount();
});
