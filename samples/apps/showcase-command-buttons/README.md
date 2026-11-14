# Quick actions

Put useful cmux actions in your sidebar.  
Each button runs a real app action from your click.

Copy `main.js` and save `cmux-app.v2.json` as `cmux-app.json` together in a new folder.
Run `cmux ext dev <folder>` and accept the install card. Keep the command running;
saving `main.js` reloads the view. The example uses the native scene kit, with no build step.

Enable the scopes this manifest requests in **Settings → Apps → Quick actions**.
Reuse your original folder for further edits; a second folder with the same app ID is refused.
Remove the installed example with `cmux ext remove local/showcase-command-buttons`. Your source files stay available.
