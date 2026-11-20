# Start a Cloud chat from a clean Mac

You need an Apple Silicon Mac, access to cmux Cloud, your own provider account, and a remote machine you control. Use a machine reserved for you when signing in with a personal subscription. The Mac runs the client; the remote machine runs the chat.

1. Open the [NEXT nightly release](https://github.com/manaflow-ai/cmux/releases/tag/nightly-next). Download the macOS arm64 DMG, open it, and drag the app to Applications. Open the app and start a terminal **inside it** so that `cmux` uses this build. Run `cmux login` and finish signing in to the intended team in your browser.
2. Run `cmux --version --json` and keep its `build_commit`, then run `cmux chat new --help`. Check that it lists `--machine` and `--prompt-file`. If either is missing, check the app for updates before continuing. Run `cmux machine list`. If your lane is already online, skip to step 4.
3. To join a machine you own, run `cmux machine add --name NAME --no-wait` in your private terminal, replacing `NAME` with the name you will use to start chats. Paste the generated join line **on the machine that will run the agent**. The line expires and is used once; keep it out of chat and tickets. After the installer reports success, run `cmux machine list` on the Mac and look for the same machine under **Machines** in the sidebar. If you need a managed VM instead, run `cmux vm new` once. If it says the VM is still starting, use `cmux vm ls` to find that VM when ready. Use `vm:ID` as the target.
4. On the remote machine, run `hostname` and note the output. Run `cmux setup harness codex` (or `claude`) if cmux is installed there. For Codex, check `codex login status` under the account that runs the lane. If it needs your ChatGPT sign-in and your workspace allows device codes, run `codex login --device-auth` in that private remote terminal and complete the code in your Mac browser. Check `codex login status` again. This [authorizes Codex on this machine](https://developers.openai.com/codex/auth/#login-on-headless-devices); signing in to cmux alone does not do that.
5. Back in the Mac app terminal, substitute the joined machine's name (or `vm:ID`) and start a chat:

   ```sh
   machine='replace-with-machine-name'
   brief=$(mktemp -t cmux-cloud-brief)
   printf '%s\n' 'Run hostname and reply with its output.' > "$brief"
   cmux chat new --machine "$machine" --harness codex --prompt-file "$brief"
   ```

   Use `--harness claude` for Claude, or add `--model MODEL` for a model available on that machine. On a joined lane, add `--fast` to use a faster tier offered by the selected model. If the harness cannot confirm that tier, cmux gives you the started chat’s name and does not send the prompt. Open the chat in cmux. Compare the reply with the hostname you noted on the remote machine; it may differ from the name shown in the sidebar. If the command reports an uncertain start, inspect the named chat before retrying.

**Copy this into a chat with an agent on the clean Mac. Replace `MACHINE_NAME` first:**

> Help me start one Codex chat on `MACHINE_NAME`. If cmux NEXT is missing, install the macOS arm64 app from `https://github.com/manaflow-ai/cmux/releases/tag/nightly-next` and open it. Inside its terminal, run `cmux chat new --help` and check for `--machine` and `--prompt-file`. Run `cmux login` and let me finish browser sign-in. Use `cmux machine list` to find `MACHINE_NAME` on my team. If it needs joining, tell me to run `cmux machine add --name MACHINE_NAME --no-wait` privately and paste the join line on that host; keep the line and all keys out of chat. Verify the joined machine appears in the CLI and in the sidebar. Use my own dedicated machine and my own Codex account. If Codex needs authorization, have me complete step 4 privately. Keep the device code out of chat and do not substitute an API key or another person’s login. Once Codex is ready, write “Run hostname and reply with its output.” to a temporary file. Run `cmux chat new --machine MACHINE_NAME --harness codex --prompt-file FILE` once, substituting the machine and file. Open the returned link and compare the assistant’s reply with `hostname` read on that remote machine. Report the CLI build, machine, link, and hostname it actually returned. On a refusal or uncertain start, tell me the step and message; don’t launch another chat or provision another VM.
