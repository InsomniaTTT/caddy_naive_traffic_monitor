#!/bin/bash
# ==============================================================
# NaiveProxy 账户监控脚本 v2
# 功能：
#   1. 显示当前活跃连接（谁正连着，来自哪个IP）
#   2. 显示每个账户本月累计流量（真实字节数）
#   3. 支持月度归档：每月初手动执行一次 --archive，把上月数据存档并清零重新计数
#
# 用法：
#   ./proxy_monitor.sh                  查看当前状态（含本统计周期累计流量）
#   ./proxy_monitor.sh --archive        将当前流量数据归档（按日期存档），并清零重新开始统计
#   ./proxy_monitor.sh --json           以JSON格式输出流量数据（供其他脚本调用）
# ==============================================================

PROXY_LOG="/var/log/caddy/proxy.log"
TRAFFIC_JSON="/var/log/caddy/traffic_by_user.json"
ARCHIVE_DIR="/var/log/caddy/traffic_archive"
ACTION="${1:-status}"

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

# ---------- 第二部分：本统计周期流量 ----------
echo ""
echo "【本统计周期累计流量（真实字节数）】"
echo "--------------------------------------------------"

if [ ! -f "$TRAFFIC_JSON" ]; then
    echo "  尚未找到统计文件: $TRAFFIC_JSON"
else
    python3 << PYEOF
import json, os
from datetime import datetime

with open("$TRAFFIC_JSON") as f:
    data = json.load(f)

mtime = os.path.getmtime("$TRAFFIC_JSON")
print(f"  (最后更新时间: {datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')})")
print()

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

    total = sum(data.values())
    sorted_items = sorted(data.items(), key=lambda x: -x[1])

    print(f"  {'账户':<15}{'流量':<15}{'占比'}")
    for user, bytes_val in sorted_items:
        pct = (bytes_val / total * 100) if total > 0 else 0
        print(f"  {user:<15}{fmt(bytes_val):<15}{pct:.1f}%")
    print(f"  {'-'*45}")
    print(f"  {'总计':<15}{fmt(total)}")
PYEOF
fi

echo ""
echo "=================================================="
echo "说明："
echo "  - 这是【累计流量】，从上次重置(或服务首次启动)到现在的总和"
echo "  - 重启 caddy 进程不会清零，因为会自动从JSON文件恢复历史值"
echo "  - 想要按月归档+重新计数，使用: ./proxy_monitor.sh --archive"
echo "=================================================="
