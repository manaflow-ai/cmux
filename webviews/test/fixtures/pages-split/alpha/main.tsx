// A page of the split build test (test/pages-split-build.test.ts): it and beta share React and util.
import { createElement } from "react";
import { forPages } from "../shared/util";

export const alpha = createElement("p", null, forPages("alpha"));
void import("./lazy");
