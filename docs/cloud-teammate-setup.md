# Start a Cloud chat from a clean Mac

You need an Apple Silicon Mac, membership in the team that owns the machine, and a teammate who can sign in to the chosen harness on that machine. The Mac runs the client; the remote machine runs the chat.

1. Open the [NEXT nightly release](https://github.com/manaflow-ai/cmux/releases/tag/nightly-next). Download the macOS arm64 DMG, open it, and drag the app to Applications. Open the app and start a terminal **inside it** so that `cmux` uses this build. Run `cmux login` and finish signing in to the intended team in your browser.
2. Run `cmux chat new --help`. Check that it lists `--machine` and `--prompt-file`. If either is missing, check the app for updates before continuing. Run `cmux machine list`. If the team's lane is already online, skip to step 4.
3. To join a machine you own, run `cmux auth token | cmux machine add --cloud-token-stdin --no-wait` in your private terminal. Paste the generated join line **on the machine that will run the agent**. The line expires and is used once; keep it out of chat and tickets. After the installer reports success, run `cmux machine list` on the Mac and look for the same machine in the sidebar. If you need a managed VM instead, `cmux vm new` creates one; record its ID and use `vm:ID` as the target.
4. In the app terminal, substitute the joined machine's name (or `vm:ID`) and start a chat:

   ```sh
   machine='replace-with-machine-name'
   brief=$(mktemp)
   printf '%s\n' 'Reply with the hostname on which you are running.' > "$brief"
   cmux chat new --machine "$machine" --harness codex --prompt-file "$brief"
   ```

   Use `--harness claude` for Claude, or add `--model MODEL` for a model available on that machine. Open the chat in cmux. A reply from the selected host verifies that the machine received the prompt; the creation receipt alone does not. If the command reports an uncertain start, inspect the named chat before retrying.

**Copy this into a chat with an agent helping you set up:**

> Set up cmux NEXT on this Mac using the steps in `docs/cloud-teammate-setup.md`. Let me finish browser sign-in. Use the machine I name; if it already appears online, reuse it. If it needs joining, show me how to run the join command in my own terminal without copying the credential or join line into this chat. Start one Codex chat there with a prompt file asking for its hostname. Report the machine, the session reference returned by cmux, and the hostname the remote agent actually reports. If something fails, give me the exact step and refusal without creating another machine or chat.
