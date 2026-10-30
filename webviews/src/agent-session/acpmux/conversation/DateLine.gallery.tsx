// l10n-allow-file: gallery fixture labels and dates, not shipped UI.
import { useEffect } from "react";
import { componentEntry } from "../../../gallery/format";

type Props = { language: string };
const now = new Date(2026, 9, 29, 12).getTime();

export default componentEntry<Props>({
  id: "agent-pane.date-line",
  title: "Localized date separators",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/conversation/DateLine.tsx", "agent-session/acpmux/conversation/timestamps.ts"],
  load: async () => {
    const { DateLine } = await import("./DateLine");
    const { currentLanguage, setPaneLanguage } = await import("../i18n");
    return function DateLines({ language }: Props) {
      useEffect(() => {
        const previous = currentLanguage();
        setPaneLanguage(language);
        return () => setPaneLanguage(previous);
      }, [language]);
      return (
        <div className="cv-transcript">
          {[0, 1, 10].map((days) => (
            <DateLine
              key={days}
              row={{ id: `date-${days}`, version: 1, kind: "date", at: new Date(2026, 9, 29 - days, 9, 15).getTime() }}
              now={now}
            />
          ))}
        </div>
      );
    };
  },
  variants: {
    french: { props: { language: "fr" } },
    japanese: { props: { language: "ja" } },
    "live-switch": {
      props: { language: "fr" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector("time")?.textContent?.includes("aujourd’hui"));
        const { setPaneLanguage } = await import("../i18n");
        setPaneLanguage("ja");
        await ctx.waitFor(() => ctx.document.querySelector("time")?.textContent?.includes("今日"));
      },
    },
  },
});
