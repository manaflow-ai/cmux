// CSS injected into the @pierre/trees shadow root (options.unsafeCSS) so the file tree
// matches Codex: 13px system font, 29px rows, 8px gutters, quiet selection fill, and the
// focused-parent indent guide.
import { codexColors as c } from "./theme";

export const treeUnsafeCSS = /* css */ `
:host {
  --trees-font-family-override: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
  --trees-font-size-override: 13px;
  --trees-bg-override: ${c.bg};
  --trees-fg-override: #f8f8f3;
  --trees-fg-muted-override: #a8a9a3;
  --trees-selected-fg-override: #f8f8f3;
  --trees-selected-bg-override: #32332d;
  --trees-bg-muted-override: #32332d;
  --trees-padding-inline-override: 8px;
  --trees-item-margin-x-override: 0px;
  --trees-item-padding-x-override: 2px;
  --trees-item-row-gap-override: 5.5px;
  --trees-border-radius-override: 6px;
  --trees-focus-ring-width-override: 0px;
  --trees-indent-guide-bg-override: #3f403a;
  --trees-scrollbar-gutter-override: 6px;
}
[data-type="item"][data-item-focused="true"]::before { display: none; }
/* Codex indents 8.75px per level (Pierre: 21.5px) and nudges files 3.75px further; the
   guide line sits under the parent's chevron. */
[data-item-section="spacing"] { padding-left: 0; margin-right: -5.5px; }
[data-type="item"][data-item-type="file"] > [data-item-section="spacing"] { padding-right: 3.75px; }
[data-item-section="spacing-item"],
[data-item-section="spacing-item"] + [data-item-section="spacing-item"] {
  box-sizing: border-box;
  width: 8.75px;
  margin: 0;
  padding-left: 0;
  border-left: 0;
  background: linear-gradient(var(--trees-indent-guide-bg), var(--trees-indent-guide-bg)) 7.25px 0 / 1px 100% no-repeat;
  transform: none;
}
[data-item-section="content"] { color: #f8f8f3; flex: 0 1 auto; text-overflow: clip; }
[data-item-section="decoration"] { flex: 1 0 auto; min-width: max-content; font-size: 12px; }
[data-item-section="decoration"] { margin-right: 1.75px; }
[data-item-section="decoration"] > span { gap: 4.5px; overflow: visible; }
[data-icon-name="file-tree-icon-chevron"] { width: 10.5px; height: 10.5px; color: #84848a; }

/* Codex clips long names at the end; Pierre middle-truncates ("workspac…sh"). Replace the
   truncating label with the row's aria-label (its name) drawn by ::after, ordered before
   the decoration lane. Flattened rows ("infra / tsadmin") keep Pierre's own markup. */
[data-type="item"] > [data-item-section="decoration"] { order: 2; }
[data-type="item"]:has(> [data-item-section="content"] > [data-truncate-group-container]) > [data-item-section="content"] { display: none; }
[data-type="item"]:has(> [data-item-section="content"] > [data-truncate-group-container])::after {
  content: attr(aria-label);
  order: 1;
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  white-space: nowrap;
  color: #f8f8f3;
}
[data-type="item"][data-item-type="file"]:not([data-item-selected="true"])::after { color: #8f908a; }
`;
