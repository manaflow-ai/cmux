import { ChatMenu, type ChatMenuItem } from "./ChatHeaderTools";

/**
 * The chat's identity in the header.  The title is a real control: it opens the same instant
 * glass menu as the header actions, instead of looking selectable while doing nothing.
 */
export function ThreadTitle({
  title,
  menu,
  onMenuOpen,
}: {
  title: string;
  menu: () => ChatMenuItem[];
  onMenuOpen?: () => Promise<unknown>;
}) {
  return (
    <ChatMenu
      items={menu}
      onOpen={onMenuOpen}
      triggerClassName="acpmux-thread-title-trigger"
      triggerLabel={title}
      triggerTitle={title}
      registerPickerLabel={null}
      trigger={
        <>
          <span className="acpmux-thread-title-text">{title}</span>
          <span className="acpmux-thread-title-chevron" aria-hidden="true" />
        </>
      }
    />
  );
}
