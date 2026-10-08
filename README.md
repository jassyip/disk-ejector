# 弹出硬盘 (Disk Ejector)

macOS 菜单栏外接硬盘弹出工具。一个按键安全弹出所有外接硬盘，全程**不需要指纹验证**。

<img src="https://img.shields.io/badge/macOS-11%2B-000000?style=flat-square" alt="macOS 11+" />
<img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT" />
<img src="https://img.shields.io/badge/Swift-5-F0511F?style=flat-square" alt="Swift" />

## 为什么做这个

macOS 自带的 Finder「推出」偶尔会失败，而网上常见的 Shell 脚本工具又有两个通病：

1. **每次都要指纹验证** —— 用「快捷指令」写的弹出工具必须走 Apple Events 授权，
   重启后系统授权缓存失效，每次运行都要碰一下指纹。
2. **重启后就失灵** —— 脚本往往硬编码了 `disk4`，而重启后磁盘编号会变。

这个工具直接以子进程调用 `diskutil`，**完全不碰 AppleScript，不需要任何授权**，
并且每次实时探测磁盘编号。

## 功能

- **一键弹出所有外接硬盘** —— 一级菜单常驻，一键搞定
- **分盘弹出** —— 菜单里列出每块盘，展开可看详情，单独弹出
- **详细的磁盘信息** —— 设备路径、接口类型、型号、总容量、可用空间、已用百分比、挂载点、加密状态
- **智能区分占用类型** —— 只被系统进程占用时自动处理；被用户程序占用时如实提示，绝不强制卸载
- **自动排除磁盘镜像** —— 不会误弹 DMG 文件
- **菜单栏常驻** —— 不占程序坞，不进「最近使用的应用程序」，双击桌面图标无任何反应

### 菜单示例

```
一键弹出所有外接硬盘
─────────────────────
● MyDrive          ← ● 已挂载 / ○ 已弹出
    设备：/dev/disk4
    接口：USB
    型号：USB3 Portable SSD
    容量：总容量 1 TB　可用 620 GB
    已用：40%
    卷：MyDrive　已挂载于 /Volumes/MyDrive
    ──────────────
    弹出此硬盘
─────────────────────
刷新
退出
```

## 安装与使用

```bash
./build.sh          # 编译并打包成 弹出硬盘.app（自动 ad-hoc 签名）
open 弹出硬盘.app   # 或双击
```

把 `弹出硬盘.app` 拖到「应用程序」文件夹即可。

- **左键或右键**点击菜单栏的硬盘图标 → 弹出菜单（两者行为一致）
- **双击桌面图标** → 无任何反应（预期行为，工具只在菜单栏）

### 加入开机自启

菜单里没有该选项，可手动添加：

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/弹出硬盘.app", hidden:true}'
```

## 工作原理

弹出不是一条 `diskutil eject` 就能成功的。实测（macOS 27.2，APFS 外接盘）：

| 步骤 | 动作 | 说明 |
|---|---|---|
| 1 | `diskutil eject` | 最快路径，多数情况直接成功 |
| 2 | `mdutil -i off` + 重试 | 被 Spotlight 索引时，先让它停止扫描该卷 |
| 3 | 逐卷 `unmount force` → `eject` | 只被系统进程占用时的兜底 |

**安全性**：第 3 步的强制卸载只在阻塞者**全部是系统进程**（Spotlight/Finder 等）时执行。
若占用者包含你自己的程序（编辑器、下载器、数据库），会直接告诉你是谁占用并请你先关闭，
**不做强制卸载**，避免丢失未保存的数据。

### 磁盘识别

判定一块盘是否该出现在菜单里，需要 `diskutil list -plist` 拿到候选，
再逐个用 `diskutil info -plist` 确认类型 —— 因为 `list` 的输出里
`VirtualOrPhysical` 和 `BusProtocol` 字段都是空的，只有 `info` 才给真实值：

- `VirtualOrPhysical == "Physical"` 且 `Internal == false` 且 `BusProtocol != "Disk Image"` → 收录
- 借此排除内部盘与 DMG 镜像

APFS 的卷名不在物理盘上，需要沿链路下钻：
`disk4` → 分区 `disk4s2` → APFS 容器 `disk5` → 卷 `disk5s2`
（注意容器编号与分区编号**不同**，靠 `APFS Physical Store Disk` 字段映射）

## 环境要求

- macOS 11或更高
- 需要 Xcode Command Line Tools（编译用）：`xcode-select --install`

## 常见问题

**Q：点了弹出没反应 / 提示被占用？**
A：菜单会列出具体是哪个程序占用，关掉它再重试。常见的是编辑器、
数据库客户端或刚下载完还没关的浏览器。

**Q：为什么不用 Finder 自带的推出？**
A：Finder 的推出在 Spotlight 索引外接盘时会失败。这个工具针对该场景做了重试与兜底。

**Q：会强制卸载导致丢数据吗？**
A：不会。只有系统进程阻塞时才强制卸载；涉及你自己的程序时只提示不卸载。

## 许可

MIT
