# Sessions for Claude Code

This plugin shows your Claude Code sessions in the **Sessions** iPhone app. You see which sessions need you, which are working and which finished, and you get a notification when one needs you.

Sessions is made by Omnia Studio. It is not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.

## What you need

- A Mac with macOS 13 or later, Apple silicon or Intel. Windows and Linux are not supported yet.
- Claude Code, in the terminal or in the Claude desktop app.
- The Sessions app on your iPhone.

## Install and connect

Type these two commands into Claude Code on your Mac. They work in the Code tab of the Claude app and in Claude Code in the Terminal.

1. Add the plugin, once per Mac:

   ```
   /plugin install sessions --marketplace omnia-sessions/sessions
   ```

   Claude Code shows where the plugin comes from and asks you to confirm. If it then says to run `/reload-plugins`, type that too.

2. In the Sessions app, tap **Connect**. It shows a six-digit code. Pair with it:

   ```
   /sessions:pair 123456
   ```

   Claude Code says "Connected to your iPhone", and the phone shows your Mac's name.

The code works once and expires after 10 minutes. The app's Connect screen, and the page at `https://omnia-relay.veldhub.workers.dev/connect`, give you both commands to copy, with your code already in the second.

If your Claude Code does not know `--marketplace`, type these two instead, one at a time:

```
/plugin marketplace add omnia-sessions/sessions
/plugin install sessions@omnia-sessions
```

Other commands:

- `/sessions:status` shows whether this Mac is connected.
- `/sessions:unpair` disconnects this Mac and deletes its key.

### From the command line instead

If the `claude` command works in your terminal, this installs the plugin without opening Claude Code:

```sh
claude plugin install sessions --marketplace omnia-sessions/sessions
```

That command needs Claude Code 2.1.292 or later. On older versions, run these two lines instead:

```sh
claude plugin marketplace add omnia-sessions/sessions
claude plugin install sessions@omnia-sessions
```

If Claude Code is already open, run `/reload-plugins` in it, then pair with `/sessions:pair` as above. The pair tool also runs straight from its install folder:

```sh
~/.claude/plugins/cache/omnia-sessions/sessions/0.1.0/tool/sessions-hook pair 123456
```

## Remove it

1. Run `/sessions:unpair`. This deletes the key on this computer and the copy at the relay.
2. Run `claude plugin uninstall sessions@omnia-sessions`, or remove it in `/plugin`.

## What is sent, and to whom

The plugin uses Claude Code hooks: session start, prompt sent, notification, tool finished, stop and session end. Each one updates a small file in `~/.omnia-sessions-plugin/` and returns at once. A separate process then sends the update.

- **To your phone, sealed:** the sessions list. For each session it sends a title (the folder name or the start of your first prompt), its state, Claude's last reply (up to 2,000 characters, plus a 300-character preview), and the times. It is encrypted on this computer with a key that only your phone and this computer have. The relay stores it but cannot read it.
- **To the relay, readable:** for the Lock Screen card, counts and, for each session that is working or needs you, its folder name (at most 40 characters) and its Claude Code session ID; and the alert texts "A session needs you" or "A session finished". iOS draws the card from the push itself, so this part cannot be encrypted. The card always uses the folder name, never the start of a prompt, so Claude's replies and your prompts are never in it.
- **The pair key** is in your login Keychain, under "Sessions pair key". On systems without a Keychain it is in a file that only you can read.

Nothing is sent until you pair, and nothing after you unpair. If you tap Disconnect on the phone, this computer notices on its next send and unpairs itself.

The relay is a Cloudflare Worker at `https://omnia-relay.veldhub.workers.dev`.

## If something does not show up

- Run `/sessions:status`.
- Read `~/.omnia-sessions-plugin/log.txt`. It lists failed sends.
- Hooks start working in sessions opened after the install, or after `/reload-plugins`.

## Settings for testing

| Variable | Effect |
| :- | :- |
| `SESSIONS_RELAY` | Relay address. Default `https://omnia-relay.veldhub.workers.dev`. Plain `http` is allowed only for `127.0.0.1` and `localhost`. |
| `SESSIONS_HOME` | State folder. Default `~/.omnia-sessions-plugin`. |
| `SESSIONS_SEND` | `detached` (default), `inline` (send inside the hook, for tests) or `off` (store only). |
| `SESSIONS_KEY_STORE` | `keychain` or `file`. |

## For developers

- `src/*.swift` is the source of `tool/sessions-hook`. It is a universal binary (arm64 and x86_64) and is committed, so users need no compiler.
- `./build.sh` rebuilds it. It needs Xcode or the Command Line Tools.
- `python3 -I tests/run_tests.py` runs the end-to-end checks against a local fake relay. It uses only the Python standard library. One part adds and removes a throwaway Keychain item.
- The pairing check is in `tests/pairtest/`: `mkdir -p build && xcrun swiftc -swift-version 5 tests/pairtest/main.swift src/Crypto.swift -o build/pairtest && build/pairtest`.
- `./set_repo.sh <owner/repo>` fills in the GitHub repository name wherever the placeholder is still written.

## License

MIT. See [LICENSE](LICENSE).
