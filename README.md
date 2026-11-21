# Claude Usage Bar

See how much of your Claude and ChatGPT plans you've used, right in your Mac's menu bar.

<img src="docs/screenshot.png" alt="The menu bar shows a red exclamation ring at 100%. Its menu has a Claude Max 20x section (5-hour session not started; weekly all models 62%, resets Wednesday, ahead of pace; weekly Fable 100% in red) and a ChatGPT Pro 100 section (weekly 35%, resets Tuesday, on track), then Refresh, Launch at Login and Quit." width="320">

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/karannavani/claude-usage-bar/main/install.sh | bash
```

That's it. The installer checks your Mac has what it needs, builds the app, puts it in `~/Applications` and starts it. It takes about a minute. You're welcome to [read the script](install.sh) first.

To have it start whenever you log in, click the icon and choose **Launch at Login**.

### What you need

- **macOS 14 Sonoma or later.** On macOS 26 Tahoe or later, the menu bar ring also fills up as you use your limit.
- **At least one of these logins**, which the app reads, so there's nothing else to set up:
  - **For Claude:** [Claude Code](https://code.claude.com) signed in with a Claude subscription such as Pro or Max. Install it, run `claude`, then type `/login`.
  - **For ChatGPT:** the [Codex CLI](https://github.com/openai/codex) signed in with your ChatGPT account. Install it, then run `codex login`.
- **Apple's Command Line Tools**, to build the app. If they're missing, the installer opens Apple's installer for you; run the command again once it's done.

## Using it

- **The menu bar** shows the limit you're closest to hitting, across both services. It turns **orange** as that limit gets high and **red with a ! symbol** when it's nearly used up. These follow the service's own rating where it gives one, or 75% and 90% otherwise.
- **Click it** to see every limit, grouped by service: for Claude, the 5-hour session, your weekly limit across all models and any per-model weekly limits; for ChatGPT, your plan's usage windows. Each shows how much you've used and when it resets.
- **Only what you use appears.** A service shows up once you're signed in to its tool, and disappears if you sign out.
- **The mark on each bar** shows an even pace: how much of that window has passed. If your bar reaches past it, you're using the limit faster than the window runs out, and the caption says **ahead of pace**; otherwise it says **on track**. Each service's windows start at different times, so their marks sit in different places.
- **It updates itself** every 2 minutes, when your Mac wakes, and when you open the menu. Choose **Refresh** (⌘R) to update straight away; it shows when the numbers were last updated.
- **Out-of-date numbers** grey out the menu bar icon and that service's bars, and a note at the top of its section says why and what happens next.
- **To remove it**, choose **Quit Claude Usage Bar**, or hold ⌘ and drag the icon out of the menu bar.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| No icon in the menu bar | If you use a menu bar manager such as Bartender or Ice, look in its hidden section. On a crowded menu bar (especially beside a notch), macOS hides some icons; on macOS 26 or later, also check **System Settings → Menu Bar**. |
| A service is missing | Sign in to its tool: `claude` then `/login` for Claude, or `codex login` for ChatGPT. A Codex login that uses an OpenAI API key has no ChatGPT plan limits to show. |
| "Token expired" | Normal if you haven't used Claude Code or Codex for a while. Use it once and the app catches up within a minute. |
| "Rate limited" | Nothing to do; it waits and tries again on its own. |
| The installer says Swift 6 is needed | Update Xcode or the Command Line Tools in **System Settings → General → Software Update**. |

## Update

Run the install command again. It replaces the app with the latest version and restarts it.

## Uninstall

First untick **Launch at Login** if you turned it on. Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/karannavani/claude-usage-bar/main/install.sh | bash -s -- --uninstall
```

## How it works

- **Claude:** it reads the login token Claude Code keeps in your macOS keychain (the `Claude Code-credentials` item) using the built-in `security` tool, then asks `https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage` command.
- **ChatGPT:** it reads the ChatGPT login the Codex CLI keeps in `~/.codex/auth.json` (or `$CODEX_HOME`), then asks `https://chatgpt.com/backend-api/wham/usage`, the endpoint the Codex CLI uses. The limits there are your ChatGPT plan's, not just Codex's.
- Neither endpoint is publicly documented, and either may change without notice, so the app is deliberately tolerant of fields it doesn't recognise.
- **It only ever reads the tokens.** Each tool renews its own tokens when you use it. The app never renews or changes them, so it can't interfere with Claude Code or Codex or sign you out.

### Privacy

Your Claude token is only ever sent to `api.anthropic.com`, and your ChatGPT token only to `chatgpt.com`. The app stores nothing, and has no analytics or other network traffic.

## Design

The app follows Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) for menu bar extras, as of macOS 27:

- The icon is an SF Symbol drawn in the menu bar's own colours, so it adapts to light and dark menu bars and Liquid Glass. Its ring uses SF Symbols 7's Variable Draw to fill with your usage.
- Colour is used sparingly, for status only, and only on the icon. The percentage keeps the menu bar's standard text colour so it stays readable on any wallpaper. Critical also changes the icon's shape, so the state never depends on colour alone.
- Clicking opens a standard menu rather than a popover, with each plan as a native section header. Bars stay neutral while all's well, so orange and red only ever mean trouble, and percentages keep full-contrast text.
- Warning and critical limits also get their own glyphs, and every limit has a VoiceOver label and value, such as "Weekly, Fable: Limit reached, 100 percent used, resets Wednesday 05:00".
- Messages say what happens next ("You're offline. Retrying automatically."), and an out-of-date service never hides a live warning from another.
- You decide whether it's in your menu bar: ⌘-drag it out to remove it, and Launch at Login is off until you turn it on.

### Lightweight

It uses about 20 MB of memory and no CPU between its checks: no timers tick while it's idle, and its menu is only built when you open it. Its rows are plain AppKit views; SwiftUI versions looked the same but cost 7–8 MB more.

## Development

```bash
git clone https://github.com/karannavani/claude-usage-bar.git
```

```bash
cd claude-usage-bar && ./install.sh
```

Running `./install.sh` from a clone builds and installs that checkout. While working on it:

```bash
swift test
```

```bash
swift run
```

`swift run` starts the app without bundling it, so **Launch at Login** is unavailable there.

| Path | What's there |
| --- | --- |
| `Sources/UsageCore` | One usage source per service (`Claude/`, `ChatGPT/`): credentials, response decoding and rows; plus the shared limit model and formatting. No AppKit, and fully unit-tested. |
| `Sources/ClaudeUsageBar` | The menu bar item, the menu, and its custom AppKit rows and notices. |
| `Support/Info.plist` | Bundle metadata (`LSUIElement`, so there's no Dock icon). |
| `scripts/build-app.sh` | Builds `build/Claude Usage Bar.app`; `--install` also copies it to `~/Applications` and launches it. |
| `install.sh` | The one-line installer and uninstaller. |

## Disclaimer

Unofficial and not affiliated with or endorsed by Anthropic or OpenAI. Claude is a trademark of Anthropic; ChatGPT and Codex are trademarks of OpenAI. The app relies on undocumented endpoints, so it may stop working at any time.

## Licence

[MIT](LICENSE)
