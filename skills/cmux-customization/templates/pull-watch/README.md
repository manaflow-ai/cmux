# My pull requests

See your real open pull requests from connected GitHub.  
Click one to open it in a cmux browser tab; cmux keeps the list fresh.

Connect GitHub in Settings → Integrations first. CI status is not part of this sample.

Copy `cmux-app.json` and `main.js` together into a new folder, then run `cmux ext dev` there. Accept the preview’s install card once; every subsequent save reloads the view.

Enable `actions:run` in Settings → Apps → My pull requests for clicks.

Edit the title, filter or row text in `main.js` to make it yours. `cmux ext shot --json` captures the installed view. To remove it, run `cmux ext remove local/showcase-pull-watch`.
