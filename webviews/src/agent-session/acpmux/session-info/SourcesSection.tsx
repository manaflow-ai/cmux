import { useEffect, useState } from "react";
import { useT } from "../i18n";

import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

import type { SummarySource } from "../summary/sessionSummary";
import { extraFolderName } from "../extraFolders";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { openPullRequestDiff, pullRequestDiffUrl } from "./pullRequestDiff";
import { heightAbove, useFoldMotion } from "./foldMotion";
import { SOURCES_SHOWN, sourceLabels, scopedPath } from "./sourcesSectionModel";
import { SessionInfoFold } from "./SessionInfoSection";
import { WindowedRows } from "./WindowedRows";

type RowProps = {
  source: SummarySource;
  onOpenBeside?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  /// A pasted image's bytes by its id, when its prompt did not carry them.
  readImage?: (id: string) => Promise<string | undefined>;
  onOpenFile?: (path: string) => unknown;
  cwd?: string;
};

export function SourcesSection({
  sources,
  folders = [],
  expanded,
  onExpandedChange,
  ...navigation
}: Omit<RowProps, "source"> & {
  sources: readonly SummarySource[];
  /// The folders the chat sees beside its own (acpmux `additionalDirectories`), listed first. Leo,
  /// 2026-11-03: "being able to have chatgpt (and in this case, any harnesses) see whatever
  /// folders/files would be cool".
  folders?: readonly string[];
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}) {
  const t = useT();
  // A fold that would hold back one row shows it instead (OutputsSection `OUTPUTS_SHOWN`).
  const folds = sources.length - SOURCES_SHOWN >= 2;
  // Show more grows the list in place and Show less closes it over the rows that go (foldMotion.ts).
  const fold = useFoldMotion<HTMLUListElement>(expanded, (list) =>
    heightAbove(list, list.children[folders.length + SOURCES_SHOWN]),
  );
  const shown = folds && !fold.drawn ? sources.slice(0, SOURCES_SHOWN) : sources;
  const labels = sourceLabels(t, sources);
  return (
    <>
      <ul ref={fold.ref} className="acpmux-session-info-list" data-section="sources">
        {folders.map((folder) => (
          // tooltip-allow: the row shows the folder's name; the tooltip is its full path
          <li key={`folder:${folder}`} className="acpmux-session-info-source" data-kind="folder" title={folder}>
            <span className="acpmux-session-info-source__link">
              <Icon name="folder" size={rowIconSize(12)} row />
              <span className="acpmux-session-info-source__label">{extraFolderName(folder)}</span>
            </span>
          </li>
        ))}
        <WindowedRows
          items={shown}
          render={(source, index) => (
            <SourceRow
              key={source.image ? `image:${source.image.id}` : `${source.kind}:${source.url ?? source.label}`}
              source={source}
              label={labels[index]!}
              {...navigation}
            />
          )}
        />
      </ul>
      {folds && (
        <SessionInfoFold
          className="acpmux-session-info-sources-fold"
          open={expanded}
          onToggle={() => fold.toggle(!expanded, onExpandedChange)}
        >
          {expanded
            ? t("sessionInfo.outputs.showLess")
            : t("sessionInfo.list.showMore", { n: sources.length - SOURCES_SHOWN })}
        </SessionInfoFold>
      )}
    </>
  );
}

function SourceRow({
  source,
  label,
  onOpenBeside,
  onOpenImage,
  readImage,
  onOpenFile,
  cwd,
}: RowProps & { label: string }) {
  const t = useT();
  const [failure, setFailure] = useState<string>();
  useEffect(() => {
    if (!failure) return;
    const timer = setTimeout(() => setFailure(undefined), 4_000);
    return () => clearTimeout(timer);
  }, [failure]);
  const icon = {
    file: "file.text",
    mcp: "extension",
    pullRequest: "git.pullrequest",
    issue: "git.pullrequest",
    url: "link.web",
    image: "site.permission.images",
  } as const;
  const content = (
    <>
      <Icon name={icon[source.kind ?? "url"]} size={rowIconSize(12)} row />
      <span className="acpmux-session-info-source__label">{label || t("image.viewer")}</span>
    </>
  );
  const path = source.kind === "file" ? scopedPath(source.label, cwd) : undefined;
  const image = source.image;
  let target = content;
  if (image && onOpenImage && (image.src || readImage))
    target = (
      <button
        type="button"
        className="acpmux-session-info-source__link"
        onClick={() => {
          setFailure(undefined);
          Promise.resolve(image.src ?? readImage?.(image.id))
            .then((src) => {
              if (!src) throw new Error(t("image.unavailable"));
              onOpenImage(src, label || t("image.viewer"));
            })
            .catch((error: unknown) => setFailure(error instanceof Error ? error.message : t("image.actionFailed")));
        }}
      >
        {content}
      </button>
    );
  else if (path && onOpenFile)
    target = (
      <button
        type="button"
        className="acpmux-session-info-source__link"
        onClick={() => {
          setFailure(undefined);
          Promise.resolve()
            .then(() => onOpenFile(path))
            .catch((error: unknown) => setFailure(error instanceof Error ? error.message : t("changes.openFailed")));
        }}
      >
        {content}
      </button>
    );
  else if (source.kind !== "file" && source.url)
    target = (
      <a
        className="acpmux-session-info-source__link"
        href={source.url}
        onClick={(event) => {
          if (!onOpenBeside || event.metaKey || event.ctrlKey || event.shiftKey) return;
          event.preventDefault();
          onOpenBeside(source.url!);
        }}
      >
        {content}
      </a>
    );
  // A pull request the chat named opens its diff from its ⋯ menu, as a Changes row does.
  const diffUrl = onOpenBeside && source.kind === "pullRequest" ? pullRequestDiffUrl(source.url) : undefined;
  return (
    <li className="acpmux-session-info-source">
      {failure ? <span role="alert">{failure}</span> : target}
      {diffUrl && !failure && (
        <Menu>
          <MenuButton
            className="acpmux-session-info-icon-button acpmux-session-info-source__more"
            label={t("sessionInfo.changes.more", { reference: source.label })}
            aria-haspopup="menu"
          >
            <Icon name="action.more" size={14} />
          </MenuButton>
          <MenuPopup
            className="acpmux-session-info-menu"
            label={t("sessionInfo.changes.actions", { reference: source.label })}
            align="end"
          >
            <MenuItem className="acpmux-session-info-menu__item" onSelect={() => openPullRequestDiff(diffUrl)}>
              {t("sessionInfo.changes.viewDiff")}
            </MenuItem>
          </MenuPopup>
        </Menu>
      )}
    </li>
  );
}
