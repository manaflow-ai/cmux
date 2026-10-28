// l10n-allow-file: gallery fixtures, not shipped UI.
// The choice-or-address editor (`home.server`: cmux Cloud, or a self-hosted server's origin) on its
// own row. The settings page entry can't show it until the generated schema carries a
// choice_or_url setting, so it gets this entry. Writes go to the row's value, as the store would.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SettingsContext, type SettingsContextValue } from "../context";
import table from "../generated/strings.json";
import type { SchemaRow } from "../schema";
import { installCatalog, setLocale } from "../strings";
import { ChoiceOrUrlEditor } from "./ChoiceOrUrlEditor";

type Props = { value: unknown; disabled?: boolean };

const row = {
  key: "home.server",
  path: ["home", "server"],
  section: "home",
  group: { text: "Messages Server", key: "settings.group.messagesServer" },
  title: { text: "Server", key: "settings.home.server" },
  help: null,
  summary: null,
  kind: "choice_or_url",
  choices: [{ value: "hosted", title: { text: "cmux Cloud", key: "settings.choice.homeServer.hosted" } }],
  url_key: "selfHosted",
  default: "hosted",
  default_label: null,
  keywords: [],
  agent_settable: false,
  kept_on_reset_all: false,
  consumers: ["cmux-next"],
  page_hidden: false,
  validation: "portable",
  accepts: [],
  refuses: [],
} as unknown as SchemaRow;

function ChoiceOrUrlGallery({ value: initial, disabled = false }: Props) {
  const [value, setValue] = useState(initial);
  // The editor only writes through `store.set`; this row's value stands in for the store.
  const [context] = useState(
    () =>
      ({
        store: { set: async (_key: string, next: unknown) => setValue(next) },
        router: null,
      }) as unknown as SettingsContextValue,
  );
  return (
    <SettingsContext.Provider value={context}>
      <div className="row" style={{ padding: 16 }}>
        <span id="home-server-label" className="row-title">
          Server
        </span>
        <ChoiceOrUrlEditor row={row} value={value} disabled={disabled} labelId="home-server-label" />
        <output data-testid="home-server-value" style={{ display: "block", marginTop: 12 }}>
          {JSON.stringify(value)}
        </output>
      </div>
    </SettingsContext.Provider>
  );
}

const refused: Play = async (ctx) => {
  await ctx.type("mini:7320", { role: "textbox" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ role: "alert" }));
};

export default componentEntry<Props>({
  id: "pages.settings.choice-or-url",
  title: "Server choice or address",
  area: "Settings",
  covers: ["pages/settings/editors/ChoiceOrUrlEditor.tsx#ChoiceOrUrlEditor"],
  load: async () => {
    installCatalog(table);
    setLocale(navigator.language);
    return ChoiceOrUrlGallery;
  },
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../page.css");
  },
  height: 200,
  variants: {
    hosted: { note: "cmux Cloud, the default: the menu alone.", props: { value: "hosted" } },
    "self-hosted": {
      note: "A self-hosted server: the menu shows Self-Hosted Server… and the address field its origin.",
      props: { value: { selfHosted: "http://mini.tail1234.ts.net:7320" } },
    },
    refused: {
      note: "An address that is not an http(s) origin is refused under the field and not written.",
      props: { value: { selfHosted: "" } },
      play: refused,
    },
    disabled: {
      note: "A managed or unavailable setting: the menu and field are disabled.",
      props: { value: { selfHosted: "http://mini.tail1234.ts.net:7320" }, disabled: true },
    },
  },
});
