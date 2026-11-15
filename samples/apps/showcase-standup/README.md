# Today

Keep a small Today list beside your workspace.  
Add a note and keep it across reloads using local app storage.

Copy `main.js` and save `cmux-app.v2.json` as `cmux-app.json` together in a new folder.
Run `cmux ext dev <folder>` and accept the install card. Keep the command running;
saving `main.js` reloads the view. The example uses the native scene kit, with no build step.

Enable the scopes this manifest requests in **Settings → Apps → Today**.
Reuse your original folder for further edits; a second folder with the same app ID is refused.
Remove the installed example with `cmux ext remove local/showcase-standup`. Your source files stay available.
