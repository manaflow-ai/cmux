import type { AllChatsDesign } from "./AllChatsList";
import { useNt } from "./strings";
import "./allChatsLoading.css";

/** Static rows share the loaded list's geometry. No fake chats or focus targets. */
export function AllChatsLoading({
  rowHeight,
  design,
  view,
}: {
  rowHeight: number;
  design: AllChatsDesign;
  view: "chats" | "projects";
}) {
  const nt = useNt();
  return (
    <div className="nt-all-host nt-all-loading" aria-busy="true" aria-label={nt("allChats")}>
      <div className="nt-all-list" aria-hidden="true">
        {Array.from({ length: 6 }, (_, index) => (
          <div key={index} className="nt-all-item nt-all-skeleton-row" style={{ height: rowHeight }}>
            {view === "projects" && index === 0 ? (
              <div className="nt-all-group">
                <span className="nt-all-placeholder nt-all-placeholder-project" />
              </div>
            ) : (
              <div className="nt-all-row">
                <span className="nt-all-glyph nt-all-placeholder" />
                <span className="nt-all-title nt-all-placeholder" />
                {design !== "quiet" && <span className="nt-all-meta nt-all-placeholder" />}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
