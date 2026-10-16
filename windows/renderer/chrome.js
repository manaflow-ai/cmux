// Compose the existing actions into cmux's compact sidebar titlebar. Keeping the
// original elements preserves the common command, keyboard and IPC handlers.
import {translateLiteral} from './i18n.js';
document.documentElement.lang = new URLSearchParams(location.search).get('locale') || navigator.language || 'en';
for (const element of document.querySelectorAll('[title], [aria-label], [placeholder]')) {
  for (const attribute of ['title','aria-label','placeholder']) {
    if (element.hasAttribute(attribute)) element.setAttribute(attribute,translateLiteral(element.getAttribute(attribute)));
  }
}
const header = document.querySelector('.brand');
const toggle = document.getElementById('toggleSidebarButton');
const restore = toggle.cloneNode(true);
restore.id = 'restoreSidebarButton';
restore.addEventListener('click', () => toggle.click());
document.querySelector('.window-actions').append(restore);
header.replaceChildren(
  toggle,
  document.getElementById('notificationsRailButton'),
  document.getElementById('newWorkspaceButton'),
  document.getElementById('paletteButton')
);
header.classList.add('sidebar-chrome');
