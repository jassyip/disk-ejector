import AppKit
import Foundation
import UserNotifications

// MARK: - 数据模型

struct ExtVolume {
    let name: String
    let mountPoint: String
    let size: Int64
    /// 卷所在容器的剩余空间（字节）。APFS 下多个卷共享同一容器空间，
    /// 取容器剩余量比取卷剩余量更能反映「盘还剩多少」。
    var freeSpace: Int64 = 0
    /// 是否已加密（FileVault）
    var isEncrypted: Bool = false

    var isMounted: Bool { !mountPoint.isEmpty && FileManager.default.fileExists(atPath: mountPoint) }

    /// 空间使用率，如 "84%"
    var usagePercentText: String {
        guard size > 0, freeSpace > 0 else { return "" }
        let used = size - freeSpace
        let pct = Double(used) / Double(size) * 100
        return String(format: "%.0f%%", pct)
    }

    var freeText: String { freeSpace > 0 ? ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file) : "" }
    var totalText: String { size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "" }
}

struct ExtDisk {
    let device: String        // disk4
    let deviceNode: String    // /dev/disk4
    let protocolName: String  // USB / Thunderbolt
    let size: Int64
    let volumes: [ExtVolume]
    let isInternal: Bool
    let ejectable: Bool
    /// 厂商/型号信息（如 Apple External SSD）
    var mediaName: String = ""
    /// 序列号
    var serial: String = ""

    var displayName: String {
        volumes.first?.name ?? mediaName
    }

    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// 剩余空间：优先取卷的容器剩余量
    var freeSpace: Int64 { volumes.first?.freeSpace ?? 0 }

    var freeText: String {
        freeSpace > 0 ? ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file) : ""
    }

    var usagePercentText: String { volumes.first?.usagePercentText ?? "" }

    /// 菜单里显示的接口类型中文名
    var protocolText: String {
        switch protocolName.lowercased() {
        case "usb": return "USB"
        case "thunderbolt": return "雷雳"
        case "nvme": return "NVMe"
        case "disk image": return "磁盘镜像"
        default: return protocolName
        }
    }
}

// MARK: - Shell 执行

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 30) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return (-1, "", "无法启动 \(launchPath)：\(error.localizedDescription)")
        }

        // 防止进程卡死导致 App 永久挂起
        var finished = false
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(40_000)
        }
        if p.isRunning {
            p.terminate()
            usleep(200_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        finished = true
        _ = finished

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        return (p.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    static func diskutil(_ args: [String], timeout: TimeInterval = 30) -> (code: Int32, out: String, err: String) {
        run("/usr/sbin/diskutil", args, timeout: timeout)
    }

    /// 读取 diskutil 的 plist 输出。
    /// 注意：`-plist` 的位置随子命令而变（list 要紧跟 list，info 要在设备参数之前），
    /// 因此这里不自动追加 -plist，由调用方按子命令要求完整传入。
    /// plist 必须落盘再解析：PropertyListSerialization 对不可 seek 的管道会直接失败。
    static func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskinfo-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        _ = run("/bin/sh", ["-c",
            "/usr/sbin/diskutil \(quoted.joined(separator: " ")) > \"\(tmp.path)\" 2>/dev/null"],
            timeout: 30)

        // 必须非空：参数位置错误时 diskutil 会静默输出 0 字节
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
        guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] != nil else {
            FileHandle.standardError.write(Data("plist 解析失败, args=\(args)\n".utf8))
            return nil
        }
        return ((try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any])
    }
}

// MARK: - 磁盘扫描

enum DiskScanner {

    /// 扫描所有「真实外部物理磁盘」，自动排除磁盘镜像(DMG)与内部盘
    static func scanExternal() -> [ExtDisk] {
        guard let root = Shell.diskutilPlist(["list", "-plist", "external"]) else { return [] }
        let allDisks = (root["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
        let wholeIDs = (root["WholeDisks"] as? [String]) ?? []

        var result: [ExtDisk] = []
        // 逐个 whole disk 用 `info -plist` 判定类型。
        // 原因：`diskutil list -plist` 的条目里并不包含 VirtualOrPhysical / BusProtocol
        //（实测均为 null），只有 info 才会给出真实值。
        for dev in wholeIDs {
            guard let info = Shell.diskutilPlist(["info", "-plist", "/dev/\(dev)"]) else { continue }

            // 过滤：只保留真实的外部物理盘
            guard (info["VirtualOrPhysical"] as? String) == "Physical" else { continue }
            guard (info["Internal"] as? Bool) != true else { continue }
            let bus = info["BusProtocol"] as? String ?? "USB"
            guard bus != "Disk Image" else { continue }

            let node = info["DeviceNode"] as? String ?? "/dev/\(dev)"
            let size = (info["Size"] as? NSNumber)?.int64Value ?? 0
            let isInternal = (info["Internal"] as? Bool) ?? false
            let ejectable = (info["Ejectable"] as? Bool) ?? false
            let media = (info["MediaName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let serial = (info["DeviceIdentifier"] as? String) ?? dev

            // 收集该物理盘下的已挂载卷
            var volumes: [ExtVolume] = []
            for e in allDisks {
                guard e["ParentWholeDisk"] as? String == dev else { continue }
                guard let mp = e["MountPoint"] as? String, !mp.isEmpty else { continue }
                let vname = e["VolumeName"] as? String ?? (URL(fileURLWithPath: mp).lastPathComponent)
                let vsize = (e["Size"] as? NSNumber)?.int64Value ?? 0
                volumes.append(ExtVolume(name: vname, mountPoint: mp, size: vsize))
            }
            // APFS 场景：卷挂在合成盘上，list 的 ParentWholeDisk 关联可能缺失，走文本兜底
            if volumes.isEmpty { volumes = fallbackVolumes(whole: dev) }

            // 补齐空间信息（剩余容量 / FileVault），菜单里要显示
            volumes = volumes.map { enrich($0, physicalSize: size) }

            result.append(ExtDisk(device: dev, deviceNode: node, protocolName: bus,
                                  size: size, volumes: volumes,
                                  isInternal: isInternal, ejectable: ejectable,
                                  mediaName: media, serial: serial))
        }
        return result
    }

    /// 补齐卷的剩余空间与加密状态。
    /// 用 df 拿剩余量（简单可靠），并尝试从 diskutil info 读FileVault 状态。
    private static func enrich(_ v: ExtVolume, physicalSize: Int64) -> ExtVolume {
        var out = v
        // 卷自身没拿到大小时，用物理盘容量兜底（APFS 卷共享容器空间）
        if out.size == 0 { out = ExtVolume(name: v.name, mountPoint: v.mountPoint, size: physicalSize) }

        if out.isMounted {
            let r = Shell.run("/bin/df", ["-k", v.mountPoint], timeout: 8)
            let availLine = r.out.split(separator: "\n").last.map(String.init) ?? ""
            let cols = availLine.split(separator: " ").filter { !$0.isEmpty }
            if cols.count >= 4, let availKB = Int64(cols[3]) {
                out.freeSpace = availKB * 1024
            }

            let info = Shell.diskutil(["info", v.mountPoint]).out
            for line in info.split(separator: "\n") {
                if line.contains("FileVault:") {
                    let val = line.split(separator: ":", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    out.isEncrypted = val.hasPrefix("Yes")
                }
            }
        } else {
            // 未挂载：无法查剩余空间，用物理盘容量显示，至少不空白
            if out.size == 0 { out = ExtVolume(name: v.name, mountPoint: v.mountPoint, size: physicalSize) }
        }
        return out
    }

    /// 文本输出兜底解析
    /// APFS 场景下卷名不在物理盘的 list 里，需要沿链路逐级下钻：
    ///   物理盘 disk4 → 分区 disk4s2 → APFS 容器 disk5 → 卷 disk5s2
    /// 用文本输出解析，比依赖 apfs plist 的字段更稳定（实测该 plist 缺少
    /// PhysicalStores / MountPoint 等关键字段）。
    /// `diskutil apfs list` 用 | + - 画树形图，这些字符在trimming 空白后依然残留，
    /// 会导致 hasPrefix 判断失效，必须先剥除。
    private static func stripTree(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t|+-"))
    }

    private static func value(afterColon s: String) -> String {
        (s.split(separator: ":", maxSplits: 1).last ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fallbackVolumes(whole: String) -> [ExtVolume] {
        // 1) 找到该物理盘上的 APFS 分区（形如 disk4s2）
        var storeID: String?
        let listOut = Shell.diskutil(["list", "/dev/\(whole)"]).out
        for line in listOut.split(separator: "\n") where line.contains("Apple_APFS Container") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let last = parts.last, last.hasPrefix("disk") { storeID = last; break }
        }
        guard let store = storeID else { return [] }

        // 2) 通过 `APFS Physical Store Disk` 把分区映射到容器编号。
        //    注意：物理分区是 disk4s2，而容器是合成盘 disk5，两者编号并不相同。
        let apfsOut = Shell.diskutil(["apfs", "list"]).out
        var containerID: String?
        var found = false
        for raw in apfsOut.split(separator: "\n") {
            let t = stripTree(String(raw))
            if t.hasPrefix("APFS Container Reference:") {
                containerID = value(afterColon: t)
            } else if t.hasPrefix("APFS Physical Store Disk:") {
                if value(afterColon: t) == store {
                    found = true
                    break
                }
            }
        }
        guard found, let cid = containerID else { return [] }
        return collectVolumes(ofContainer: cid, from: apfsOut)
    }

    /// 从 `apfs list` 文本中提取指定容器的所有已挂载卷
    private static func collectVolumes(ofContainer cid: String, from apfsOut: String) -> [ExtVolume] {
        var volIDs: [String] = []
        var inTarget = false
        for raw in apfsOut.split(separator: "\n") {
            let t = stripTree(String(raw))
            if t.hasPrefix("APFS Container Reference:") {
                inTarget = (value(afterColon: t) == cid)
            } else if inTarget, t.hasPrefix("APFS Volume Disk"), t.contains("(Role)") {
                // 设备号在冒号之后： "APFS Volume Disk (Role):   disk5s2 (No specific role)"
                if let id = value(afterColon: t).split(separator: " ").first, id.hasPrefix("disk") {
                    volIDs.append(String(id))
                }
            }
        }

        var vols: [ExtVolume] = []
        for vid in volIDs {
            let info = Shell.diskutil(["info", "/dev/\(vid)"]).out
            var name = "", mount = ""
            for line in info.split(separator: "\n") {
                if line.contains("Volume Name:") {
                    name = value(afterColon: String(line))
                } else if line.contains("Mount Point:") {
                    mount = value(afterColon: String(line))
                }
            }
            guard !name.isEmpty, name != "Not applicable (no file system)" else { continue }
            vols.append(ExtVolume(name: name, mountPoint: mount, size: 0))
        }
        return vols
    }
}

// MARK: - 占用检测

enum BusyDetector {
    /// 找出正在占用挂载点的进程（弹出失败时告诉用户该关谁）
    static func holders(for volumes: [ExtVolume]) -> [String] {
        var apps: [String: Int] = [:]
        for v in volumes where FileManager.default.fileExists(atPath: v.mountPoint) {
            let r = Shell.run("/usr/sbin/lsof", ["-Fn", v.mountPoint], timeout: 20)
            for line in r.out.split(separator: "\n") where line.hasPrefix("n") {
                let name = String(line.dropFirst())
                if !name.isEmpty { apps[name, default: 0] += 1 }
            }
        }
        return apps.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// 这些系统进程会短暂占用外接盘，稍后重试通常就能成功，
    /// 不需要用户手动干预，也不该当成"弹出失败"来报告。
    static let transientAgents: Set<String> = [
        "managedcorespotlightd", "mds", "mds_stores", "mdworker", "mdworker_shared",
        "Spotlight", "photolibraryd", "apsd", "bird", "cloudd", "birdcloudd",
        "Finder", "Dock", "identityservicesd", "trustd", "secd", "securityd",
        "diskarbitrationd", "AppleMobileFileIntegrity", "iCloudAgent",
        "com.apple.Spotlight", "corespotlightd", "mdsworker",
        "launchd", "kernel_task", "WindowServer",
    ]

    /// 判定阻塞者是否全部属于可重试的系统进程
    static func isOnlyTransient(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        return names.allSatisfy { n in
            transientAgents.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
        }
    }

    /// 把 diskutil 报错里的 PID + 进程名提取出来，便于判断
    static func dissents(from err: String) -> [(pid: Int, name: String)] {
        var result: [(Int, String)] = []
        // 只匹配 "Unmount was dissented by PID 8898 (.../managedcorespotlightd)"
        // 必须带 "dissented by" 前缀，否则 "Dissenter parent PPID 1 (/sbin/launchd)"
        // 这类父进程说明行会被误当成真正的占用者。
        let re = try? NSRegularExpression(
            pattern: #"dissented by PID\s+(\d+)\s+\(([^)]+)\)"#,
            options: [.caseInsensitive]
        )
        guard let re else { return [] }
        let ns = err as NSString
        for m in re.matches(in: err, range: NSRange(location: 0, length: ns.length)) {
            let pid = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let path = ns.substring(with: m.range(at: 2))
            result.append((pid, (path as NSString).lastPathComponent))
        }
        return result
    }

    /// 温和地让系统索引进程松手：mdutil 关闭该卷的Spotlight 索引
    /// 这是无损操作，不删除任何索引数据，仅停止对该卷的即时扫描。
    static func relaxSpotlight(for volumes: [ExtVolume]) {
        for v in volumes where !v.mountPoint.isEmpty {
            _ = Shell.run("/usr/sbin/mdutil", ["-i", "off", v.mountPoint], timeout: 10)
        }
    }

    /// 找出属于该物理盘的、当前仍挂载的卷设备号。
    /// 必须限定在该盘对应的容器内，否则会误卸载内置盘的卷。
    static func mountedVolumeDevices(for disk: ExtDisk) -> [String] {
        // 先定位该物理盘的 APFS 分区（如 disk4s2）
        var storeID: String?
        for line in Shell.diskutil(["list", "/dev/\(disk.device)"]).out.split(separator: "\n")
        where line.contains("Apple_APFS Container") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let last = parts.last, last.hasPrefix("disk") { storeID = last; break }
        }

        // 非 APFS 盘：直接取该盘下的分区设备
        if storeID == nil {
            var devs: [String] = []
            for line in Shell.diskutil(["list", "/dev/\(disk.device)"]).out.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if let last = parts.last, last.hasPrefix("\(disk.device)s") { devs.append(last) }
            }
            return devs
        }

        // APFS：分区 → 容器 → 卷
        let apfsOut = Shell.diskutil(["apfs", "list"]).out
        var containerID: String?
        for raw in apfsOut.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t|+-"))
            if t.hasPrefix("APFS Container Reference:") {
                containerID = t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("APFS Physical Store Disk:"),
                      t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) == storeID {
                break
            }
        }
        guard let cid = containerID else { return [] }

        var devs: [String] = []
        var inTarget = false
        for raw in apfsOut.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t|+-"))
            if t.hasPrefix("APFS Container Reference:") {
                inTarget = (t.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) == cid)
            } else if inTarget, t.hasPrefix("APFS Volume Disk"), t.contains("(Role)") {
                let id = t.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if id.hasPrefix("disk") { devs.append(id) }
            }
        }
        return devs
    }
}

// MARK: - 弹出执行

enum EjectError: LocalizedError {
    case busy([String])
    case failed(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .busy(let apps):
            if apps.isEmpty { return "磁盘正在被占用，请稍后重试" }
            let list = apps.prefix(5).joined(separator: "、")
            return "磁盘正被以下程序占用：\n\(list)\n\n请关闭它们后重新弹出"
        case .failed(let msg):
            return msg.isEmpty ? "弹出失败" : msg
        case .notFound:
            return "找不到该磁盘（可能已经拔出）"
        }
    }
}

enum Ejector {
    /// 安全弹出：分级处理占用情况
    ///
    /// 实测结论（macOS 27.2/ APFS 外接盘）：`diskutil eject` 常被 Spotlight 的
    /// managedcorespotlightd 拒绝，仅靠等待或 mdutil 关索引并不可靠；
    /// 真正有效的是先逐卷 `unmount force`，再对整盘 eject。
    /// 因此这里的顺序是：温和 eject → 停索引重试 → 强制卸载各卷 → 再 eject。
    static func eject(_ disk: ExtDisk) throws {
        var lastErr = ""

        // 第 1 步：直接尝试弹出（最快路径）
        let first = Shell.diskutil(["eject", disk.deviceNode])
        if first.code == 0 { return }

        let raw = first.err.isEmpty ? first.out : first.err
        lastErr = clean(raw)

        let dissents = BusyDetector.dissents(from: raw).map { $0.name }
        let blockers = dissents.isEmpty ? BusyDetector.holders(for: disk.volumes) : dissents
        let onlyTransient = BusyDetector.isOnlyTransient(blockers)

        // 阻塞者里有你自己的程序（编辑器、下载器、数据库等）→ 直接如实告知，
        // 不做强制卸载，避免丢失未保存数据。
        if !onlyTransient && !blockers.isEmpty {
            throw EjectError.busy(blockers)
        }

        // 第 2 步：让 Spotlight 停止索引该卷，稍候重试
        if onlyTransient {
            BusyDetector.relaxSpotlight(for: disk.volumes)
            usleep(1_500_000)
            let retry = Shell.diskutil(["eject", disk.deviceNode])
            if retry.code == 0 { return }
            lastErr = clean(retry.err.isEmpty ? retry.out : retry.err)
        }

        // 第 3 步：只被系统进程占用时，逐卷强制卸载后再 eject
        let vols = BusyDetector.mountedVolumeDevices(for: disk)
        if !vols.isEmpty {
            for v in vols {
                _ = Shell.diskutil(["unmount", "force", "/dev/\(v)"])
            }
            usleep(800_000)
        }
        let forced = Shell.diskutil(["eject", disk.deviceNode])
        if forced.code == 0 { return }

        let forcedRaw = forced.err.isEmpty ? forced.out : forced.err
        let forcedBlockers = BusyDetector.dissents(from: forcedRaw).map { $0.name }

        // 仍然失败：能识别出具体占用者就报给人看，否则回传原始信息
        if !forcedBlockers.isEmpty && !BusyDetector.isOnlyTransient(forcedBlockers) {
            throw EjectError.busy(forcedBlockers)
        }
        throw EjectError.failed(lastErr.isEmpty ? clean(forcedRaw) : lastErr)
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "diskutil: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let statusTitle = NSStatusItem.variableLength
    private var scanTimer: Timer?

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: statusTitle)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                                          accessibilityDescription: "外接硬盘")

        refreshStatusIcon()

        // 定期刷新：硬盘插拔后菜单栏图标随之更新
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStatusIcon()
        }
        RunLoop.main.add(scanTimer!, forMode: .common)

        // 纯菜单栏工具：双击桌面图标不做任何事，所有交互都在这个图标上。
        // 左右键统一走 NSMenu —— NSStatusItem 挂 menu 后左右键行为一致，
        // 都是弹出同一个菜单；这也避免了「同时挂 menu 和 action 时 action 失效」的问题。
        let m = NSMenu()
        m.delegate = self
        populate(m)
        statusItem.menu = m
    }

    // MARK: 菜单

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // 每次打开都刷新内容，保证盘列表是最新的（插拔后立即可见）。
        // 注意是「原地更新」而不是换一个新NSMenu：menuWillOpen 期间替换
        // statusItem.menu 会把正在显示的菜单顶掉，导致菜单打不开或内容不刷新。
        populate(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// 用当前外接盘情况填充菜单
    private func populate(_ m: NSMenu) {
        m.removeAllItems()
        let disks = DiskScanner.scanExternal()

        // ---- 一键弹出全部（一级菜单常驻，始终可见）----
        let all = NSMenuItem(title: "一键弹出所有外接硬盘",
                             action: #selector(ejectAll), keyEquivalent: "")
        all.target = self
        all.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)
        // 没有盘可弹时置灰，避免点了没反应让人困惑
        all.isEnabled = !disks.isEmpty
        m.addItem(all)

        m.addItem(.separator())

        if disks.isEmpty {
            let none = NSMenuItem(title: "未检测到外接硬盘", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        } else {
            // ---- 分盘：每块盘一个子菜单，展开后是详细信息 + 单独弹出 ----
            for d in disks {
                let parent = NSMenuItem(title: "\(diskGlyph(d))\(d.displayName)",
                                        action: nil, keyEquivalent: "")
                parent.submenu = diskDetailMenu(d)
                m.addItem(parent)
            }
            m.addItem(.separator())
        }

        let r = NSMenuItem(title: "刷新", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        m.addItem(r)
        let q = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
    }

    /// 盘符前的状态标识：已挂载用实心点，未挂载用空心点
    private func diskGlyph(_ d: ExtDisk) -> String {
        d.volumes.contains { $0.isMounted } ? "● " : "○ "
    }

    /// 单块硬盘的详情子菜单：完整信息 + 分盘弹出按钮
    private func diskDetailMenu(_ d: ExtDisk) -> NSMenu {
        let sub = NSMenu()

        // 基本信息
        sub.addItem(infoRow(label: "设备", value: d.deviceNode))
        sub.addItem(infoRow(label: "接口", value: d.protocolText))
        if !d.mediaName.isEmpty && d.mediaName != d.displayName {
            sub.addItem(infoRow(label: "型号", value: d.mediaName))
        }

        // 空间信息
        if !d.totalSizeText.isEmpty {
            var cap = "总容量 \(d.totalSizeText)"
            if !d.freeText.isEmpty { cap += "　可用 \(d.freeText)" }
            sub.addItem(infoRow(label: "容量", value: cap))
        }
        if !d.usagePercentText.isEmpty {
            sub.addItem(infoRow(label: "已用", value: d.usagePercentText))
        }

        // 卷列表（含挂载点、加密状态）
        for v in d.volumes {
            var line = v.name
            if v.isMounted {
                line += "　已挂载于 \(v.mountPoint)"
            } else {
                line += "　未挂载"
            }
            if v.isEncrypted { line += "　🔒 已加密" }
            sub.addItem(infoRow(label: "卷", value: line))
        }

        sub.addItem(.separator())

        // 单独弹出这块盘
        let e = NSMenuItem(title: "弹出此硬盘",
                           action: #selector(ejectDisk(_:)), keyEquivalent: "")
        e.target = self
        e.representedObject = d.deviceNode
        e.image = NSImage(systemSymbolName: "eject", accessibilityDescription: nil)
        sub.addItem(e)

        return sub
    }

    private func infoRow(label: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label)：\(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func refreshStatusIcon() {
        let disks = DiskScanner.scanExternal()
        statusItem.button?.image = NSImage(
            systemSymbolName: disks.isEmpty ? "externaldrive"
                                             : "externaldrive.connected.to.line.below",
            accessibilityDescription: "外接硬盘"
        )
        // 菜单内容跟着一起刷新：弹出后列表要立刻反映最新状态。
        // 菜单正在显示时跳过，避免把用户正在看的菜单抽走（menuWillOpen 会负责刷新）。
        if let m = statusItem.menu, !isMenuOpen {
            populate(m)
        }
    }

    /// 菜单当前是否处于显示状态
    private var isMenuOpen = false

    // MARK: 动作

    @objc private func refresh() {
        refreshStatusIcon()
        flashIcon(systemImage: "arrow.clockwise",
                  restore: "externaldrive.connected.to.line.below")
    }

    @objc private func ejectDisk(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? String else { return }

        guard let disk = DiskScanner.scanExternal().first(where: { $0.deviceNode == node }) else {
            notify("磁盘已不在", "该硬盘可能已经拔出了")
            return
        }

        do {
            try Ejector.eject(disk)
            notify("已安全弹出", "\(disk.displayName) 已断开，可以直接拔出了")
            flashIcon(systemImage: "checkmark.circle.fill", restore: "externaldrive")
        } catch {
            notify("弹出失败", error.localizedDescription)
            flashIcon(systemImage: "exclamationmark.triangle.fill", restore: "externaldrive")
        }
        refreshStatusIcon()
    }

    @objc private func ejectAll() {
        let disks = DiskScanner.scanExternal()
        guard !disks.isEmpty else {
            notify("无可弹出硬盘", "当前没有检测到已插入的外接硬盘")
            refreshStatusIcon()
            return
        }

        var succeeded: [String] = []
        var failed: [(name: String, reason: String)] = []

        for disk in disks {
            do {
                try Ejector.eject(disk)
                succeeded.append(disk.displayName)
            } catch {
                failed.append((disk.displayName, error.localizedDescription))
            }
        }

        // 汇总结果，避免「有的成功有的失败」却统一报成功
        if failed.isEmpty {
            let names = succeeded.joined(separator: "、")
            notify("已全部弹出", "\(names) 已断开，可以直接拔出")
        } else if succeeded.isEmpty {
            let reasons = failed.map { "\($0.name)：\($0.reason)" }
                .joined(separator: "\n")
            notify("全部弹出失败", reasons)
        } else {
            let ok = succeeded.joined(separator: "、")
            let bad = failed.map { "\($0.name)（\($0.reason)）" }.joined(separator: "、")
            notify("部分弹出失败", "已成功：\(ok)\n失败：\(bad)")
        }

        refreshStatusIcon()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 反馈

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        // 未获通知授权时降级为系统横幅，避免失败影响主流程
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = body
                    alert.runModal()
                }
                return
            }
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    /// 临时换图标给出视觉反馈
    private func flashIcon(systemImage: String, restore: String) {
        guard let btn = statusItem.button else { return }
        btn.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            btn.image = NSImage(systemSymbolName: restore,
                               accessibilityDescription: "外接硬盘")
        }
    }
}

// MARK: - 命令行模式（双击 App / 脚本调用时直接弹出）

enum CLIMode {
    /// 返回 true 表示已用命令行模式处理完毕，进程应退出
    static func handleIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--eject-now") else { return false }

        // 命令行模式下也要能弹窗反馈，因此按前台应用激活
        NSApplication.shared.setActivationPolicy(.regular)

        let disks = DiskScanner.scanExternal()
        guard !disks.isEmpty else {
            feedback(ok: false, title: "未检测到外接硬盘",
                     body: "请确认硬盘已插入并已挂载")
            exit(0)
        }

        // 只弹第一块（或指定名称的那块）
        var target = disks[0]
        if let idx = args.firstIndex(of: "--disk"), idx + 1 < args.count {
            let want = args[idx + 1]
            if let m = disks.first(where: {
                $0.deviceNode == want || $0.displayName == want || $0.volumes.contains { $0.name == want }
            }) { target = m }
        }

        do {
            try Ejector.eject(target)
            feedback(ok: true, title: "已安全弹出",
                     body: "\(target.displayName) 已断开，可以直接拔出了")
        } catch {
            feedback(ok: false, title: "弹出失败", body: error.localizedDescription)
            exit(1)
        }
        exit(0)
    }

    /// 弹出后给一个明确的窗口反馈（双击场景下用户需要看到结果）
    private static func feedback(ok: Bool, title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = ok ? .informational : .warning
        alert.addButton(withTitle: "好")
        if ok {
            alert.icon = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        } else {
            alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
        alert.runModal()
    }
}

// MARK: - 入口

// 纯菜单栏工具：双击桌面图标不会打开任何窗口（这是预期行为），
// 所有交互都在菜单栏图标上完成。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// accessory：不在程序坞、也不进「最近使用的应用程序」
app.setActivationPolicy(.accessory)
app.run()