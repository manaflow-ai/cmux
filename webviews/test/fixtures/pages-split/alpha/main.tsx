// A page of the split build test (test/pages-split-build.test.ts): it and beta share React.
import { createElement } from "react";

export const alpha = createElement("p", null, "alpha");
void import("./lazy");
