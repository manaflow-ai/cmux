// The preview card's "Open in ▾" menu (decision D6): cmux's own browser pane first, then the
// installed browsers the host lists (`browser.list`: opaque ids, names and icons; never a path),
// then Copy link. A pick sends only `{url, browserId}` (`browser.openIn`); the host checks the id
// against its own list, the URL (http or https, no user info), and a user gesture.
import { useState } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator } from "../../../ui/Menu";
import { useT } from "../i18n";
import { copyText } from "../conversation/clipboard";
import { ChevronDown, Copy, Globe } from "../conversation/icons";
import { callChipHost } from "../chips/host";

export type Browser = { id: string; name: string; icon?: string };

/// `onOpenInPane` opens the URL in cmux's browser pane (the card's existing path).
export function OpenInMenu({ url, onOpenInPane }: { url: string; onOpenInPane: (url: string) => void }) {
  const t = useT();
  const [browsers, setBrowsers] = useState<Browser[] | undefined>();
  const onOpenChange = (open: boolean) => {
    // The list is asked for on every open: the host's ids from an older list stop working.
    if (open)
      void callChipHost("browser.list", {}).then((reply) => {
        const list = (reply as { browsers?: Browser[] } | undefined)?.browsers;
        setBrowsers(Array.isArray(list) ? list.filter((entry) => typeof entry.id === "string") : []);
      });
  };
  return (
    <Menu onOpenChange={onOpenChange}>
      <MenuButton className="acpmux-review-changes acpmux-open-in" label={t("preview.openIn")}>
        {t("preview.openIn")}
        <ChevronDown size={12} />
      </MenuButton>
      <MenuPopup align="end">
        <MenuItem onSelect={() => onOpenInPane(url)}>
          <Globe size={16} className="acpmux-open-in__icon" />
          {t("preview.cmuxBrowser")}
        </MenuItem>
        {browsers?.map((browser) => (
          <MenuItem
            key={browser.id}
            onSelect={() => void callChipHost("browser.openIn", { url, browserId: browser.id })}
          >
            {browser.icon?.startsWith("data:image/") ? (
              <img className="acpmux-open-in__icon" src={browser.icon} alt="" width={16} height={16} />
            ) : (
              <Globe size={16} className="acpmux-open-in__icon" />
            )}
            {browser.name}
          </MenuItem>
        ))}
        <MenuSeparator />
        <MenuItem onSelect={() => void copyText(url)}>
          <Copy size={16} className="acpmux-open-in__icon" />
          {t("preview.copyLink")}
        </MenuItem>
      </MenuPopup>
    </Menu>
  );
}
