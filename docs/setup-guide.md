# Set up cmux

<!-- Generated from setup::TASKS by scripts/cmux-next/generate-setup-guide.py. -->

## Start an agent on this Mac

1. Open the model picker and choose + to see Harnesses. Install a provider, then use Sign In and finish its browser or terminal instructions.
2. Run cmux setup harness to check the result. Follow the recovery it reports for that profile; unknown sign-in evidence does not confirm a working account.

## Recover a sign-in

1. Open Settings > Accounts. Use Sign In for a missing provider or Re-authenticate for an expired one, then check again.
2. For the wrong cmux account, use Switch Account and check the masked address. For a missing or unreadable saved key, use Add Key; never paste the secret into a chat.
3. If the command or browser reports offline, reconnect before retrying. If Cloud is unavailable, retry when the service returns; local work can continue.

## Use another machine

1. For a Cloud machine, sign in to cmux, then preview with cmux setup cloud-machine --dry-run. To proceed, run cmux setup cloud-machine without --dry-run. Creating a machine costs money; confirm the request only when you want it.
2. For an existing SSH machine, run cmux setup machine HOST. If the connection fails, use the SSH command it reports. Do not enter a password into an agent chat.
3. Run cmux setup status for the current checks and recovery steps. A detected credential is not proof that it is valid or belongs to the intended account.
