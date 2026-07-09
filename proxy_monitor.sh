#!/bin/bash
# ==============================================================
# NaiveProxy 账户监控脚本 v3
# 功能：
#   1. 显示当前活跃连接（谁正连着，来自哪个IP）
#   2. 显示每个账户本月累计流量（真实字节数）+ 配额占比
#   3. 支持月度归档：每月初手动执行一次 --archive，把上月数据存档并清零重新计数
#
# 用法：
#   ./proxy_monitor.sh                  查看当前状态（含本统计周期累计流量+配额占比）
#   ./proxy_monitor.sh --archive        将当前流量数据归档（按日期存档），并清零重新开始统计
#   ./proxy_monitor.sh --json           以JSON格式输出流量数据（供其他脚本调用）
#
# 配额配置：
#   修改下方 QUOTA_MAP 中的 用户名=字节数，与 Caddyfile 中的 traffic_quota 对应。
#   支持人类可读格式如 50GB、1TB 等。不在此列表中的用户视为不限流量。
# ==============================================================

PROXY_LOG="/var/log/caddy/proxy.log"
TRAFFIC_JSON="/var/log/caddy/traffic_by_user.json"
ARCHIVE_DIR="/var/log/caddy/traffic_archive"
ACTION="${1:-status}"

# ========== 配额配置（与 Caddyfile traffic_quota 对应）==========
# 格式: "用户名=配额"，配额支持 B/KB/MB/GB/TB 后缀（不区分大小写）
# 不在此列表中的用户 = 不限流量（显示为 ∞）
QUOTA_MAP=(
    "user2=50GB"
    "user3=20GB"
    "user4=100GB"
    # user1 / user5 不限流量，不列出
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
    # 用 python3 算乘法避免 shell 溢出
    python3 -c "print(int(float('$num') * $mult))"
}

# 构建配额字节数关联数组
declare -A QUOTA_BYTES
for entry in "${QUOTA_MAP[@]}"; do
    user="${entry%=*}"
    quota_str="${entry#*=}"
    quota_bytes=$(parse_quota "$quota_str")
    if [ $? -eq 0 ] && [ "$quota_bytes" != "-1" ]; then
        QUOTA_BYTES["$user"]="$quota_bytes"
    fi
done

fmt_bytes_py() {
python3 -c "
b = $1
if b < 1024:
    print(f'{b} B')
elif b < 1024**2:
    print(f'{b/1024:.1f} KB')
elif b < 1024**3:
    print(f'{b/1024**2:.2f} MB')
else:
    print(f'{b/1024**3:.2f} GB')
"
}

# ---------- --json 模式 ----------
if [ "$ACTION" == "--json" ]; then
    if [ -f "$TRAFFIC_JSON" ]; then
        cat "$TRAFFIC_JSON"
    else
        echo "{}"
    fi
    exit 0
fi

# ---------- --archive 模式：归档当前数据并清零 ----------
if [ "$ACTION" == "--archive" ]; then
    if [ ! -f "$TRAFFIC_JSON" ]; then
        echo "没有找到统计文件，无需归档: $TRAFFIC_JSON"
        exit 1
    fi

    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_NAME="traffic_$(date '+%Y-%m').json"
    ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_NAME"

    if [ -f "$ARCHIVE_PATH" ]; then
        echo "警告: $ARCHIVE_PATH 已存在，将被覆盖"
        read -p "确认继续吗？(y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "已取消"
            exit 0
        fi
    fi

    cp "$TRAFFIC_JSON" "$ARCHIVE_PATH"
    echo "已归档到: $ARCHIVE_PATH"
    echo ""
    echo "归档内容："
    cat "$ARCHIVE_PATH"
    echo ""
    echo ""
    echo "⚠️  重要提醒："
    echo "  这个脚本只是【复制归档】，并没有真正清零 caddy 进程内存里的计数器。"
    echo "  因为 caddy 是持续运行的进程，内存中的 sync.Map 计数器不会因为你复制了"
    echo "  文件就重置。要让下个月的统计从0开始，你需要重启 caddy 进程，且重启前"
    echo "  要把 $TRAFFIC_JSON 文件清空或删除，否则 loadTrafficStats 会重新加载"
    echo "  归档前的数值继续累加。"
    echo ""
    echo "  真正重置的步骤："
    echo "    1. 已执行归档（上面已完成）"
    echo "    2. 停止 caddy 进程: pkill -f 'caddy run'"
    echo "    3. 删除或清空统计文件: rm $TRAFFIC_JSON"
    echo "    4. 重新启动 caddy: cd /root && nohup ./caddy run > /var/log/caddy_stdout.log 2>&1 &"
    echo ""
    read -p "是否现在就执行 步骤2-4 完成真正重置？这会短暂中断代理服务几秒钟 (y/N): " do_reset
    if [ "$do_reset" == "y" ] || [ "$do_reset" == "Y" ]; then
        echo "正在重启 caddy 以重置计数器..."
        pkill -f "caddy run"
        sleep 2
        rm -f "$TRAFFIC_JSON"
        cd /root
        nohup ./caddy run > /var/log/caddy_stdout.log 2>&1 &
        sleep 3
        echo "重启完成，当前进程状态："
        ps aux | grep "caddy run" | grep -v grep
    else
        echo "已跳过重置步骤，统计仍在累计中（本次归档只是留了个快照，没有清零）"
    fi
    exit 0
fi

# ---------- 默认模式：显示状态 ----------
echo "=================================================="
echo "  NaiveProxy 账户监控   $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================="

# ---------- 第一部分：当前活跃连接 ----------
echo ""
echo "【当前活跃连接】"
echo "--------------------------------------------------"

CONN_COUNT=$(ss -tn state established '( sport = :443 )' 2>/dev/null | tail -n +2 | wc -l)

if [ "$CONN_COUNT" -eq 0 ]; then
    echo "  当前没有活跃连接"
else
    echo "  共 $CONN_COUNT 条连接"
    echo ""
    if [ -f "$PROXY_LOG" ]; then
        python3 << 'PYEOF'
import json, base64, time, subprocess

now = time.time()

result = subprocess.run(
    ["ss", "-tn", "state", "established", "( sport = :443 )"],
    capture_output=True, text=True
)
active_ips = set()
for line in result.stdout.strip().split("\n")[1:]:
    parts = line.split()
    if len(parts) >= 4:
        peer = parts[3]
        ip = peer.rsplit(":", 1)[0].replace("::ffff:", "").strip("[]")
        active_ips.add(ip)

if not active_ips:
    print("  (无活跃连接)")
else:
    ip_to_user = {}
    try:
        with open('/var/log/caddy/proxy.log') as f:
            for line in f:
                try:
                    entry = json.loads(line)
                    if now - entry.get('ts', 0) > 300:
                        continue
                    ip = entry.get('request', {}).get('remote_ip', '')
                    if ip not in active_ips:
                        continue
                    auth = entry.get('request', {}).get('headers', {}).get('Proxy-Authorization', [''])[0]
                    if not auth.startswith('Basic '):
                        continue
                    cred = base64.b64decode(auth[6:]).decode()
                    user = cred.split(':')[0]
                    status = entry.get('status')
                    if status == 200:
                        ip_to_user[ip] = user
                except Exception:
                    continue
    except FileNotFoundError:
        pass

    for ip in sorted(active_ips):
        user = ip_to_user.get(ip, "未知(最近5分钟无成功认证记录)")
        print(f"  {ip:<20} -> {user}")
PYEOF
    fi
fi

# ---------- 第二部分：本统计周期流量 + 配额占比 ----------
echo ""
echo "【本统计周期累计流量 + 配额占比】"
echo "--------------------------------------------------"

if [ ! -f "$TRAFFIC_JSON" ]; then
    echo "  尚未找到统计文件: $TRAFFIC_JSON"
else
    # 将 QUOTA_BYTES 传给 python
    QUOTA_ENV=""
    for user in "${!QUOTA_BYTES[@]}"; do
        QUOTA_ENV="${QUOTA_ENV}'${user}':${QUOTA_BYTES[$user]},"
    done

    python3 << PYEOF
import json, os
from datetime import datetime

with open("$TRAFFIC_JSON") as f:
    data = json.load(f)

mtime = os.path.getmtime("$TRAFFIC_JSON")
print(f"  (最后更新时间: {datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')})")
print()

# 配额映射（字节数），与 Caddyfile traffic_quota 对应
quota = {${QUOTA_ENV%?}}

if not data:
    print("  暂无流量数据")
else:
    def fmt(b):
        if b < 1024:
            return f"{b} B"
        elif b < 1024**2:
            return f"{b/1024:.1f} KB"
        elif b < 1024**3:
            return f"{b/1024**2:.2f} MB"
        else:
            return f"{b/1024**3:.2f} GB"

    def pct_bar(pct, width=12):
        """生成简易进度条"""
        filled = int(width * pct / 100)
        bar = '█' * filled + '░' * (width - filled)
        return bar

    total = sum(data.values())
    sorted_items = sorted(data.items(), key=lambda x: -x[1])

    # 表头
    print(f"  {'账户':<12}{'已用流量':<14}{'配额':<14}{'占比':<8}{'进度条'}")
    print(f"  {'-'*12}{'-'*14}{'-'*14}{'-'*8}{'-'*14}")

    for user, bytes_val in sorted_items:
        share_of_total = (bytes_val / total * 100) if total > 0 else 0
        if user in quota:
            q = quota[user]
            pct_of_quota = (bytes_val / q * 100) if q > 0 else 0
            pct_display = f"{pct_of_quota:.1f}%"
            quota_display = fmt(q)
            bar = pct_bar(min(pct_of_quota, 100))
        else:
            pct_display = "∞"
            quota_display = "不限"
            bar = "────────────"
        print(f"  {user:<12}{fmt(bytes_val):<14}{quota_display:<14}{pct_display:<8}{bar}")

    print(f"  {'-'*12}{'-'*14}{'-'*14}{'-'*8}{'-'*14}")
    print(f"  {'总计':<12}{fmt(total)}")
PYEOF
fi

echo ""
echo "=================================================="
echo "说明："
echo "  - 已用流量：从上次重置(或服务首次启动)到现在的累计值"
echo "  - 占比 = 已用流量 / 配额限额，配额来自脚本顶部的 QUOTA_MAP"
echo "  - 不限流量的用户(如 user1)占比显示为 ∞"
echo "  - 重启 caddy 不会清零（自动从JSON恢复历史值）"
echo "  - 每月自动重置由 Caddyfile 的 traffic_reset_day 控制"
echo "  - 手动归档+重置: ./proxy_monitor.sh --archive"
echo "=================================================="