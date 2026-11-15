# Working agents

See your working and blocked terminal agents together.  
Click an agent to focus its terminal.

Copy `main.js` and save `cmux-app.v2.json` as `cmux-app.json` together in a new folder.
Run `cmux ext dev <folder>` and accept the install card. Keep the command running;
saving `main.js` reloads the view. The example uses the native scene kit, with no build step.

Enable the scopes this manifest requests in **Settings → Apps → Working agents**.
Reuse your original folder for further edits; a second folder with the same app ID is refused.
Remove the installed example with `cmux ext remove local/showcase-agent-status`. Your source files stay available.
