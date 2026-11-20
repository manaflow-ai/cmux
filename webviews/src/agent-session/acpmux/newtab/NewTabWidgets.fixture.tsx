// l10n-allow-file: gallery fixtures (sample widget content), not shipped UI.
// The New Tab widget grid on the in-memory widget host (widgetsMock.ts), as the gallery entries
// draw it: the real grid, tiles, edit mode and Add Widget sheet, with sample widgets.
import { useEffect, useState } from "react";
import type { WidgetTilePlacement } from "../../../apps/scene/widgetsClient";
import { MockWidgetsHost } from "../../../apps/scene/widgetsMock";
import { noChat } from "../../../gallery/fixtures/acpmux";
import type { AddWidgetLook } from "./AddWidgetGallery";
import { NewTabScreen } from "./NewTabScreen";
import type { ScreenTemplate } from "./templates";
import { NewTabWidgets, NewTabWidgetsHost, type WidgetTileLook } from "./NewTabWidgets";
import type { WidgetEditLook } from "./WidgetEditing";

export const FIXTURE_TILES: WidgetTilePlacement[] = [
  { instance: "w1", app: "cmux/clock", size: "small" },
  { instance: "w2", app: "cmux/weather", size: "small" },
  { instance: "w3", app: "cmux/todo", size: "medium" },
  { instance: "w4", app: "cmux/clock", size: "large" },
  { instance: "w5", app: "cmux/weather", size: "medium" },
];

export type WidgetFixtureProps = {
  tileLook?: WidgetTileLook;
  editLook?: WidgetEditLook;
  galleryLook?: AddWidgetLook;
  editing?: boolean;
  gallery?: boolean;
  /// The tile whose widget threw (let it crash: shown stale).
  stale?: string;
  tiles?: WidgetTilePlacement[];
};

export function NewTabWidgetsFixture({
  tileLook = "glass",
  editLook = "badge",
  galleryLook = "rows",
  editing = false,
  gallery = false,
  stale,
  tiles = FIXTURE_TILES,
}: WidgetFixtureProps) {
  const [host] = useState(() => new MockWidgetsHost(tiles));
  useEffect(() => {
    if (!stale) return;
    // After the tiles' first scenes: the daemon reports the widget's render threw.
    const timer = setTimeout(() => {
      const id = host.mountOf(stale);
      if (id) host.health(id, true);
    }, 50);
    return () => clearTimeout(timer);
  }, [host, stale]);
  return (
    <div className="nt-widgets-fixture" style={{ padding: 24, minHeight: "100%" }}>
      <NewTabWidgets
        client={host}
        tileLook={tileLook}
        editLook={editLook}
        galleryLook={galleryLook}
        initialEditing={editing}
        initialGallery={gallery}
      />
    </div>
  );
}

const noop = () => {};

/** The whole New Tab page, composer and all, with a full widget grid on the in-memory host. */
export function NewTabPageWithWidgetsFixture({
  template = "minimal",
  tiles = FIXTURE_TILES,
}: {
  template?: ScreenTemplate;
  tiles?: WidgetTilePlacement[];
}) {
  const [host] = useState(() => new MockWidgetsHost(tiles));
  return (
    <NewTabWidgetsHost value={host}>
      <NewTabScreen
        template={template}
        snapshot={noChat([])}
        lastAgent="claude"
        home="/Users/you"
        cwd="/Users/you/src/cmux"
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />
    </NewTabWidgetsHost>
  );
}
