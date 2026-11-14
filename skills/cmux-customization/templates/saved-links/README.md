# Dashboard links

Keep your actual dashboard and project links in the sidebar.  
Paste an HTTPS link, then click it to open a browser tab beside your work.

Copy `cmux-app.json` and `main.js` together into a new folder, then run `cmux ext dev` there. Accept the preview’s install card once; every subsequent save reloads the view.

Enable `storage:local`, `actions:run` in Settings → Apps → Dashboard links for clicks and saved state.

Edit the title, filter or row text in `main.js` to make it yours. `cmux ext shot --json` captures the installed view. To remove it, run `cmux ext remove local/showcase-saved-links`.
