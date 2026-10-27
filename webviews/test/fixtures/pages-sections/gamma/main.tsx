// A page with lazy sections (test/pages-split-build.test.ts), as Settings loads its sections.
import { a } from "../shared/a";

export const gamma = a("gamma");
export const sections = { one: () => import("./sections/One"), two: () => import("./sections/Two") };
