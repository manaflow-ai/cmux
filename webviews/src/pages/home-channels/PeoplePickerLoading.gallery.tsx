// l10n-allow-file: public sample people in gallery fixtures, not shipped copy.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { PeoplePicker } from "./PeoplePicker";
import type { HomeParticipant } from "./types";

type Props = { people: HomeParticipant[]; loading: boolean };
function PickerGallery({ people, loading }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [picked, setPicked] = useState<string[]>([]);
  return <PeoplePicker people={people} picked={picked} onPicked={setPicked} strings={strings} loading={loading} />;
}
const people: HomeParticipant[] = ["Taylor", "Morgan", "Casey", "Jordan"].map((name, index) => ({
  id: `sample-${index}`,
  name,
  kind: "human",
  chief: false,
}));
export default componentEntry<Props>({
  id: "pages.home-channels.people-picker-loading",
  title: "People picker loading",
  area: "Home",
  height: 280,
  widths: { narrow: 320, normal: 480, wide: 680 },
  covers: ["pages/home-channels/PeoplePicker.tsx#PeoplePicker"],
  load: async () => PickerGallery,
  styles: () => Promise.all([import("./styles.css"), import("./ledger.css")]),
  variants: {
    pending: {
      note: "The directory has not answered yet; the loaded row layout remains visible.",
      props: { people: [], loading: true },
    },
    loaded: { note: "The directory has answered with four people.", props: { people, loading: false } },
    refreshing: {
      note: "Populated results remain selectable during a background read.",
      props: { people, loading: true },
    },
    empty: {
      note: "A completed empty directory uses the existing no-match message.",
      props: { people: [], loading: false },
    },
  },
});
