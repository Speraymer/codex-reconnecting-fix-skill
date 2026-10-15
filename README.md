# Codex Reconnecting Fix

A Codex skill for Windows that automatically repairs persistent `Reconnecting… 1/5` delays, stream timeouts, and WebSocket failures when Codex Desktop is used behind a local HTTP or mixed proxy.

The skill performs the complete repair after invocation: it detects the real proxy port, tests ChatGPT and WebSocket endpoints, repairs `~/.codex/.env`, switches away from an unhealthy Clash-compatible node when available, preserves a backup, and restarts Codex automatically.

It does **not** change browser language, cookies, login state, Windows global environment variables, or subscription settings.

## Install

```powershell
git clone https://github.com/Speraymer/codex-reconnecting-fix-skill.git "$env:USERPROFILE\.codex\skills\codex-reconnecting-fix"
```

Restart Codex once after installation so the skill is discovered.

## Use

Ask Codex:

```text
Use $codex-reconnecting-fix to fix the persistent Reconnecting problem.
```

No port lookup, file editing, node selection, or manual restart is required during the repair.

## Requirements

- Windows 10 or 11
- Codex Desktop
- An already running local HTTP or mixed proxy
- `curl.exe` (included with current Windows)
- Optional: a locally accessible Clash-compatible controller for automatic node switching

## Safety

- Only the current user's `~/.codex/.env` is edited.
- Existing unrelated entries are preserved.
- Existing `ALL_PROXY` and `NO_PROXY` values are preserved; required local exclusions are appended to `NO_PROXY`.
- Existing `.env` files receive timestamped backups.
- A failed node search restores the previous selector.
- Controller tokens, proxy credentials, subscription URLs, and public IPs are never printed.

See OpenAI's [network recommendations for ChatGPT and Codex](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps) for the WebSocket requirements behind this repair.

## License

MIT
