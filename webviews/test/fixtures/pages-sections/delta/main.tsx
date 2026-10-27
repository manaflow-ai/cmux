// A page without sections that shares code with gamma and its sections (test/pages-split-build.test.ts).
import { a } from "../shared/a";
import { c } from "../shared/c";
import { d } from "../shared/d";

export const delta = [a("delta"), c, d].join(" ");
