# SMB 自动挂载方案

## 环境信息

| 项目 | 详情 |
|---|---|
| Mac 型号 | MacBook Pro (18,3) |
| 芯片 | Apple M1 Pro |
| 内存 | 16 GB |
| macOS 版本 | 26.5.1 (Build 25F80) |
| SMB 服务器 | `<SMB_SERVER_IP>` |
| SMB 用户名 | `<SMB_USERNAME>` |
| 共享文件夹 | `<SHARE_NAME_1>`、`<SHARE_NAME_2>` |

## 问题

macOS 睡眠后 SMB 连接断开，Finder 侧边栏的共享文件夹变成灰色幽灵图标（云朵+禁止符号），点击提示「未能打开文件夹，因为原始项目无法找到」。

## 原理

macOS 睡眠时会断开网络（`networkoversleep 0`），导致 SMB 会话超时。唤醒后挂载点失效，Finder 侧边栏的 URL bookmark 仍指向已失效的连接，显示为灰色。

## 解决方案

由 launchd 在唤醒/登录/网络变化时触发自动重连。

| 层 | 技术 | 作用 |
|---|---|---|
| 1 | `osascript mount volume` + 关闭窗口 | 挂载 + 侧边栏恢复（Finder 钥匙串授权，无额外弹窗） |
| 2 | `osascript update disk` | 无痛刷新 Finder 缓存 |

全程走 Finder 的钥匙串授权，不调用 `security` 命令，不会弹出钥匙串授权对话框。

### 智能刷新策略

- 距上次运行 **≤ 10 分钟**（Mac 一直醒着）→ 只做 Layer 2，无窗口闪现
- 距上次运行 **> 10 分钟**（可能刚睡醒）→ Layer 1+2，窗口闪现 ~0.3 秒后自动关闭

## 文件

```
~/Library/Scripts/mount_smb.sh                     # 挂载脚本
~/Library/LaunchAgents/com.yourname.mountsmb.plist   # launchd 守护配置
~/Library/Logs/mount_smb.log                        # 运行日志
~/Library/Caches/mount_smb.lastrun                  # 上次运行时间戳
```

## 使用指南

使用前需要根据自己的环境修改配置文件中的占位符。

### 前置条件

已在 Finder 中通过「连接服务器」（⌘K）连接过 SMB 共享，并勾选了「在我的钥匙串中记住此密码」。这样 Finder 已保存凭据，脚本可以直接复用。

### 第一步：修改挂载脚本

编辑 `mount_smb.sh`，找到配置区，替换占位符：

```bash
# ---- 配置区 ----
SERVER="192.168.0.100"          # ← 改为你的 SMB 服务器 IP

SHARES=(
    # 格式: "共享名|挂载点|URL编码名"
    "Documents|/Volumes/Documents|Documents"
    "软件库|/Volumes/软件库|%E8%BD%AF%E4%BB%B6%E5%BA%93"
)
```

**URL 编码**：如果共享名含中文或特殊字符，用以下命令获取编码值：

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote('软件库'))"
# 输出: %E8%BD%AF%E4%BB%B6%E5%BA%93
```

纯英文共享名不需要编码，直接写原名即可。

### 第二步：修改 launchd 配置

编辑 `com.yourname.mountsmb.plist`，将 `<YOUR_USERNAME>` 替换为你的 macOS 用户名：

```bash
# 获取当前用户名
whoami

# 批量替换（假设用户名为 zhangsan）
sed -i '' 's/<YOUR_USERNAME>/zhangsan/g' com.yourname.mountsmb.plist
```

也可以将 `com.yourname.mountsmb` 改为你喜欢的名称，只要保持一致即可。

### 第三步：安装

完成以上配置后，按下方安装步骤操作。

---

## 触发时机

| 触发方式 | 场景 |
|---|---|
| `RunAtLoad` | 用户登录时 |
| `WatchPaths` | 网络配置变化时（唤醒、切换 Wi-Fi） |
| `StartInterval` 60s | 定期兜底检查 |

## 安装步骤

### 1. 复制文件到对应位置

```bash
cp smb-automount/mount_smb.sh ~/Library/Scripts/
cp smb-automount/com.yourname.mountsmb.plist ~/Library/LaunchAgents/
chmod +x ~/Library/Scripts/mount_smb.sh
```

### 2. 加载 launchd 守护

```bash
launchctl bootout gui/$(id -u)/com.yourname.mountsmb 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yourname.mountsmb.plist
```

### 3. 验证

```bash
# 手动触发一次
launchctl kickstart gui/$(id -u)/com.yourname.mountsmb

# 查看日志
cat ~/Library/Logs/mount_smb.log
```

## 卸载步骤

完全移除本方案的所有文件和服务：

```bash
# 1. 停止并移除 launchd 守护
launchctl bootout gui/$(id -u)/com.yourname.mountsmb 2>/dev/null || true

# 2. 删除所有相关文件
rm ~/Library/LaunchAgents/com.yourname.mountsmb.plist
rm ~/Library/Scripts/mount_smb.sh
rm ~/Library/Logs/mount_smb.log
rm ~/Library/Caches/mount_smb.lastrun

# 3. （可选）删除钥匙串中的 SMB 密码
#     打开「钥匙串访问」App → 搜索 "192.168.0.100" → 右键删除
```

## 管理命令

```bash
# 查看守护状态
launchctl list | grep mountsmb

# 手动触发
launchctl kickstart gui/$(id -u)/com.yourname.mountsmb

# 暂停服务（停止守护并从当前用户的 launchd 中卸载；不会删除配置文件）
launchctl bootout gui/$(id -u)/com.yourname.mountsmb

# 恢复服务（重新加载 launchd 配置）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yourname.mountsmb.plist

# 恢复后立即触发一次挂载（可选）
launchctl kickstart gui/$(id -u)/com.yourname.mountsmb

# 查看日志
tail -f ~/Library/Logs/mount_smb.log

# 清理日志
> ~/Library/Logs/mount_smb.log
```

## 修改共享配置

编辑 `mount_smb.sh`，修改 `SHARES` 数组：

```bash
SHARES=(
    "共享名|/Volumes/挂载点|URL编码名"
    "新共享|/Volumes/新共享|new_share"
)
```

修改后重新加载 launchd 守护。
