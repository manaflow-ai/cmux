# Focus timer

Start or pause a short focus session beside your work.  
Native controls count down and cmux tells you when time is up.

Copy `main.js` and save `cmux-app.v2.json` as `cmux-app.json` together in a new folder.
Run `cmux ext dev <folder>` and accept the install card. Keep the command running;
saving `main.js` reloads the view. The example uses the native scene kit, with no build step.

Enable the scopes this manifest requests in **Settings → Apps → Focus timer**.
Reuse your original folder for further edits; a second folder with the same app ID is refused.
Remove the installed example with `cmux ext remove local/showcase-focus-timer`. Your source files stay available.
