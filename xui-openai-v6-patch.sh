#!/usr/bin/env bash
# 3x-ui (openai over IPv6) patch — apply/remove/status/test
# Works by editing the x-ui template config stored in SQLite (settings.key =
# 'xrayTemplateConfig'), so changes survive panel-driven config regeneration.
set -euo pipefail

PROVIDER="openai"
TAG="openai-v6"
RULE_TAG="xui-ai-openai-v6"
DOMAINS="chatgpt.com chat.com openai.com openai.org chatgpt.site sora.com api.openai.com platform.openai.com oaistatic.com oaistatsig.com oaiusercontent.com chatgpt.livekit.cloud host.livekit.cloud turn.livekit.cloud openai.com.cdn.cloudflare.net"
GEOSITE="geosite:openai"
SAMPLES="chatgpt.com api.openai.com platform.openai.com sora.com"
TEST_URLS="https://chatgpt.com/cdn-cgi/trace|2xx-4xx https://api.openai.com/v1/models|2xx-4xx https://www.openai.com/|any"

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
SERVICE="${XUI_SERVICE:-x-ui}"
XRAY_BIN="${XRAY_BIN:-/usr/local/x-ui/bin/xray-linux-amd64}"
XRAY_CFG="${XRAY_CFG:-/usr/local/x-ui/bin/config.json}"
BACKUP_DIR="${XUI_AI_BACKUP_DIR:-/root/bak-3xui}"
DNS_SERVER="${XUI_AI_DNS:-8.8.8.8}"
IPV6="${XUI_AI_IPV6:-}"
TIMEOUT="${XUI_AI_TIMEOUT:-15}"
PROBE_TIMEOUT="${XUI_AI_PROBE_TIMEOUT:-8}"
E2E_TIMEOUT="${XUI_AI_E2E_TIMEOUT:-20}"
STATE_DIR="${XUI_AI_STATE_DIR:-/var/lib/xui-ai-ipv6}"
STATE_FILE="$STATE_DIR/openai.json"

log()   { echo "[xui-ai-openai-v6] $*"; }
logerr(){ echo "[xui-ai-openai-v6] $*" >&2; }  # safe inside $(...)
die()   { echo "[xui-ai-openai-v6] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: xui-ai-openai-v6-patch.sh <apply|remove|status|test>

  apply   add an IPv6 'freedom' outbound + routing/DNS rules for OpenAI / ChatGPT
  remove  remove only the objects created by this script
  status  show whether the patch is active (read-only)
  test    preflight IPv6 + config state + REAL end-to-end test through Xray (read-only)

apply order:
  1) enumerate every global IPv6 on the host and pick one with PROVEN outbound
     egress (api6.ipify.org must echo the exact address back, plus a second
     endpoint must answer) — nothing is changed until this succeeds
  2) preflight: check AAAA + HTTP reachability of AI endpoints via that address
  3) back up the DB/template, patch the template, restart x-ui, validate Xray
  4) end-to-end: temporary local SOCKS inbound on the generated config; AI
     domains must exit over the IPv6, a control domain must keep its old route

Environment overrides:
  XUI_AI_IPV6=<addr>         force a specific source IPv6 (still connectivity-checked)
  XUI_DB=<path>              x-ui SQLite DB       (default /etc/x-ui/x-ui.db)
  XUI_SERVICE=<name>         systemd service     (default x-ui)
  XRAY_BIN=<path>            Xray binary          (default /usr/local/x-ui/bin/xray-linux-amd64)
  XRAY_CFG=<path>            generated config     (default /usr/local/x-ui/bin/config.json)
  XUI_AI_BACKUP_DIR=<path>   backup directory    (default /root/bak-3xui)
  XUI_AI_DNS=<addr>          plain-IP DNS for AAAA (default 8.8.8.8; DoH URLs cannot
                             be combined with queryStrategy)
  XUI_AI_PROBE_TIMEOUT=<n>   preflight curl timeout (default 8)
  XUI_AI_E2E_TIMEOUT=<n>     end-to-end curl timeout (default 20)
  XUI_AI_SKIP_TEST=1         skip diagnostics after apply
  XUI_AI_SKIP_E2E=1          skip the real Xray end-to-end test only
  XUI_AI_TEST_PROXY=<url>    optional extra proxy check (e.g. socks5h://127.0.0.1:1080)

NOTE: apply/remove restart x-ui, which briefly interrupts active connections.
EOF
}

check_root() { [[ "$(id -u)" == "0" ]] || die "run as root"; }

ipv6_candidates() {
  # All global (non-link-local, non-loopback) IPv6 addresses assigned to the host.
  ip -6 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -v '^fe80:' | grep -v '^::1$' | sort -u
}

probe_ipv6() {
  # $1 = candidate address. Success = ipify sees EXACTLY this address through it
  # and a second independent endpoint answers. Prints the address on success.
  local ip="$1" seen code
  [[ "$ip" == *:* ]] || return 1
  seen="$(curl -6 -s --interface "$ip" --max-time "$PROBE_TIMEOUT" https://api6.ipify.org 2>/dev/null || true)"
  [[ "$seen" == "$ip" ]] || return 1
  code="$(curl -6 -L -s -o /dev/null -w '%{http_code}' --interface "$ip" --max-time "$PROBE_TIMEOUT" https://www.google.com/generate_204 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]] || return 1
  echo "$ip"
}

ipv6_http_ok() {
  local ip="$1" code
  code="$(curl -6 -L -s -o /dev/null -w '%{http_code}' --interface "$ip" --max-time "$PROBE_TIMEOUT" "$2" 2>/dev/null || true)"
  [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]
}

find_ipv6() {
  # Returns a VERIFIED source IPv6. With "soft" (test mode only) it falls back
  # to the first assigned address for diagnostics instead of aborting.
  local soft="${1:-}" ip seen code tested="" good
  if [[ -n "$IPV6" ]]; then
    seen="$(curl -6 -s --interface "$IPV6" --max-time "$PROBE_TIMEOUT" https://api6.ipify.org 2>/dev/null || true)"
    if [[ "$seen" != "$IPV6" ]]; then
      logerr "WARN: forced IPv6 $IPV6 -> observed ${seen:-none} (continuing because it was forced)"
    fi
    if ! ipv6_http_ok "$IPV6" https://www.google.com/generate_204; then
      if [[ "$soft" == "soft" ]]; then
        logerr "WARN: forced IPv6 $IPV6 has no working egress (diagnostics only)"
      else
        die "forced IPv6 $IPV6 has no working IPv6 egress"
      fi
    fi
    echo "$IPV6"; return 0
  fi
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    tested="$tested $ip"
    if good="$(probe_ipv6 "$ip")" && [[ -n "$good" ]]; then
      logerr "IPv6 preflight: $ip — egress confirmed (ipify + second endpoint)"
      echo "$good"; return 0
    fi
    logerr "IPv6 preflight: $ip — FAILED (no working egress)"
  done < <(ipv6_candidates)
  if [[ "$soft" == "soft" ]]; then
    local fallback; fallback="$(ipv6_candidates | head -1 || true)"
    [[ -n "$fallback" ]] && { logerr "WARN: no verified IPv6; diagnostics will use $fallback"; echo "$fallback"; return 0; }
    echo ""; return 0
  fi
  [[ -n "$tested" ]] || die "no global IPv6 address found on any interface; set XUI_AI_IPV6=<addr>"
  die "none of the global IPv6 addresses ($tested) has working IPv6 egress; fix IPv6 or set XUI_AI_IPV6=<addr>"
}

preflight_ai_ipv6() {
  # Fail BEFORE any config change. Generic IPv6 egress was already PROVEN by
  # find_ipv6(); here we additionally verify that AI domains resolve to AAAA.
  # Direct HTTP to AI hosts is informational only: in production this traffic
  # goes through the Xray outbound, so the host itself may not reach it.
  local ip="$1" h aaaa=0 reachable=0
  ipv6_http_ok "$ip" https://www.google.com/generate_204 \
    || die "IPv6 $ip has no working egress — refusing to apply"
  for h in $SAMPLES; do
    if python3 -c 'import socket,sys;socket.getaddrinfo(sys.argv[1],443,socket.AF_INET6)' "$h" 2>/dev/null; then
      aaaa=$((aaaa + 1))
      if ipv6_http_ok "$ip" "https://$h/"; then
        log "preflight AI: $h directly reachable over $ip"
        reachable=$((reachable + 1))
      else
        log "WARN: preflight AI: $h not directly reachable over $ip (E2E through Xray will decide)"
      fi
    else
      log "WARN: preflight AI: no AAAA for $h"
    fi
  done
  [[ $aaaa -ge 1 ]] || die "none of the AI domains has an AAAA record — refusing to apply"
  if [[ $reachable -ge 1 ]]; then
    log "preflight AI: $reachable/$aaaa endpoints directly reachable over $ip"
  else
    log "WARN: preflight AI: no AI endpoint directly reachable over $ip (routing may still work via tunnel)"
  fi
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$DB" "$BACKUP_DIR/x-ui.db.bak-$ts"
  python3 - "$DB" "$BACKUP_DIR/template-$PROVIDER-before-$ts.json" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=30)
row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if not row:
    raise SystemExit("xrayTemplateConfig not found in DB")
open(sys.argv[2], "w", encoding="utf-8").write(row[0])
PY
  log "backup: $BACKUP_DIR/x-ui.db.bak-$ts + template-$PROVIDER-before-$ts.json"
}

patch_template() {
  # mode=add|remove, via env
  python3 - <<'PY'
import json, os, sqlite3, sys

mode    = os.environ["XUI_AI_MODE"]
db      = os.environ["XUI_AI_DB"]
tag     = os.environ["XUI_AI_TAG"]
rule    = os.environ["XUI_AI_RULETAG"]
domains = os.environ["XUI_AI_DOMAINS"].split()
geosite = os.environ["XUI_AI_GEOSITE"]
dns_srv = os.environ["XUI_AI_DNSSERVER"]
ipv6    = os.environ["XUI_AI_IPV6"]
state   = os.environ["XUI_AI_STATE"]

sel = domains + [geosite]

con = sqlite3.connect(db, timeout=30)
con.execute("PRAGMA busy_timeout=30000")
row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if not row:
    raise SystemExit("xrayTemplateConfig not found in DB")
cfg = json.loads(row[0])

outbounds = cfg.setdefault("outbounds", [])
rules     = cfg.setdefault("routing", {}).setdefault("rules", [])
servers   = cfg.setdefault("dns", {}).setdefault("servers", [])
dns_cfg   = cfg["dns"]

def ours_dns(s):
    if s.get("queryStrategy") != "UseIPv6":
        return False
    d = s.get("domains") or []
    return bool(set(d) & set(domains)) or geosite in d

if mode == "add":
    # Global queryStrategy takes precedence over per-server values in Xray.
    # Switch it to UseIP so a per-server UseIPv6 (AAAA) entry is possible;
    # every pre-existing server keeps its own UseIPv4, so other traffic is unchanged.
    import os as _os
    if not _os.path.exists(state):
        _os.makedirs(_os.path.dirname(state), exist_ok=True)
        with open(state, "w", encoding="utf-8") as f:
            json.dump({"global_query_strategy": dns_cfg.get("queryStrategy", "UseIP")}, f)
    dns_cfg["queryStrategy"] = "UseIP"
    outbounds[:] = [o for o in outbounds if o.get("tag") != tag]
    outbounds.append({
        "tag": tag,
        "protocol": "freedom",
        "sendThrough": ipv6,
        "settings": {},
        "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6"}},
    })
    rules[:] = [r for r in rules if r.get("ruleTag") != rule]
    rules.insert(0, {
        "type": "field",
        "ruleTag": rule,
        "domain": sel,
        "outboundTag": tag,
    })
    servers[:] = [s for s in servers if not ours_dns(s)]
    servers.insert(0, {
        "address": dns_srv,
        "domains": sel,
        "queryStrategy": "UseIPv6",
        "skipFallback": True,
    })
elif mode == "remove":
    outbounds[:] = [o for o in outbounds if o.get("tag") != tag]
    rules[:] = [r for r in rules if r.get("ruleTag") != rule]
    servers[:] = [s for s in servers if not ours_dns(s)]
    # Restore the original global strategy only when no other IPv6 AI patch remains.
    if not any(s.get("queryStrategy") == "UseIPv6" for s in servers) and os.path.exists(state):
        try:
            dns_cfg["queryStrategy"] = json.load(open(state, encoding="utf-8")).get(
                "global_query_strategy", "UseIP")
        except Exception:
            pass
        os.remove(state)
else:
    raise SystemExit("bad mode")

con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
            (json.dumps(cfg, ensure_ascii=False),))
con.commit()
con.close()
PY
}

validate_generated() {
  local tmp="/tmp/xui-ai-validate.$$.json" logf="/tmp/xui-ai-validate.$$.log"
  python3 - "$XRAY_CFG" "$tmp" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
c["inbounds"] = []
c.pop("api", None)
c.pop("metrics", None)
json.dump(c, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
  timeout 8 "$XRAY_BIN" -c "$tmp" test >"$logf" 2>&1 || true
  if grep -qE 'Failed|\[Error\]' "$logf"; then
    cat "$logf" >&2
    rm -f "$tmp" "$logf"
    log "ERROR: generated Xray config is invalid"
    return 1
  fi
  grep -q 'started' "$logf" || { cat "$logf" >&2; rm -f "$tmp" "$logf"; log "ERROR: Xray did not start on test config"; return 1; }
  rm -f "$tmp" "$logf"
  log "generated config validated by Xray"
}

restart_panel() {
  systemctl restart "$SERVICE"
  local i
  for i in $(seq 1 20); do
    systemctl is-active --quiet "$SERVICE" && break
    sleep 1
  done
  systemctl is-active --quiet "$SERVICE" || die "$SERVICE failed to start"
  sleep 2
}

check_generated() {
  python3 - "$XRAY_CFG" "$TAG" "$RULE_TAG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
tag, rule = sys.argv[2], sys.argv[3]
assert any(o.get("tag") == tag for o in c.get("outbounds", [])), "outbound missing"
assert any(r.get("ruleTag") == rule for r in c.get("routing", {}).get("rules", [])), "rule missing"
PY
}

cmd_status() {
  python3 - "$DB" "$TAG" "$RULE_TAG" "$DOMAINS" "$GEOSITE" <<'PY'
import json, sqlite3, sys
db, tag, rule = sys.argv[1:4]
domains = sys.argv[4].split(); geosite = sys.argv[5]
con = sqlite3.connect(db, timeout=30)
row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
if not row:
    raise SystemExit("xrayTemplateConfig not found")
c = json.loads(row[0])
o = [x for x in c.get("outbounds", []) if x.get("tag") == tag]
r = [x for x in c.get("routing", {}).get("rules", []) if x.get("ruleTag") == rule]
def ours(s):
    d = s.get("domains") or []
    return s.get("queryStrategy") == "UseIPv6" and (bool(set(d) & set(domains)) or geosite in d)
s = [x for x in c.get("dns", {}).get("servers", []) if ours(x)]
print("outbound :", json.dumps(o[0], ensure_ascii=False) if o else "MISSING")
print("rule     :", (r[0]["outboundTag"] + " <- " + str(len(r[0].get("domain", []))) + " domains") if r else "MISSING")
print("dns srv  :", (s[0].get("address", "") + " (UseIPv6)") if s else "MISSING")
print("dns glob :", c.get("dns", {}).get("queryStrategy", "UseIP"))
print("state    :", "ACTIVE" if (o and r and s) else "NOT APPLIED")
PY
}

http_code() {
  local url="$1" ip="$2" code
  code="$(curl -6 -L -s -o /dev/null -w '%{http_code}' --interface "$ip" --max-time "$TIMEOUT" "$url" 2>/dev/null || true)"
  echo "${code:-000}"
}

E2E_PID=""
E2E_TMP=""

e2e_cleanup() {
  [[ -n "$E2E_PID" ]] && kill "$E2E_PID" 2>/dev/null || true
  if [[ -n "$E2E_TMP" ]]; then
    rm -f "$E2E_TMP" "${E2E_TMP%.json}.log"
  fi
  E2E_PID=""; E2E_TMP=""
}
trap e2e_cleanup EXIT

e2e_test() {
  # Real end-to-end check using the GENERATED config: a temporary local SOCKS
  # inbound feeds the real routing rules. AI traffic must exit over IPv6;
  # a control domain must keep its pre-existing (IPv4) route.
  local expected="$1"
  if [[ ! -x "$XRAY_BIN" || ! -f "$XRAY_CFG" ]]; then
    log "E2E SKIP: Xray binary or generated config unavailable"
    return 0
  fi
  if ! python3 - "$XRAY_CFG" "$RULE_TAG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if any(r.get("ruleTag") == sys.argv[2]
                          for r in c.get("routing", {}).get("rules", [])) else 1)
PY
  then
    log "E2E SKIP: patch rule is not active in the generated config"
    return 0
  fi

  local port tmp logf px code trace_ip ctrl rc=0 i
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  tmp="/tmp/xui-ai-e2e.$$.json"
  logf="${tmp%.json}.log"
  E2E_TMP="$tmp"
  python3 - "$XRAY_CFG" "$tmp" "$port" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
c["inbounds"] = [{
    "tag": "xui-ai-e2e", "port": int(sys.argv[3]), "listen": "127.0.0.1",
    "protocol": "socks", "settings": {"auth": "noauth", "udp": False},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
}]
c.pop("api", None)
c.pop("metrics", None)
json.dump(c, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
  "$XRAY_BIN" -c "$tmp" >"$logf" 2>&1 &
  E2E_PID=$!
  for i in 1 2 3 4 5; do
    kill -0 "$E2E_PID" 2>/dev/null || break
    if python3 -c 'import socket,sys;s=socket.socket();s.settimeout(0.3);s.connect(("127.0.0.1",int(sys.argv[1])));s.close()' "$port" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! kill -0 "$E2E_PID" 2>/dev/null; then
    cat "$logf" >&2
    log "E2E ERROR: temporary Xray instance failed to start"
    e2e_cleanup
    return 1
  fi

  px="socks5h://127.0.0.1:$port"
  echo "=== E2E through Xray (expected IPv6 $expected) ==="
  if [[ "$PROVIDER" == "gemini" ]]; then
    # Google endpoints do not echo the client IP; HTTP success through the real
    # routing + the preflight AAAA/egress check above is the proof for Gemini.
    code="$(curl -s -L --max-time "$E2E_TIMEOUT" -x "$px" -o /dev/null -w '%{http_code}' https://gemini.google.com/generate_204 2>/dev/null || true)"
    if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
      log "E2E OK: gemini.google.com via Xray -> HTTP $code"
    else
      log "E2E FAIL: gemini.google.com via Xray -> HTTP ${code:-000}"
      rc=1
    fi
  else
    if [[ "$PROVIDER" == "claude" ]]; then
      trace_ip="$(curl -s --max-time "$E2E_TIMEOUT" -x "$px" https://claude.ai/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2;exit}' || true)"
    else
      trace_ip="$(curl -s --max-time "$E2E_TIMEOUT" -x "$px" https://chatgpt.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2;exit}' || true)"
    fi
    if [[ "$trace_ip" == "$expected" ]]; then
      log "E2E OK: $PROVIDER via Xray exits over IPv6 $trace_ip"
    elif [[ -n "$trace_ip" && "$trace_ip" == *:* ]]; then
      log "E2E WARN: $PROVIDER exits over IPv6 $trace_ip (expected $expected)"
    else
      log "E2E FAIL: $PROVIDER exits over ${trace_ip:-nothing} (expected $expected)"
      rc=1
    fi
  fi

  ctrl="$(curl -s --max-time "$E2E_TIMEOUT" -x "$px" https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$ctrl" && "$ctrl" != *:* ]]; then
    log "E2E OK: control api.ipify.org keeps the old IPv4 route ($ctrl)"
  elif [[ -n "$ctrl" ]]; then
    log "E2E WARN: control api.ipify.org went IPv6 ($ctrl) — other rules may be affected"
    rc=1
  else
    log "E2E WARN: control api.ipify.org returned no answer"
    rc=1
  fi

  e2e_cleanup
  return "$rc"
}

cmd_test() {
  local ip="${1:-}"
  [[ -n "$ip" ]] || ip="$(find_ipv6 soft)"
  [[ -n "$ip" ]] || { log "ERROR: no IPv6 address available"; return 1; }
  echo "=== OpenAI / ChatGPT over IPv6 — diagnostics (no config changes) ==="
  log "source IPv6: $ip"
  local seen; seen="$(curl -6 -s --interface "$ip" --max-time "$TIMEOUT" https://api6.ipify.org 2>/dev/null || true)"
  [[ "$seen" == "$ip" ]] && log "OK: outbound IPv6 = $seen" || log "WARN: outbound IPv6 = ${seen:-none}"
  for h in $SAMPLES; do
    if python3 -c 'import socket,sys;socket.getaddrinfo(sys.argv[1],443,socket.AF_INET6)' "$h" 2>/dev/null; then
      log "OK: AAAA $h"
    else
      log "WARN: no AAAA for $h"
    fi
  done
  for pair in $TEST_URLS; do
    local url="${pair%%|*}" expect="${pair##*|}"
    local code; code="$(http_code "$url" "$ip")"
    if [[ "$code" == "$expect" || ( "$expect" == "any" && "$code" =~ ^[0-9]{3}$ && "$code" != "000" ) || ( "$expect" == "2xx-4xx" && "$code" =~ ^[24][0-9][0-9]$ ) ]]; then
      log "OK: $url -> HTTP $code"
    else
      log "WARN: $url -> HTTP $code (expected $expect)"
    fi
  done
  if [[ -n "${XUI_AI_TEST_PROXY:-}" ]]; then
    local pip
    pip="$(curl -s --max-time "$TIMEOUT" -x "$XUI_AI_TEST_PROXY" https://api6.ipify.org 2>/dev/null || true)"
    if [[ "$pip" == *:* ]]; then
      log "OK: proxy test exit IPv6 = $pip"
    else
      log "WARN: proxy test failed (${pip:-no response})"
    fi
  fi
  if [[ -f "$XRAY_CFG" ]]; then
    cmd_status || true
    validate_generated || true
  fi
  if [[ "${XUI_AI_SKIP_E2E:-0}" != "1" ]]; then
    e2e_test "$ip" || true
  fi
}

rollback() {
  log "rolling back from the latest DB backup"
  local last; last="$(ls -1t "$BACKUP_DIR"/x-ui.db.bak-* 2>/dev/null | head -1)"
  [[ -n "$last" ]] || die "no backup found for rollback"
  systemctl stop "$SERVICE" || true
  cp -a "$last" "$DB"
  restart_panel || true
}

cmd_apply() {
  check_root
  [[ -f "$DB" ]] || die "DB not found: $DB (override XUI_DB)"
  [[ -x "$XRAY_BIN" ]] || die "Xray not found: $XRAY_BIN"
  local ip; ip="$(find_ipv6)"
  preflight_ai_ipv6 "$ip"
  backup
  systemctl stop "$SERVICE"
  export XUI_AI_MODE=add XUI_AI_DB="$DB" XUI_AI_TAG="$TAG" XUI_AI_RULETAG="$RULE_TAG" \
         XUI_AI_DOMAINS="$DOMAINS" XUI_AI_GEOSITE="$GEOSITE" \
         XUI_AI_DNSSERVER="$DNS_SERVER" XUI_AI_IPV6="$ip" XUI_AI_STATE="$STATE_FILE"
  if ! patch_template; then
    systemctl start "$SERVICE" || true
    die "failed to patch template"
  fi
  restart_panel
  if ! check_generated; then
    log "ERROR: generated config did not pick up the patch"
    rollback
    die "rolled back"
  fi
  if ! validate_generated; then
    rollback
    die "rolled back: invalid generated config"
  fi
  log "done: OpenAI / ChatGPT traffic -> $TAG -> $ip (IPv6)"
  if [[ "${XUI_AI_SKIP_TEST:-0}" != "1" ]]; then cmd_test "$ip" || true; fi
}

cmd_remove() {
  check_root
  [[ -f "$DB" ]] || die "DB not found: $DB"
  backup
  systemctl stop "$SERVICE"
  export XUI_AI_MODE=remove XUI_AI_DB="$DB" XUI_AI_TAG="$TAG" XUI_AI_RULETAG="$RULE_TAG" \
         XUI_AI_DOMAINS="$DOMAINS" XUI_AI_GEOSITE="$GEOSITE" \
         XUI_AI_DNSSERVER="$DNS_SERVER" XUI_AI_IPV6="" XUI_AI_STATE="$STATE_FILE"
  patch_template || { systemctl start "$SERVICE" || true; die "failed to remove patch"; }
  restart_panel
  log "removed $TAG / $RULE_TAG / IPv6 DNS entry"
}

case "${1:-}" in
  apply)  cmd_apply ;;
  remove) cmd_remove ;;
  status) cmd_status ;;
  test)   cmd_test ;;
  *)      usage; exit 1 ;;
esac
