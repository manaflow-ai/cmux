// Move to Cloud's done toast, when the folder was copied rather than cloned or something stayed on
// this Mac (hq RFD 0066 piece 1, "Say what happened"). Every word is Rust's: cmux-cloud-start-core
// `moves/landed.rs` reads the seed push's answer (`mode`, `skipped_files`, `skipped_counts`) into
// `Landed`, and this only lays it out. No answer, or a clone that left nothing: the toast is the
// one it always was.
import type { ReactNode } from "react";
import { Disclosure } from "../../ui/Disclosure";
import type { ToastSpec } from "../../ui/NoticeStack";
import "./moveLanded.css";

/** One group of paths left on this Mac (Rust `landed::Skipped`). */
export interface LandedGroup {
  group: "secret" | "rebuilt" | "big" | "repository" | "other";
  label: string;
  paths: string[];
  more: number;
  text: string;
}

/** How the folder reached the machine and what stayed behind (Rust `landed::Landed`). */
export interface MoveLanded {
  how: "cloned" | "copied" | "projected";
  headline?: string | null;
  reason?: string | null;
  skipped: LandedGroup[];
  summary?: string | null;
}

/** How the skipped list is laid out. */
export type LandedLook = "inline" | "count" | "grouped";

/** Paths shown per group in the grouped look before a `+N`. */
const SHOWN = 4;

function Lines({ landed }: { landed: MoveLanded }) {
  return (
    <ul className="acpmux-move-landed-lines">
      {landed.skipped.map((group) => (
        <li key={group.group} data-group={group.group}>
          {group.text}
        </li>
      ))}
    </ul>
  );
}

function Groups({ landed }: { landed: MoveLanded }) {
  return (
    <div className="acpmux-move-landed-groups">
      {landed.skipped.map((group) => {
        const shown = group.paths.slice(0, SHOWN);
        const rest = group.paths.length - shown.length + group.more;
        return (
          <section key={group.group} className="acpmux-move-landed-group" data-group={group.group}>
            <span className="acpmux-move-landed-label">{group.label}</span>
            <span className="acpmux-move-landed-paths">
              {shown.map((path) => (
                <code key={path} className="acpmux-move-landed-path">
                  {path}
                </code>
              ))}
              {rest > 0 && <span className="acpmux-move-landed-more">+{rest}</span>}
            </span>
          </section>
        );
      })}
    </div>
  );
}

/** The skipped list in `look`; nothing when nothing stayed. */
export function MoveLandedDetail({ landed, look }: { landed: MoveLanded; look: LandedLook }): ReactNode {
  if (landed.skipped.length === 0) return null;
  if (look === "grouped") return <Groups landed={landed} />;
  if (look === "count")
    return (
      <Disclosure className="acpmux-move-landed-disclosure" label={landed.summary ?? ""}>
        <Lines landed={landed} />
      </Disclosure>
    );
  return <Lines landed={landed} />;
}

/** The done toast `done` with what `landed` says: the copy's headline as its title, why after its
 *  sentence, and the skipped list under it. `done` as it is when there is nothing to say. */
export function movedToast(done: ToastSpec, landed: MoveLanded | undefined, look: LandedLook): ToastSpec {
  if (!landed || (landed.how !== "copied" && landed.skipped.length === 0)) return done;
  const message = [done.message, landed.reason].filter(Boolean).join(" ");
  return {
    ...done,
    title: landed.headline ?? done.title,
    message,
    children: landed.skipped.length > 0 ? <MoveLandedDetail landed={landed} look={look} /> : undefined,
  };
}
