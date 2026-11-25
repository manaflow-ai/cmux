// The surge card on Machines (docs: cmuxterm-hq docs/design/value-business-cases.md, case 3): after a
// surge, how many of its machines are ready, how long the last one took, and whether its queue drained.
// Hidden when no surge is listed.
import type { Strings } from "../shared/i18n";
import type { CloudSurge } from "./ops";
import { L } from "./strings";
import { surgeParts } from "./surge";

export function SurgeCard({ surge, strings }: { surge: CloudSurge | undefined; strings: Strings }) {
  if (!surge) return null;
  const { t, language } = strings;
  const parts = surgeParts(surge, t, language);
  return (
    <section
      className={`cloud-surge ${surge.drained ? "is-drained" : "is-starting"}`}
      aria-label={t(L.surgeTitle)}
      data-testid="cloud-surge"
    >
      <span className="cloud-surge-title">{t(L.surgeTitle)}</span>
      {parts.map((part, index) => (
        <span key={index} className={index === 0 ? "cloud-surge-ready" : "cloud-muted cloud-surge-part"}>
          {part}
        </span>
      ))}
    </section>
  );
}
