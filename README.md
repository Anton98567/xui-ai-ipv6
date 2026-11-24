# xui-ai-ipv6

Патчи для **3x-ui / Xray**: направляют трафик Gemini, OpenAI/ChatGPT и Claude/Anthropic
через IPv6-адрес сервера, **не меняя остальные маршруты**.

Done by editing the **x-ui template config** in SQLite (`settings.key = 'xrayTemplateConfig'`),
not the generated `bin/config.json`. Therefore the changes survive any panel-driven config
regeneration (adding inbounds, saving settings, etc.).

## Why

Typical 3x-ui installs are IPv4-only:

- global DNS `queryStrategy: UseIPv4`
- `direct` outbound with `sockopt.domainStrategy: ForceIPv4`

As a result AI services are reached over IPv4. These patches add a dedicated IPv6 path
only for AI domains, leaving `warp` / `direct` / `api` / `blocked` rules untouched.

## What each patch adds

For one provider (example: `openai`):

1. `freedom` outbound `openai-v6` with `sendThrough: <server IPv6>` and
   `streamSettings.sockopt.domainStrategy: UseIPv6`.
2. Routing rule `ruleTag: xui-ai-openai-v6` inserted **at the beginning** of
   `routing.rules`, sending provider domains + `geosite:openai` to `openai-v6`.
3. Dedicated DNS server with `queryStrategy: UseIPv6` and `skipFallback: true` for the
   same domain list.
4. Global DNS `queryStrategy` is switched from `UseIPv4` to `UseIP` (Xray gives global
   strategy priority, so per-server `UseIPv6` cannot work with global `UseIPv4`).
   **All pre-existing DNS servers keep their own `UseIPv4`**, so non-AI traffic is
   unchanged. The original global value is saved in
   `/var/lib/xui-ai-ipv6/<provider>.json` and restored by `remove`.

### Domain sources

Full lists taken from [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community):

| Patch | Explicit domains | Geosite |
|---|---|---|
| Gemini / Antigravity | 45 (incl. `aistudio.google.com`, `jules.google.com`, `antigravity.google.com`, `cloudcode-pa.googleapis.com`, …) | `geosite:google-deepmind` |
| OpenAI / ChatGPT | 16 (incl. `chatgpt.com`, `api.openai.com`, `sora.com`, livekit endpoints, …) | `geosite:openai` |
| Claude / Anthropic | 22 (incl. `claude.ai`, `api.anthropic.com`, `console.anthropic.com`, `claude.com`, …) | `geosite:anthropic` |

Note: `geosite:gemini` and `geosite:claude` do not exist (404 in v2fly) — the correct
categories are `google-deepmind` and `anthropic`.

## Requirements

- root access on the 3x-ui server
- working global IPv6. The script **verifies it itself** before touching anything:
  every global address is probed with `--interface`, `api6.ipify.org` must echo back
  exactly that address, and a second endpoint must answer. If none works, `apply`
  aborts with no changes.
- `python3`, `curl`, `systemctl`, Xray binary (default path auto-detected by convention)
- Xray ≥ 1.8 (tested on 26.7.28)

## Install (one command per provider)

```bash
# Gemini / Antigravity
curl -fsSL https://raw.githubusercontent.com/Anton98567/xui-ai-ipv6/main/xui-gemini-v6-patch.sh \
  -o /usr/local/sbin/xui-gemini-v6-patch.sh && chmod 700 /usr/local/sbin/xui-gemini-v6-patch.sh \
  && /usr/local/sbin/xui-gemini-v6-patch.sh apply

# OpenAI / ChatGPT
curl -fsSL https://raw.githubusercontent.com/Anton98567/xui-ai-ipv6/main/xui-openai-v6-patch.sh \
  -o /usr/local/sbin/xui-openai-v6-patch.sh && chmod 700 /usr/local/sbin/xui-openai-v6-patch.sh \
  && /usr/local/sbin/xui-openai-v6-patch.sh apply

# Claude / Anthropic
curl -fsSL https://raw.githubusercontent.com/Anton98567/xui-ai-ipv6/main/xui-claude-v6-patch.sh \
  -o /usr/local/sbin/xui-claude-v6-patch.sh && chmod 700 /usr/local/sbin/xui-claude-v6-patch.sh \
  && /usr/local/sbin/xui-claude-v6-patch.sh apply
```

All three patches can be applied together. They are independent: each owns its own
outbound, rule, DNS entry and state file.

## Install all three at once (one line)

```bash
for p in gemini openai claude; do curl -fsSL "https://raw.githubusercontent.com/Anton98567/xui-ai-ipv6/main/xui-${p}-v6-patch.sh" -o "/usr/local/sbin/xui-${p}-v6-patch.sh" && chmod 700 "/usr/local/sbin/xui-${p}-v6-patch.sh" && "/usr/local/sbin/xui-${p}-v6-patch.sh" apply || exit 1; done
```

Each patch still performs its own IPv6 preflight, so the loop stops at the first
provider whose IPv6/network validation fails.

## Modes

```bash
xui-<provider>-v6-patch.sh apply    # verify IPv6, back up, add routing, restart x-ui, E2E test
xui-<provider>-v6-patch.sh remove   # remove only own objects and restore original DNS strategy
xui-<provider>-v6-patch.sh status   # read-only: show outbound/rule/DNS state
xui-<provider>-v6-patch.sh test     # read-only: IPv6 preflight, AAAA, HTTP, config validation + REAL E2E
```

`apply` / `remove` briefly restart `x-ui` (active connections are interrupted).

## Safety

- **IPv6 is selected only after a live egress test**, before any DB/config change. A forced
  `XUI_AI_IPV6` is checked the same way. AI domains must have AAAA records; direct HTTP
  reachability of AI hosts is reported but is not required, because production traffic
  goes through the Xray route.
- DB + template backup before every change: `/root/bak-3xui/`
- Generated config validated with `xray -c <tmp> test` before committing to the result
- **Real end-to-end test after apply**: the generated config is cloned into a temporary
  Xray instance with a local SOCKS inbound. Provider traffic must exit over the chosen IPv6
  (Cloudflare `ip=` check for OpenAI/Claude, HTTP check for Gemini), while the control
  domain `api.ipify.org` must keep its original IPv4 route.
- Automatic rollback on failure (invalid config / missing generated objects)
- `remove` is surgical: it never touches rules or outbounds created by other patches
  or by the panel
- `status` and `test` never modify anything (E2E uses a temporary Xray process and cleans up)

## Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `XUI_AI_IPV6` | autodetect | force a specific source IPv6 (still connectivity-checked) |
| `XUI_DB` | `/etc/x-ui/x-ui.db` | x-ui SQLite DB |
| `XUI_SERVICE` | `x-ui` | systemd service |
| `XRAY_BIN` | `/usr/local/x-ui/bin/xray-linux-amd64` | Xray binary |
| `XRAY_CFG` | `/usr/local/x-ui/bin/config.json` | generated config |
| `XUI_AI_BACKUP_DIR` | `/root/bak-3xui` | backup directory |
| `XUI_AI_DNS` | `8.8.8.8` | plain-IP DNS used for AAAA (DoH URLs cannot be combined with `queryStrategy`) |
| `XUI_AI_STATE_DIR` | `/var/lib/xui-ai-ipv6` | saved original global DNS strategy |
| `XUI_AI_TIMEOUT` | `15` | diagnostic curl timeout |
| `XUI_AI_PROBE_TIMEOUT` | `8` | IPv6 preflight curl timeout |
| `XUI_AI_E2E_TIMEOUT` | `20` | end-to-end curl timeout |
| `XUI_AI_TEST_PROXY` | empty | optional extra proxy check (e.g. `socks5h://127.0.0.1:1080`) |
| `XUI_AI_SKIP_TEST` | `0` | set to `1` to skip all post-apply diagnostics |
| `XUI_AI_SKIP_E2E` | `0` | set to `1` to skip only the real Xray E2E test |

## Verification example

```bash
xui-gemini-v6-patch.sh status
xui-gemini-v6-patch.sh test
```

`test` already includes the real E2E check — expected output (excerpt):

```
[xui-ai-openai-v6] IPv6 preflight: 2001:db8::1 — egress confirmed (ipify + second endpoint)
=== E2E through Xray (expected IPv6 2001:db8::1) ===
[xui-ai-openai-v6] E2E OK: openai via Xray exits over IPv6 2001:db8::1
[xui-ai-openai-v6] E2E OK: control api.ipify.org keeps the old IPv4 route (192.0.2.10)
```

## Notes / caveats

- DoH addresses are **not** supported as the dedicated `UseIPv6` DNS server; Xray
  rejects `queryStrategy` on a domain-style DNS address. Use a plain IP.
- If the server has no usable IPv6, `apply` stops with an error — nothing is changed.
- The global DNS strategy stays `UseIP` while any of the patches is active; this is
  required for per-server `UseIPv6`. It is restored on the last `remove`.
- Domain lists are static in the script. Re-run the generator / update the scripts
  when v2fly lists change.

## License

MIT
