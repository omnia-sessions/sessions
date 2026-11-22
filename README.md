# Sessions for Claude Code

This plugin shows your Claude Code sessions in the **Sessions** iPhone app. You see which sessions need you, which are working and which finished, and you get a notification when one needs you.

Sessions is made by Omnia Studio. It is not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.

## Where it works

- Claude Code on a Mac with macOS 13 or later, Apple silicon or Intel: the terminal, the Code tab of the Claude desktop app, and the IDE extensions.
- It needs the Sessions app on your iPhone.
- In claude.ai chat and in Cowork it does nothing. Its commands say that it works only in Claude Code on a Mac.
- Windows and Linux are not supported. On those systems it stays silent.

## Install from the Claude directory

1. On claude.ai or in the Claude app, open **Customize > Plugins**, find **Sessions**, and add it.
2. Start Claude Code, signed in with the same claude.ai account. It downloads the plugin in the background. If it says "Plugins changed", run `/reload-plugins`.
3. Connect your iPhone: in the Sessions app tap **Connect**, then type `/sessions:pair 123456` with your code.

This needs Claude Code 2.1.273 or later.

## Install from a terminal or the Code tab

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
- `/sessions:unpair` disconnects this Mac and deletes its key and local data.

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

If Claude Code is already open, run `/reload-plugins` in it, then pair with `/sessions:pair` as above.

## Remove it

1. Run `/sessions:unpair`. This deletes the pair key, the local folder `~/.omnia-sessions-plugin/`, and the copy at the relay. (If you put other files in that folder yourself, those stay, and the command says so.)
2. Remove the plugin: on claude.ai under **Customize > Plugins** if you added it there, or with `claude plugin uninstall sessions@omnia-sessions`.

## What it reads, what it sends, and to whom

Nothing happens until you pair. Before that, the hooks exit at once.

After you pair, the plugin reads only what Claude Code passes to its hooks. From that it keeps the session ID, the folder name, the first line of your first prompt, Claude's last reply, the text of a permission or question notice, and the kind of error that stopped a session. It ignores tool inputs and outputs. It does not read your files, your transcripts or your settings, and it changes no permissions.

| Hook | Why |
| :- | :- |
| SessionStart | adds the session to the list |
| UserPromptSubmit | marks it as working; the first prompt's first line can become its title |
| Notification | marks it as waiting for you (a permission prompt or a question); an idle notice a minute after Claude finished can send "A session finished" |
| PostToolUse | notices that Claude carried on after a permission prompt; runs in the background and never slows Claude down |
| Stop, StopFailure | marks it as done or stopped by an error, with Claude's last reply |
| SessionEnd | removes it |

Each hook updates a small file in `~/.omnia-sessions-plugin/` and returns. When something changed, it starts a short background process that sends the update and exits. Each request it sends is limited to 3 seconds (pairing allows 10). It leaves no process running and installs no launch agent.

- **To your phone, end-to-end encrypted:** for each session, a title (the folder name, the first line of your first prompt, or a title you gave the session), its state, what it waits for, Claude's last reply (up to 2,000 characters, plus a 300-character preview), and the times; and your Mac's name. It is encrypted on this Mac with a key only your phone and this Mac have (X25519, AES-256-GCM). The relay stores it but cannot read it.
- **To the relay and Apple, readable:** for the Lock Screen card, counts and, for each session that is working or needs you, its folder name (at most 40 characters) and its Claude Code session ID; and the alert texts "A session needs you" or "A session finished". iOS draws the card from the push itself, so this part cannot be encrypted. The card always uses the folder name, never the start of a prompt, so your prompts and Claude's replies are never in it.
- **At pairing, readable:** your Mac's name (as set in System Settings > General > Sharing, up to 60 characters; it often includes your first name), so the phone can show which Mac it paired with. The relay keeps it with the pairing code, stops handing it out after 10 minutes, and deletes it at its next daily clean-up.
- **The pair key** is in your login Keychain, under "Sessions pair key".

The relay also sees the IP address each request comes from, as any web server does.

The only host it contacts is the relay at `https://omnia-relay.veldhub.workers.dev`, run by Omnia Studio on Cloudflare.

Why it sends Claude's last reply: so you can read on your phone what the session said when it finished or stopped.

If you tap Disconnect on the phone, this Mac notices on its next send and unpairs itself: it deletes the pair key and the session list and keeps its log, which says why. `/sessions:unpair` then deletes the rest of the folder.

Privacy policy: https://omnia-relay.veldhub.workers.dev/privacy
Terms: https://omnia-relay.veldhub.workers.dev/terms
Support and security reports: https://omnia-relay.veldhub.workers.dev/support

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
| `SESSIONS_KEY_STORE` | `keychain` (default) or `file` (a file only you can read, in the state folder). |

## How tool/sessions-hook is built

`tool/sessions-hook` is the only compiled file. It is built from `src/*.swift` and nothing else. It uses only Apple frameworks (Foundation, CryptoKit, SystemConfiguration) and no third-party code. It is a universal binary (arm64 and x86_64), ad-hoc signed, and committed so users need no compiler. The hooks and commands start it through `tool/run.sh`, a short shell script that exits instead on any system other than macOS.

To check that it matches the source:

1. Install Xcode 26.3 (Swift 6.2.4).
2. In a fresh clone, from any folder, run `./build.sh`. It uses the Xcode that `DEVELOPER_DIR` names, for example `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh`. Without it, it uses the selected Xcode, or an Xcode 26.3 it finds in `/Applications`, `~/Applications` or `~/Downloads`.
3. It prints the Swift version and the SHA-256 of `tool/sessions-hook`, and writes that hash to `tool/sessions-hook.sha256`.
4. `git status` shows no change to either file.

Another Xcode or Swift version gives a different file that works the same; `build.sh` says so when it is not Swift 6.2.4. To check the committed file against its hash without building, run `shasum -a 256 -c tool/sessions-hook.sha256`.

`./set_repo.sh <owner/repo>` writes the GitHub repository name into every file, if the plugin moves.

## For reviewers: try it without an iPhone

- `python3 -I tests/run_tests.py` runs the end-to-end checks against a local fake relay. It uses only the Python standard library. One part adds and removes a throwaway Keychain item.
- The pairing check is in `tests/pairtest/`: `mkdir -p build && xcrun swiftc -swift-version 5 tests/pairtest/main.swift src/Crypto.swift -o build/pairtest && build/pairtest`.
- Without pairing, every hook exits at once and nothing is stored or sent. `/sessions:status` says the computer is not connected.
- `SESSIONS_SEND=off` stores updates without sending them.

## License

MIT. See [LICENSE](LICENSE).
