import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { NewTabHeadline, type NewTabHeadlineProps } from "./NewTabHeadline";

const props: NewTabHeadlineProps = {
  projects: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
  noProject: false,
  onPick: () => {},
  onNoProject: () => {},
};

/// The question's text: the h1 with its tags stripped.
const question = (overrides: Partial<NewTabHeadlineProps>) =>
  renderToStaticMarkup(<NewTabHeadline {...props} {...overrides} />)
    .match(/<h1[^>]*>(.*?)<\/h1>/s)![1]!
    .replace(/<[^>]+>/g, "");

test("the headline names the project and the machine the chat starts on", () => {
  expect(question({ folder: "/Users/you/src/cmux", machine: "studio-mini" })).toBe(
    "What should we work on in cmux on studio-mini?",
  );
});

test("with no project picked it still names the machine", () => {
  expect(question({ machine: "studio-mini" })).toBe("What should we work on at studio-mini?");
});

test("with no machine it asks as before", () => {
  expect(question({ folder: "/Users/you/src/cmux" })).toBe("What should we work on in cmux?");
  expect(question({})).toBe("What should we work on?");
});
