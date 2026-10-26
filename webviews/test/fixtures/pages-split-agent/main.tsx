// The agent pane of the split build test (test/pages-split-build.test.ts), outside the pages folder:
// it shares React with alpha and beta, and imports from their util and alpha's lazy module what no
// page uses, which must stay in the pane's own files.
import { createElement } from "react";
import { forPane } from "../pages-split/shared/util";

export const agent = createElement("p", null, forPane("agent"));
void import("../pages-split/alpha/lazy");
