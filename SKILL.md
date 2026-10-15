---
name: codex-reconnecting-fix
description: Automatically diagnose and repair persistent Reconnecting, stream timeout, and WebSocket failures in Codex Desktop on Windows when a local HTTP or mixed proxy is in use.
---

# Codex Reconnecting Fix

Use the bundled script first. It detects the active local HTTP/mixed proxy, checks the real ChatGPT and WebSocket routes, repairs Codex's proxy environment, switches away from a failing Clash-compatible node when possible, and schedules a Codex restart.

## Run

1. Tell the user once that the proxy route may change briefly and Codex will restart automatically.
2. Run from this skill directory:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair-codex-reconnecting.ps1
   ```

3. Do not ask the user to find a port, edit `.env`, choose a node, or restart the app. After the script schedules the restart, immediately return its concise result so the message is delivered before the app closes.

The script must finish with a tested route or fail with the exact blocker. Do not guess a proxy port, disable a required system proxy, clear browser data, or change Windows-wide environment variables.

## Invariants

- Modify only the current user's `~/.codex/.env`; preserve unrelated entries and create a timestamped backup before changing an existing file.
- Update only `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`. Preserve `ALL_PROXY` and every unrelated entry; retain existing `NO_PROXY` targets and append the required local addresses.
- Require both `https://chatgpt.com/cdn-cgi/trace` and `https://ws.chatgpt.com/` to complete through the selected proxy. A `404` from the bare WebSocket host is reachable and expected; status `000` or a TLS timeout is failure.
- If a Clash-compatible controller is discoverable, test ordinary supported-region nodes, exclude traffic-multiplier and account-information entries, keep the fastest route that passes real endpoint checks, and restore the previous selector if every candidate fails.
- Never print controller tokens, subscription URLs, proxy credentials, or public IP addresses.
- Language settings, cookies, login state, and browser localization are outside this skill.

For non-mutating diagnosis or development, use `-CheckOnly`. For script testing without closing Codex, use `-NoRestart` and an isolated `-CodexHome`.

Official network background: https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps
