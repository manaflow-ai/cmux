// l10n-allow-file: public sample file contents and gallery-only host controls.
import { useRef, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createStrings } from "../shared/i18n";
import { FilesSection } from "./FilesSection";
import type { MachineDetail } from "./detail";
import type { CloudStore } from "./store";
import table from "./generated/strings.json";

type Props = { result: "pending" | "success" | "failure" };

function FileSaveGallery({ result }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [detail, setDetail] = useState<MachineDetail>({
    machine: "sample-machine",
    loading: false,
    files: {
      path: "/home/cmux",
      entries: [],
      loading: false,
      preview: { path: "/home/cmux/notes.txt", text: "Original text", size: 13 },
    },
  });
  const finish = useRef<(() => void) | null>(null);
  const [pending, setPending] = useState(false);
  const [settled, setSettled] = useState(false);
  const [store] = useState(
    () =>
      ({
        files: {
          save: (path: string, text: string) =>
            new Promise<boolean>((resolve) => {
              setPending(true);
              finish.current = () => {
                if (result === "success")
                  setDetail((current) => ({
                    ...current,
                    files: { ...current.files!, preview: { path, text, size: text.length } },
                  }));
                setPending(false);
                setSettled(true);
                finish.current = null;
                resolve(result === "success");
              };
            }),
        },
      }) as unknown as CloudStore,
  );
  return (
    <section className="cloud-detail-section" data-save-settled={settled} data-gallery-capture="">
      <FilesSection store={store} detail={detail} unavailable={[]} transfers={[]} strings={strings} />
      {pending && result !== "pending" && (
        <button type="button" data-testid="finish-write" onClick={() => finish.current?.()}>
          Complete mock write
        </button>
      )}
    </section>
  );
}

const editDuringSave: Play = async (ctx) => {
  await ctx.click({ selector: ".cloud-file-edit" });
  await ctx.type(" — submitted", { selector: "textarea" });
  await ctx.click({ selector: ".cloud-file-save" });
  await ctx.type("\nNewer unsaved edit — 👩🏽‍💻 中文", { selector: "textarea" });
  if (ctx.document.querySelector('[data-testid="finish-write"]')) {
    await ctx.click({ testId: "finish-write" });
    await ctx.waitFor(() => ctx.document.querySelector('[data-save-settled="true"]'));
  }
};

export default componentEntry<Props>({
  id: "cloud.file-save",
  title: "Cloud file save",
  area: "Pages",
  height: 420,
  widths: { narrow: 360, normal: 700, wide: 1000 },
  covers: ["pages/cloud/FilesSection.tsx#Preview"],
  load: async () => FileSaveGallery,
  styles: () => Promise.all([import("../shared/pageBase.css"), import("./styles.css")]),
  variants: {
    pending: {
      note: "Typing remains available while Save waits for its write.",
      props: { result: "pending" },
      play: editDuringSave,
    },
    success: {
      note: "A successful write retains edits typed after submission.",
      props: { result: "success" },
      play: editDuringSave,
    },
    failure: {
      note: "A failed write retains the draft and enables retry.",
      props: { result: "failure" },
      play: editDuringSave,
    },
  },
});
