#!/bin/bash
# ==============================================================
# NaiveProxy 实时流量监控仪表盘
# 功能：
#   每 N 秒刷新一次，显示每个账户的：
#     - 活跃连接数（来自 ss）
#     - 累计流量（来自 traffic_by_user.json）
#     - 近期速率（滚动窗口）
#     - 配额占比 + 进度条
#     - 最近访问的 3 个目标 URL（来自 proxy.log）
#
# 前置条件：
#   1. Caddyfile 添加 JSON 访问日志：
#      log {
#        output file /var/log/caddy/proxy.log
#        format json
#      }
#   2. 全局开启 log_credentials（否则 Proxy-Authorization 被脱敏）：
#      servers {
#        log_credentials
#      }
#   3. 建议把 traffic_stats_interval 设为 1~2s 以获得实时流量：
#      traffic_stats_interval 1s
#
# 用法：
#   ./proxy_live.sh          实时仪表盘（每 REFRESH_INTERVAL 秒刷新，Ctrl-C 退出）
#   ./proxy_live.sh -n       单次快照（刷新一次后退出）
#
# 配额配置：
#   自动从 Caddyfile 的 traffic_quota 块解析（改 Caddyfile 即生效，无需改本脚本）。
#   CADDYFILE 路径可用环境变量覆盖：CADDYFILE=/path/to/Caddyfile ./proxy_live.sh
#   仅当 Caddyfile 找不到或解析为空时，回退到下方 QUOTA_MAP_FALLBACK。
#   不在 traffic_quota 里的账户视为不限流量。
#
# ── 本版修复记录 ──
#   问题：某些账户的"活跃连接/最近访问 URL"长期空白，即使确实在用、
#         且累计流量在增长。
#   根因：脚本原先只解析 status == 200 的日志行来提取用户名
#         （Proxy-Authorization 头）。但 NaiveProxy 的 probe_resistance
#         特性会让不少正常请求（探测判定、握手/重试时机等）返回 400，
#         这些 400 请求里其实也带着合法的 Basic auth 头，之前被直接
#         跳过，导致该用户完全没有被记入"活跃"或"最近 URL"。
#   修复：status 过滤放宽为 200 和 400 都尝试解析用户名；
#         活跃连接数只统计 200（代表连接确实成功转发），
#         但 400 的请求单独统计为"连接异常"提示，并且仍然计入
#         "最近访问"轨迹（标注为异常），方便判断到底是没用还是连不上。
# ==============================================================

PROXY_LOG="/var/log/caddy/proxy.log"
TRAFFIC_JSON="/var/log/caddy/traffic_by_user.json"
REFRESH_INTERVAL=1
TAIL_BYTES=2097152        # 读 proxy.log 末尾 2MB
RECENT_WINDOW=300          # 活跃连接回查窗口（秒）
RATE_WINDOW=3             # 速率滚动窗口（秒）；默认 60 兼容 30s 写盘，设 2s 写盘时可改为 6
CADDYFILE="${CADDYFILE:-/root/Caddyfile}"   # 配额自动从此解析，可用环境变量覆盖

SINGLE_SHOT=0
if [ "$1" = "-n" ] || [ "$1" = "--once" ]; then
    SINGLE_SHOT=1
fi

# ========== 配额：自动从 Caddyfile 的 traffic_quota 块解析 ==========
# 改 Caddyfile 的 traffic_quota 即生效，无需改本脚本。
# 仅当 Caddyfile 找不到或解析为空时，回退到下方 QUOTA_MAP_FALLBACK。
QUOTA_MAP_FALLBACK=(
    "Shane=333GB"
    "Clyde=333GB"
    "Tamir=333GB"
    "Gaojiji=333GB"
    "TeacherJ=333GB"
    # adminZ 不限流量，不列出
)

# 将人类可读配额字符串转为字节数
parse_quota() {
    local s="${1^^}"  # 转大写
    s="${s// /}"       # 去空格
    local num="${s%%[BKMGT]*}"
    local unit="${s##*[0-9]}"
    local mult=1
    case "$unit" in
        TB)     mult=$((1024*1024*1024*1024)) ;;
        GB)     mult=$((1024*1024*1024)) ;;
        MB)     mult=$((1024*1024)) ;;
        KB)     mult=$((1024)) ;;
        B|"")   mult=1 ;;
        *)      echo "-1"; return 1 ;;
    esac
    python3 -c "print(int(float('$num') * $mult))"
}

# 从 Caddyfile 解析 traffic_quota 块，逐行输出 "user=size"
parse_quota_block() {
    [ -f "$CADDYFILE" ] || return 1
    awk '
        /traffic_quota[ \t]*\{/ { in_block=1; next }
        in_block && /^[ \t]*\}/ { in_block=0; next }
        in_block && NF>=2 && $1 !~ /^#/ { printf "%s=%s\n", $1, $2 }
    ' "$CADDYFILE"
}

# 构建配额字节数关联数组（优先 Caddyfile，回退 QUOTA_MAP_FALLBACK）
declare -A QUOTA_BYTES
quota_entries=()
if parsed=$(parse_quota_block 2>/dev/null) && [ -n "$parsed" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && quota_entries+=("$line")
    done <<< "$parsed"
fi
if [ ${#quota_entries[@]} -eq 0 ]; then
    quota_entries=("${QUOTA_MAP_FALLBACK[@]}")
fi
for entry in "${quota_entries[@]}"; do
    user="${entry%=*}"
    quota_str="${entry#*=}"
    quota_bytes=$(parse_quota "$quota_str")
    if [ $? -eq 0 ] && [ "$quota_bytes" != "-1" ]; then
        QUOTA_BYTES["$user"]="$quota_bytes"
    fi
done

# 拼配额字符串传给 python: 'user1':123,'user2':456
QUOTA_ENV=""
for user in "${!QUOTA_BYTES[@]}"; do
    QUOTA_ENV="${QUOTA_ENV}'${user}':${QUOTA_BYTES[$user]},"
done
QUOTA_ENV="${QUOTA_ENV%,}"

export _PL_PROXY_LOG="$PROXY_LOG"
export _PL_TRAFFIC_JSON="$TRAFFIC_JSON"
export _PL_REFRESH="$REFRESH_INTERVAL"
export _PL_TAIL_BYTES="$TAIL_BYTES"
export _PL_RECENT_WINDOW="$RECENT_WINDOW"
export _PL_RATE_WINDOW="$RATE_WINDOW"
export _PL_QUOTA_ENV="$QUOTA_ENV"
export _PL_SINGLE_SHOT="$SINGLE_SHOT"

exec python3 << 'PYEOF'
import json, os, subprocess, sys, time, base64, collections, io

PROXY_LOG      = os.environ["_PL_PROXY_LOG"]
TRAFFIC_JSON   = os.environ["_PL_TRAFFIC_JSON"]
REFRESH        = int(os.environ["_PL_REFRESH"])
TAIL_BYTES     = int(os.environ["_PL_TAIL_BYTES"])
RECENT_WINDOW  = int(os.environ["_PL_RECENT_WINDOW"])
RATE_WINDOW    = int(os.environ["_PL_RATE_WINDOW"])
QUOTA_STR      = os.environ.get("_PL_QUOTA_ENV", "")
SINGLE_SHOT    = os.environ["_PL_SINGLE_SHOT"] == "1"

# Parse quota from env string
quota = {}
if QUOTA_STR:
    for pair in QUOTA_STR.split(","):
        if ":" in pair:
            u, b = pair.split(":", 1)
            u = u.strip("'\" ")
            b = b.strip("'\" ")
            if u and b:
                quota[u] = int(b)

# Rate history: {user: deque of (ts, bytes)}
rate_history = {}

def fmt(b):
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KB"
    elif b < 1024**3:
        return f"{b/1024**2:.2f} MB"
    else:
        return f"{b/1024**3:.2f} GB"

def fmt_rate(bps):
    if bps < 1024:
        return f"{bps:.0f} B/s"
    elif bps < 1024**2:
        return f"{bps/1024:.1f} KB/s"
    elif bps < 1024**3:
        return f"{bps/1024**2:.2f} MB/s"
    else:
        return f"{bps/1024**3:.2f} GB/s"

def pct_bar(pct, width=12):
    filled = int(width * min(pct, 100) / 100)
    return "█" * filled + "░" * (width - filled)

def fmt_rel_time(seconds_ago):
    if seconds_ago < 5:
        return "just now"
    elif seconds_ago < 60:
        return f"{int(seconds_ago)}s"
    elif seconds_ago < 3600:
        return f"{int(seconds_ago/60)}m"
    else:
        return f"{int(seconds_ago/3600)}h"

def dwidth(s):
    """Display width: CJK/wide chars = 2, others = 1."""
    w = 0
    for ch in s:
        cp = ord(ch)
        # CJK Unified Ideographs, CJK Compatibility, Fullwidth forms, etc.
        if (0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF or
            0x3400 <= cp <= 0x4DBF or 0x2E80 <= cp <= 0x2EFF or
            0x3000 <= cp <= 0x303F or 0xFF00 <= cp <= 0xFFEF or
            0x2580 <= cp <= 0x259F):  # block elements █ ░
            w += 2
        else:
            w += 1
    return w

def lpad(s, width):
    """Left-align string to display width."""
    return s + ' ' * max(0, width - dwidth(s))

def rpad(s, width):
    """Right-align string to display width."""
    return ' ' * max(0, width - dwidth(s)) + s

def truncate(s, maxlen):
    """Truncate string to maxlen chars, appending … if needed."""
    if len(s) <= maxlen:
        return s
    return s[:maxlen - 1] + "…"

# Column widths (display columns)
COL_USER = 12
COL_ACTIVE = 4
COL_USED = 12
COL_RATE = 12
COL_QUOTA = 8
COL_PCT = 8
COL_BAR = 12
MAX_URL_LEN = 35

def tail_file(path, max_bytes):
    """Read the last max_bytes of a file, return lines."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            start = max(0, size - max_bytes)
            f.seek(start)
            raw = f.read()
        # Decode, skip partial first line if we seeked mid-file
        text = raw.decode("utf-8", errors="replace")
        lines = text.splitlines()
        if start > 0 and lines:
            lines = lines[1:]  # skip potentially partial first line
        return lines
    except FileNotFoundError:
        return []
    except Exception:
        return []

def get_active_ips():
    """Get set of active peer IPs on port 443 via ss."""
    try:
        result = subprocess.run(
            ["ss", "-tn", "state", "established", "( sport = :443 )"],
            capture_output=True, text=True, timeout=5
        )
        ips = set()
        for line in result.stdout.strip().split("\n")[1:]:
            parts = line.split()
            if len(parts) >= 4:
                peer = parts[3]
                ip = peer.rsplit(":", 1)[0].replace("::ffff:", "").strip("[]")
                ips.add(ip)
        return ips
    except Exception:
        return set()

def decode_username(entry):
    """Extract username from Proxy-Authorization Basic auth header, or None."""
    auth_list = entry.get("request", {}).get("headers", {}).get("Proxy-Authorization", [])
    auth = auth_list[0] if auth_list else ""
    if not auth.startswith("Basic "):
        return None
    try:
        cred = base64.b64decode(auth[6:]).decode()
        return cred.split(":")[0]
    except Exception:
        return None

def parse_proxy_log(lines, now, active_ips):
    """
    Parse proxy.log lines.

    NOTE (修复说明):
      NaiveProxy 的 probe_resistance 会让不少合法客户端的请求返回 400
      （探测判定 / 重试时机 / 握手细节等），而不是 200。这些 400 请求里
      往往仍然带有合法的 Proxy-Authorization 头。旧版脚本只解析 200，
      导致这部分用户即使一直在用，也完全不出现在"活跃"或"最近 URL"里。
      现在 200 和 400 都尝试解析用户名：
        - 200 -> 计入真正的"活跃连接数"（需要 IP 命中 ss 快照）+ 正常 URL
        - 400 -> 不计入活跃连接数，但计入"最近访问"轨迹并标注为异常，
                 同时用于生成"连接异常"提示，帮助判断是没用还是连不上。

    Returns:
      ip_to_user: {ip: username} 用于 200 且命中 active_ips 的连接
      user_urls: {user: [(uri, ts, status)]} 最近 3 条记录（200/400 都算）
      user_error_count: {user: 最近 RECENT_WINDOW 秒内 400 请求数}
    """
    ip_to_user = {}
    # user -> {uri: (latest_ts, status)} for dedup
    user_uri_latest = collections.defaultdict(dict)
    user_error_count = collections.Counter()
    cutoff = now - RECENT_WINDOW
    url_cutoff = now - 3600  # URL 轨迹用更宽的窗口，方便看近1小时活动

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue

        ts = entry.get("ts", 0)
        status = entry.get("status")

        if status not in (200, 400):
            continue

        username = decode_username(entry)
        if not username:
            continue

        remote_ip = entry.get("request", {}).get("remote_ip", "")
        uri = entry.get("request", {}).get("uri", "")

        if status == 200:
            # 真正成功转发的连接：计入活跃连接数（需要 IP 命中当前 ss 快照）
            if ts >= cutoff and remote_ip in active_ips:
                ip_to_user[remote_ip] = username
        else:  # status == 400
            if ts >= cutoff:
                user_error_count[username] += 1

        # URL / 活动轨迹：200 和 400 都记录，取每个 (user, uri) 最新一条
        if ts >= url_cutoff and uri:
            prev = user_uri_latest[username].get(uri)
            if prev is None or ts > prev[0]:
                user_uri_latest[username][uri] = (ts, status)

    # Build user_urls: top 3 most recent distinct URIs per user
    user_urls = {}
    for user, uri_dict in user_uri_latest.items():
        sorted_uris = sorted(uri_dict.items(), key=lambda x: -x[1][0])[:3]
        # flatten to (uri, ts, status)
        user_urls[user] = [(uri, ts_status[0], ts_status[1]) for uri, ts_status in sorted_uris]

    return ip_to_user, user_urls, user_error_count

# ─── Main loop ──────────────────────────────────────────────
try:
    while True:
        now = time.time()
        now_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))

        # 缓存本帧输出，最后一次性原地重绘（光标归位 + 逐行清行尾），避免整屏 clear 造成闪烁
        _frame = io.StringIO()
        _real_stdout = sys.stdout
        sys.stdout = _frame

        # ─── Header ───
        print(f"\033[1;36m{'=' * 60}\033[0m")
        print(f"\033[1;36m  NaiveProxy 实时监控   {now_str}   (每{REFRESH}s刷新)\033[0m")
        print(f"\033[1;36m{'=' * 60}\033[0m")

        # ─── Active IPs ───
        active_ips = get_active_ips()

        # ─── Proxy log ───
        log_lines = tail_file(PROXY_LOG, TAIL_BYTES)
        if not log_lines:
            print()
            print(f"  \033[33m⚠ 未找到访问日志: {PROXY_LOG}\033[0m")
            print(f"  请确认 Caddyfile 配置了:")
            print(f"    log {{ output file {PROXY_LOG} format json }}")
            print(f"    servers {{ log_credentials }}")
        if log_lines:
            ip_to_user, user_urls, user_error_count = parse_proxy_log(log_lines, now, active_ips)
        else:
            ip_to_user, user_urls, user_error_count = {}, {}, collections.Counter()

        # Count active connections per user (仅 200 状态)
        active_per_user = collections.Counter(ip_to_user.values())
        total_active = len(active_ips)

        # ─── Traffic JSON ───
        traffic = {}
        traffic_mtime = 0
        try:
            with open(TRAFFIC_JSON) as f:
                traffic = json.load(f)
            traffic_mtime = os.path.getmtime(TRAFFIC_JSON)
        except (FileNotFoundError, json.JSONDecodeError):
            if not traffic:
                print()
                print(f"  \033[33m⚠ 尚未找到统计文件: {TRAFFIC_JSON}\033[0m")
                print(f"  caddy 启动后需要等待一个写盘周期才会生成。")

        traffic_age = now - traffic_mtime if traffic_mtime else 0

        # ─── Rate computation ───
        for user, cur_bytes in traffic.items():
            if user not in rate_history:
                rate_history[user] = collections.deque()
            rate_history[user].append((now, cur_bytes))
            # Prune old samples
            while rate_history[user] and rate_history[user][0][0] < now - RATE_WINDOW:
                rate_history[user].popleft()

        # Remove users no longer in traffic
        for user in list(rate_history.keys()):
            if user not in traffic:
                del rate_history[user]

        # ─── Render table ───
        sep = "  " + "─" * COL_USER + "  " + "─" * COL_ACTIVE + "  " + "─" * COL_USED + "  " + "─" * COL_RATE + "  " + "─" * COL_QUOTA + "  " + "─" * COL_PCT + "  " + "─" * COL_BAR

        print()
        print(f"\033[1m  {lpad('账户', COL_USER)}  {rpad('活跃', COL_ACTIVE)}  {lpad('累计流量', COL_USED)}  {lpad('速率', COL_RATE)}  {lpad('配额', COL_QUOTA)}  {lpad('占比', COL_PCT)}  {lpad('进度条', COL_BAR)}\033[0m")
        print(sep)

        if not traffic:
            print(f"  {lpad('(暂无数据)', COL_USER)}")
        else:
            sorted_users = sorted(traffic.items(), key=lambda x: -x[1])
            for user, cur_bytes in sorted_users:
                conn_count = active_per_user.get(user, 0)
                conn_str = str(conn_count) if conn_count > 0 else "-"
                used_str = fmt(cur_bytes)

                # Rate
                hist = rate_history.get(user, collections.deque())
                if len(hist) >= 2:
                    oldest_ts, oldest_bytes = hist[0]
                    latest_ts, latest_bytes = hist[-1]
                    dt = latest_ts - oldest_ts
                    if dt > 0.5:
                        rate_bps = max(0, (latest_bytes - oldest_bytes) / dt)
                        rate_str = fmt_rate(rate_bps)
                    else:
                        rate_str = "..."
                else:
                    rate_str = "..."

                # Quota
                if user in quota and quota[user] > 0:
                    q = quota[user]
                    pct = (cur_bytes / q * 100) if q > 0 else 0
                    pct_str = f"{pct:.1f}%"
                    quota_str = fmt(q)
                    bar = pct_bar(pct)
                else:
                    pct_str = "∞"
                    quota_str = "不限"
                    bar = "─" * 12

                print(f"  \033[1m{lpad(user, COL_USER)}\033[0m  {rpad(conn_str, COL_ACTIVE)}  {lpad(used_str, COL_USED)}  {lpad(rate_str, COL_RATE)}  {lpad(quota_str, COL_QUOTA)}  {lpad(pct_str, COL_PCT)}  {bar}")

                # Top 3 recent URLs / activity for this user (200 和 400 都显示)
                urls = user_urls.get(user, [])
                if urls:
                    for uri, ts, status in urls:
                        ago = now - ts
                        rel = fmt_rel_time(ago)
                        display_uri = truncate(uri.replace(":443", "") if uri.endswith(":443") else uri, MAX_URL_LEN)
                        if status == 200:
                            print(f"  {'':>{COL_USER}}  ↳ \033[2m{display_uri}  {rel}\033[0m")
                        else:
                            print(f"  {'':>{COL_USER}}  ↳ \033[33m{display_uri}  {rel}  [{status}]\033[0m")
                else:
                    print(f"  {'':>{COL_USER}}  ↳ \033[2m(近期无访问)\033[0m")

                # 连接异常提示：最近窗口内有 400 但没有对应的活跃 200 连接
                err_count = user_error_count.get(user, 0)
                if err_count > 0:
                    print(f"  {'':>{COL_USER}}  ↳ \033[33m⚠ 最近{RECENT_WINDOW}s内 {err_count} 次请求被拒(400)，"
                          f"可能是 probe_resistance 拦截或客户端配置问题\033[0m")

                print()  # blank line between accounts

        # ─── Summary ───
        print(sep)
        total_bytes = sum(traffic.values()) if traffic else 0
        print(f"  {lpad('总计', COL_USER)}  {rpad(str(total_active), COL_ACTIVE)}  {fmt(total_bytes)}")
        if traffic_mtime:
            mtime_str = time.strftime("%H:%M:%S", time.localtime(traffic_mtime))
            age_hint = ""
            if traffic_age > 30:
                age_hint = " \033[33m⚠ 数据较旧，建议 traffic_stats_interval 2s\033[0m"
            print(f"  \033[2m(流量数据更新于 {mtime_str}，{traffic_age:.0f}s前){age_hint}\033[0m")

        # ─── Footer ───
        print()
        print(f"\033[2m  Ctrl-C 退出 | 活跃=ss实时(仅200) | 黄色=400(可能被probe_resistance拦截) | 流量={TRAFFIC_JSON}\033[0m")
        print(f"\033[2m  URL来源={PROXY_LOG} (需 log_credentials)\033[0m")
        print(f"\033[2m  实时流量建议: traffic_stats_interval 1~2s\033[0m")

        # 恢复 stdout，一次性原地输出本帧：归位 -> 逐行(清行尾+内容) -> 清余下旧行
        sys.stdout = _real_stdout
        parts = ["\033[H"]
        for _ln in _frame.getvalue().split("\n"):
            parts.append("\033[K" + _ln + "\n")
        parts.append("\033[J")
        sys.stdout.write("".join(parts))
        sys.stdout.flush()

        if SINGLE_SHOT:
            break

        time.sleep(REFRESH)

except KeyboardInterrupt:
    sys.stdout = sys.__stdout__
    sys.stdout.write("\033[?25h\033[2J\033[H")
    print("\n实时监控已停止。")
    sys.exit(0)
PYEOF