import { renderToStaticMarkup } from "react-dom/server";
import { SkillsPage } from "./SkillsPage";
import { MockSkillsProvider, sampleEntries } from "./mockProvider";

test("renders the directory and harness state", () => {
  const html = renderToStaticMarkup(
    <SkillsPage
      client={new MockSkillsProvider()}
      initialEntries={sampleEntries}
    />,
  );
  expect(html).toContain("Skills, MCP servers and plugins");
  expect(html).toContain("Filesystem tools");
  expect(html).toContain("Sync");
});
