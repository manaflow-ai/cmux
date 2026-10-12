title: Open Chrome pages from the New Tab field and the address bar
action: newTab.page | Try it

Type `chrome://extensions`, `chrome://version`, `about:flags` or a `chrome-extension://` address in the New Tab field or the address bar and it opens in a Chromium tab instead of a web search. Any spelling works: `chrome://extensions` and `CHROME://Extensions/` open the same page. The address bar completes the common page names after `chrome://`, and a `chrome://` address you type is never sent to your search engine for suggestions.

Where cmux has its own page, the Chrome address opens it, so your data stays in one place: `chrome://history` opens History, `chrome://bookmarks` opens Bookmarks and `chrome://settings` opens Settings > Browser. Agents and scripts still cannot open or script Chromium's own pages, such as the password manager or the extensions page.
