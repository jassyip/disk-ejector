import Foundation

// 命令行层验证（不启动 UI，不执行弹出）
// 用法： swiftc -o selftest selftest.swift && ./selftest
// 校验点：
//  1) 正确识别真实外部物理盘（能报出盘名、接口、容量）
//  2) 排除 DMG 磁盘镜像 与 内部盘
//  3) 确认最终 eject 命令目标正确

func plist(_ args: [String]) -> [String: Any]? {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("st-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let q = args.map { "'" + $0 + "'" }.joined(separator: " ")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "/usr/sbin/diskutil \(q) > '\(tmp.path)' 2>/dev/null"]
    try? p.run(); p.waitUntilExit()
    guard let d = FileManager.default.contents(atPath: tmp.path), !d.isEmpty else {
        print("❌ diskutil \(args.joined(separator: " ")) 输出为空（-plist 位置错误）")
        return nil
    }
    return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any]
}

func text(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run()
    let o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return o
}

func sh(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run()
    let o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return o
}
func stripTree(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " \t|+-")) }
func val(_ s: String) -> String { (s.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) }

guard let root = plist(["list", "-plist", "external"]),
      let allDisks = root["AllDisksAndPartitions"] as? [[String: Any]]
else { print("❌ plist 解析失败"); exit(1) }

let wholeIDs = (root["WholeDisks"] as? [String]) ?? []
print("whole disks: \(wholeIDs.sorted())")
print("\n[判定过程]  list-plist 不含类型字段 → 逐个查 info-plist")

var picked: [String] = []
for dev in wholeIDs {
    guard let info = plist(["info", "-plist", "/dev/\(dev)"]) else {
        print("  \(dev)  info 读取失败"); continue
    }
    let virt = info["VirtualOrPhysical"] as? String ?? "?"
    let bus  = info["BusProtocol"] as? String ?? "-"
    let intr = (info["Internal"] as? Bool) ?? false
    let ok = (virt == "Physical" && !intr && bus != "Disk Image")
    print("  \(dev.padding(toLength: 6, withPad: " ", startingAt: 0)) phys=\(virt.padding(toLength: 9, withPad: " ", startingAt: 0)) bus=\(bus.padding(toLength: 11, withPad: " ", startingAt: 0)) internal=\(intr ? "YES " : "NO  ") -> \(ok ? "✅ 选中" : "⛔️ 排除")")
    if ok { picked.append(dev) }
}

print("")
if picked.isEmpty { print("⚠️  当前没有外接硬盘（属正常）"); exit(0) }

print("[选中磁盘详情]")
for dev in picked {
    guard let info = plist(["info", "-plist", "/dev/\(dev)"]) else { continue }
    let node = info["DeviceNode"] as! String
    let size = (info["Size"] as? NSNumber)?.int64Value ?? 0
    let ej   = (info["Ejectable"] as? Bool) ?? false
    print("  \(node)  size=\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))  ejectable=\(ej)")

    var found = false
    for e in allDisks where (e["ParentWholeDisk"] as? String == dev) {
        if let mp = e["MountPoint"] as? String, !mp.isEmpty {
            let vn = e["VolumeName"] as? String ?? (URL(fileURLWithPath: mp).lastPathComponent)
            print("     卷: \(vn)  →  \(mp)")
            found = true
        }
    }
    // APFS：卷在合成盘上，走 app 里的 store→container→volume 兜底路径
    if !found {
        var storeID: String?
        for line in sh(["list", "/dev/\(dev)"]).split(separator: "\n")
        where line.contains("Apple_APFS Container") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let last = parts.last, last.hasPrefix("disk") { storeID = last; break }
        }
        let apfsOut = sh(["apfs", "list"])
        var cid: String?
        if let store = storeID {
            for raw in apfsOut.split(separator: "\n") {
                let t = stripTree(String(raw))
                if t.hasPrefix("APFS Container Reference:") { cid = val(t) }
                else if t.hasPrefix("APFS Physical Store Disk:"), val(t) == store { break }
            }
        }
        if let cid = cid {
            var inT = false
            for raw in apfsOut.split(separator: "\n") {
                let t = stripTree(String(raw))
                if t.hasPrefix("APFS Container Reference:") { inT = (val(t) == cid) }
                else if inT, t.hasPrefix("APFS Volume Disk"), t.contains("(Role)") {
                    if let id = val(t).split(separator: " ").first, id.hasPrefix("disk") {
                        var n = "", m = ""
                        for line in sh(["info", "/dev/\(id)"]).split(separator: "\n") {
                            if line.contains("Volume Name:") { n = val(String(line)) }
                            else if line.contains("Mount Point:") { m = val(String(line)) }
                        }
                        if !n.isEmpty, n != "Not applicable (no file system)" {
                            print("     卷: \(n)  →  \(m.isEmpty ? "(未挂载)" : m)")
                        }
                    }
                }
            }
        }
    }
    print("     ✅ 弹出命令: diskutil eject \(node)")
}