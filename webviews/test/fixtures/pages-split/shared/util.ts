// A module alpha, beta and the agent pane fixture import (test/pages-split-build.test.ts): the pages use
// forPages only, the pane forPane only, so a page that loaded forPane would carry the pane's code.
export const forPages = (name: string) => `page ${name}`;
export const forPane = (name: string) => `pane ${name} `.repeat(64);
