# Branch status

See the real Git branch and its ahead/behind counts in Session Info, following that chat’s folder.

Use Refresh after external Git changes if your build does not send a Git change event.

Copy `cmux-app.json` and `main.js` together into a new folder, then run `cmux ext dev` there. Accept the preview’s install card once; every subsequent save reloads the view.

Edit the title, filter or row text in `main.js` to make it yours. `cmux ext shot --json` captures the installed view. To remove it, run `cmux ext remove local/showcase-branch-status`.
