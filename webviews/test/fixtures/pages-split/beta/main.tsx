// A page of the split build test (test/pages-split-build.test.ts): it and alpha share React and util.
import { createElement } from "react";
import { forPages } from "../shared/util";

export const beta = createElement("p", null, forPages("beta"));
