// The agent pane of the split build test (test/pages-split-build.test.ts): an entry of the pages'
// run outside the pages folder, which shares React with alpha and beta.
import { createElement } from "react";

export const agent = createElement("p", null, "agent");
void import("../pages-split/alpha/lazy");
