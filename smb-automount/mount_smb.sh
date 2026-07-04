#!/bin/bash
set -uo pipefail
# 注意：不使用 set -e，因为需要手动处理各种错误情况

# ================================================================
# SMB Auto-Mount Script for macOS
#
# 解决问题：macOS 睡眠后 SMB 共享断开，侧边栏幽灵图标
#
# 策略（两层）：
#   Layer 1: osascript mount volume + 关闭窗口 → 挂载 + 侧边栏恢复
#   Layer 2: update disk                       → 无痛刷新 Finder 缓存
#
# 全程使用 Finder 的钥匙串授权，不再调用 security 命令，
# 彻底消除钥匙串弹窗问题。
#
# 智能判断：只有当 Mac 可能刚唤醒时才执行 Layer 1
#   - 上次运行 > 10 分钟前 → 可能睡过 → 完整刷新
#   - 上次运行 < 10 分钟前 → 一直醒着 → 只做 Layer 2
# ================================================================

# ---- 配置区 ----
# 修改为你的 SMB 服务器 IP
SERVER="<SMB_SERVER_IP>"

# 格式: "共享名|挂载点|URL编码名（中文等需编码）"
# URL编码: 中文可用 python3 -c "import urllib.parse; print(urllib.parse.quote('名称'))"
SHARES=(
    "<SHARE_NAME_1>|/Volumes/<SHARE_NAME_1>|<SHARE_NAME_1>"
    "<SHARE_NAME_2>|/Volumes/<SHARE_NAME_2>|<SHARE_NAME_2_URLENCODED>"
)

# 服务器可达性检查：重试次数 × 间隔
MAX_PING_RETRIES=10
PING_RETRY_DELAY=3

# 多久没运行就认为是"刚唤醒"（秒）
WAKE_THRESHOLD=600

# ---- 路径 ----
LOG_FILE="$HOME/Library/Logs/mount_smb.log"
STATE_FILE="$HOME/Library/Caches/mount_smb.lastrun"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

# 日志同时写入文件
exec >> "$LOG_FILE" 2>&1

# ---- 辅助函数 ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*"; }

is_mounted() {
    mount | grep -q " on ${1} ("
}

# 通过 Finder 挂载一个共享，并关闭弹出的窗口
# 参数: URL编码名, 挂载点路径
mount_via_finder() {
    local URL_NAME="$1"
    local MOUNT_POINT="$2"
    local SMB_URL="smb://${SERVER}/${URL_NAME}"

    osascript -e "
tell application \"Finder\"
    set beforeWindows to count of windows
    try
        mount volume \"${SMB_URL}\"
    end try
    delay 0.3
    set afterWindows to count of windows
    if afterWindows > beforeWindows then
        repeat (afterWindows - beforeWindows) times
            try
                close window 1
            end try
        end repeat
    end if
end tell
" 2>/dev/null
}

# ---- 主流程 ----
log "═══════════════════════════════════════════"
log "SMB Auto-Mount 开始"

# ============================================================
# Step 1: 等待服务器可达
# ============================================================
log "Step 1: 检查服务器 $SERVER ..."

if ping -c 1 -t 2 "$SERVER" &>/dev/null; then
    log "  ✓ 服务器可达"
else
    log "  服务器不可达，等待网络恢复..."
    for i in $(seq 1 $MAX_PING_RETRIES); do
        sleep $PING_RETRY_DELAY
        if ping -c 1 -t 2 "$SERVER" &>/dev/null; then
            log "  ✓ 第 ${i} 次重试后可达"
            break
        fi
        if [ "$i" -eq $MAX_PING_RETRIES ]; then
            log "  ✗ $((MAX_PING_RETRIES * PING_RETRY_DELAY))秒后仍不可达，退出"
            exit 1
        fi
    done
fi

# ============================================================
# Step 2: 挂载每个共享
#
# 全程使用 osascript mount volume，钥匙串授权走 Finder，
# 不再调用 security 命令，彻底消除钥匙串弹窗。
# ============================================================
log "Step 2: 挂载 SMB 共享..."
MOUNTED_ANY=false

for entry in "${SHARES[@]}"; do
    IFS='|' read -r SHARE_NAME MOUNT_POINT URL_NAME <<< "$entry"

    if is_mounted "$MOUNT_POINT"; then
        log "  [$SHARE_NAME] 已挂载，跳过"
        continue
    fi

    log "  [$SHARE_NAME] 未挂载，开始挂载..."

    # 清理残留挂载点
    if [ -d "$MOUNT_POINT" ]; then
        diskutil unmount force "$MOUNT_POINT" 2>/dev/null || true
        sleep 1
    fi

    mount_via_finder "$URL_NAME" "$MOUNT_POINT"

    if is_mounted "$MOUNT_POINT"; then
        log "  [$SHARE_NAME] ✓ 挂载成功"
        MOUNTED_ANY=true
    else
        log "  [$SHARE_NAME] ✗ 挂载失败"
    fi
done

# ============================================================
# Step 3: 刷新 Finder 侧边栏
# ============================================================

# 判断是否需要完整刷新（可能刚唤醒）
LAST_RUN=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)
echo "$NOW" > "$STATE_FILE"
GAP=$((NOW - LAST_RUN))

NEED_FULL_REFRESH=false
if [ "$GAP" -gt $WAKE_THRESHOLD ]; then
    NEED_FULL_REFRESH=true
    log "Step 3: 完整刷新模式（距上次运行 ${GAP}s > ${WAKE_THRESHOLD}s，可能刚唤醒）"
elif [ "$MOUNTED_ANY" = true ]; then
    NEED_FULL_REFRESH=true
    log "Step 3: 完整刷新模式（有新挂载）"
else
    log "Step 3: 轻量刷新模式（距上次运行 ${GAP}s，无需完整刷新）"
fi

for entry in "${SHARES[@]}"; do
    IFS='|' read -r SHARE_NAME MOUNT_POINT URL_NAME <<< "$entry"
    VOL_NAME=$(basename "$MOUNT_POINT")

    if ! is_mounted "$MOUNT_POINT"; then
        log "  [$SHARE_NAME] 未挂载，跳过侧边栏刷新"
        continue
    fi

    # ---- Layer 2: update disk（轻量刷新，无窗口） ----
    osascript -e "
tell application \"Finder\"
    try
        update disk \"${VOL_NAME}\"
    end try
end tell
" 2>/dev/null
    log "  [$SHARE_NAME] update disk ✓"

    # ---- Layer 1: mount volume + 关闭窗口（保证侧边栏恢复） ----
    # 只在"可能刚唤醒"或"有新挂载"时执行
    if [ "$NEED_FULL_REFRESH" = true ]; then
        mount_via_finder "$URL_NAME" "$MOUNT_POINT"
        log "  [$SHARE_NAME] mount volume + close window ✓"
    fi
done

log "SMB Auto-Mount 完成"
log "═══════════════════════════════════════════"
