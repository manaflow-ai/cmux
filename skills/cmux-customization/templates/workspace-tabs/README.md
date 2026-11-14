# This workspace

Read the tabs in your current workspace.  
Click a row to focus its tab; workspace changes refresh the list.

Copy `cmux-app.json` and `main.js` together into a new folder, then run `cmux ext dev` there. Accept the preview’s install card once; every subsequent save reloads the view.

Enable `workspace:write` in Settings → Apps → This workspace for clicks.

Edit the title, filter or row text in `main.js` to make it yours. `cmux ext shot --json` captures the installed view. To remove it, run `cmux ext remove local/showcase-workspace-tabs`.
