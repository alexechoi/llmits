# Claude Usage Bar

A minimal macOS menu bar app that shows how close you are to your Claude plan's usage limits.

<img src="docs/screenshot.png" alt="Menu bar showing a red gauge at 94%, with a dropdown listing the 5-hour session, weekly all-models and weekly per-model limits" width="300">

- **Menu bar:** a small gauge and the percentage of whichever limit you're closest to hitting. It turns orange or red as that limit becomes a concern (the server's own severity rating, or 75% / 90% when it doesn't give one).
- **Dropdown:** every limit on your plan (5-hour session, weekly across all models, weekly per model) with a bar and when it resets.
- **Stale data is obvious:** if the numbers can't be refreshed, the menu bar item greys out and the dropdown says why.
- **Launch at Login** toggle in the dropdown.

## How it works

- It reads the OAuth token that [Claude Code](https://code.claude.com) stores in your login keychain (the `Claude Code-credentials` item), using `/usr/bin/security`.
- It calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` command uses. This endpoint is **undocumented and may change without notice**. Decoding is deliberately lenient so unknown fields or new kinds of limit don't break it.
- It polls every 2 minutes, after your Mac wakes, and whenever you open the dropdown with data more than a minute old.
- **It never refreshes or writes the token.** Claude Code's access tokens are short-lived and Claude Code refreshes them whenever you use it. If the token has expired, the app keeps showing the last numbers, greyed out, until Claude Code next refreshes it. This means it can never interfere with, or log you out of, Claude Code.

## Requirements

- macOS 14 or later
- Claude Code signed in with a Claude subscription (run `claude`, then `/login`)
- Xcode 16 or later (Swift 6) to build

## Install

```bash
git clone https://github.com/karannavani/claude-usage-bar.git
```

```bash
cd claude-usage-bar && ./scripts/build-app.sh --install
```

This builds a release binary, wraps it in `Claude Usage Bar.app` with an ad-hoc signature, copies it to `~/Applications`, and launches it. Without `--install` it just builds `build/Claude Usage Bar.app`.

**Can't see it?** If you use a menu bar manager such as Bartender or Ice, new items usually land in its hidden section, so drag it out. Also check that the app is allowed in **System Settings → Menu Bar**.

To uninstall, untick **Launch at Login**, choose **Quit**, and delete `~/Applications/Claude Usage Bar.app`.

## Development

```bash
swift test
```

```bash
swift run
```

`swift run` starts the app unbundled, where **Launch at Login** is unavailable (only a bundled `.app` can be a login item).

| Path | What's there |
| --- | --- |
| `Sources/UsageCore` | Credentials, response decoding, limit summary and formatting. No AppKit, fully unit-tested. |
| `Sources/ClaudeUsageBar` | The status item, menu, gauge icon and SwiftUI dropdown rows. |
| `Support/Info.plist` | Bundle metadata (`LSUIElement`, so there's no Dock icon). |
| `scripts/build-app.sh` | Builds and assembles the `.app`. |

## Privacy

Your token is only ever sent to `api.anthropic.com`. The app stores nothing, and has no analytics or other network traffic.

## Disclaimer

Unofficial and not affiliated with or endorsed by Anthropic. It relies on an undocumented endpoint, so it may stop working at any time.

## Licence

[MIT](LICENSE)
