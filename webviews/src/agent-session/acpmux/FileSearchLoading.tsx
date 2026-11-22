import "./fileSearchLoading.css";

/// Decorative rows share each picker's loaded row classes, including font metrics and columns.
/// They never become options, so the field keeps focus and no placeholder can be picked.
export function FileSearchLoading({ mention = false }: { mention?: boolean }) {
  return [0, 1, 2].map((row) => (
    <div
      key={row}
      aria-hidden="true"
      data-file-search-placeholder=""
      className={mention ? "acpmux-slash-row acpmux-mention-row" : "acpmux-file-result"}
    >
      {mention && <span className="acpmux-mention-icon acpmux-file-loading-icon" />}
      <span className={`${mention ? "acpmux-slash-name" : "acpmux-file-name"} acpmux-file-loading-name`}>
        {"\u00a0"}
      </span>
      <span className={`${mention ? "acpmux-slash-description" : "acpmux-file-dir"} acpmux-file-loading-dir`}>
        {"\u00a0"}
      </span>
    </div>
  ));
}
