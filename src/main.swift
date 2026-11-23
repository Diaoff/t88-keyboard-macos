// t88ctl — LANGTU T88 键盘 macOS 用户态 HID 工具
//
// 设计依据：键盘通过 HID 厂商接口接收配置报文，macOS 侧只需要 IOKit HID，无需 DriverKit。
//
// 已知边界：厂商的 HID 报表协议是私有的，未被公开文档化。本工具只实现
// 已在本机实测验证过的部分：
//   - 设备发现与接口枚举
//   - 报告描述符读取
//   - Feature Report 原始读/写通道
//   - 输入报文监听
//   - 灯效（04 18 / 04 13 / 64B / 04 02 / 04 F0）
//   - 设备参数块（04 18 / 00 01 / 04 02，字段名与偏移见 docs/protocol.md）
// 宏、DKS、LCD/GIF 等需要文件级二进制编码的功能尚未还原，不做猜测性实现。

import Foundation
import IOKit
import IOKit.hid

// MARK: - 已知设备

struct KnownDevice {
    let vid: Int
    let pid: Int
    let name: String
}

// 设备身份（VID/PID 与设备名，实测核对）
let knownDevices = [
    KnownDevice(vid: 0x0C45, pid: 0x8006, name: "T88-USB  (有线)"),
    KnownDevice(vid: 0x05AC, pid: 0x024F, name: "T88-2.4G (2.4G 接收器)"),
]

// 厂商自定义集合：Usage Page 0xFF60 / Usage 0x61（QMK raw HID 常用段位，实机实测）
let kVendorPage = 0xFF60
let kVendorUsage = 0x61

// MARK: - 参数

struct Options {
    var vid: Int?
    var pid: Int?
    var page: Int?
    var usage: Int?
    var idx = 0
    var includeAll = false
    var save = false      // 灯效写入固件 EEPROM（默认不写，避免磨损/持久化）
    var dryRun = false
}

func parseInt(_ s: String) -> Int? {
    let t = s.lowercased()
    if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
    return Int(t)
}

func parseHex(_ s: String) -> [UInt8]? {
    let h = s.replacingOccurrences(of: " ", with: "")
    guard h.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var idx = h.startIndex
    while idx < h.endIndex {
        let next = h.index(idx, offsetBy: 2)
        guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}

// MARK: - 设备匹配

func matchingDicts(_ o: Options) -> [[String: Any]] {
    var vidPids: [(Int, Int)] = []
    if let v = o.vid, let p = o.pid {
        vidPids = [(v, p)]
    } else if o.includeAll {
        vidPids = []
    } else {
        vidPids = knownDevices.map { ($0.vid, $0.pid) }
    }

    var dicts: [[String: Any]] = []
    if vidPids.isEmpty {
        var d: [String: Any] = [:]
        if let page = o.page { d[kIOHIDPrimaryUsagePageKey as String] = page }
        if let usage = o.usage { d[kIOHIDPrimaryUsageKey as String] = usage }
        dicts.append(d)
    } else {
        for (v, p) in vidPids {
            var d: [String: Any] = [
                kIOHIDVendorIDKey as String: v,
                kIOHIDProductIDKey as String: p,
            ]
            if let page = o.page { d[kIOHIDPrimaryUsagePageKey as String] = page }
            if let usage = o.usage { d[kIOHIDPrimaryUsageKey as String] = usage }
            dicts.append(d)
        }
    }
    return dicts
}

func devices(_ o: Options) -> [IOHIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts(o) as CFArray)
    // 枚举不依赖 manager 打开成功；包含键盘类接口时可能因 TCC 拒绝而返回失败，
    // 但 CopyDevices 仍可正常工作。
    _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    // 按 LocationID + UsagePage 排序，输出稳定
    return set.sorted {
        let l0 = intProp($0, kIOHIDLocationIDKey) ?? 0
        let l1 = intProp($1, kIOHIDLocationIDKey) ?? 0
        if l0 != l1 { return l0 < l1 }
        return (intProp($0, kIOHIDPrimaryUsagePageKey) ?? 0) < (intProp($1, kIOHIDPrimaryUsagePageKey) ?? 0)
    }
}

func intProp(_ dev: IOHIDDevice, _ key: String) -> Int? {
    return IOHIDDeviceGetProperty(dev, key as CFString) as? Int
}

func strProp(_ dev: IOHIDDevice, _ key: String) -> String? {
    return IOHIDDeviceGetProperty(dev, key as CFString) as? String
}

// MARK: - 输出

func printStatus(_ link: VendorLink, _ label: String) {
    guard link.hasFeature, let st = link.lastStatus else { return }
    print("  状态[\(label)]: \(hex(st))")
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func describe(_ dev: IOHIDDevice) {
    let page = intProp(dev, kIOHIDPrimaryUsagePageKey) ?? -1
    let usage = intProp(dev, kIOHIDPrimaryUsageKey) ?? -1
    let vid = intProp(dev, kIOHIDVendorIDKey) ?? -1
    let pid = intProp(dev, kIOHIDProductIDKey) ?? -1
    let inSz = intProp(dev, kIOHIDMaxInputReportSizeKey) ?? -1
    let outSz = intProp(dev, kIOHIDMaxOutputReportSizeKey) ?? -1
    let featSz = intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? -1
    let loc = intProp(dev, kIOHIDLocationIDKey) ?? -1
    let product = strProp(dev, kIOHIDProductKey) ?? "-"
    let manufacturer = strProp(dev, kIOHIDManufacturerKey) ?? "-"
    let transport = strProp(dev, kIOHIDTransportKey) ?? "-"
    let serial = strProp(dev, kIOHIDSerialNumberKey) ?? "-"

    print("  product      : \(product)")
    print("  manufacturer : \(manufacturer)")
    print("  vid/pid      : 0x\(String(format: "%04X", vid))/0x\(String(format: "%04X", pid))")
    print("  transport    : \(transport)   locationID: 0x\(String(format: "%08X", loc))")
    print("  serial       : \(serial)")
    print("  usage        : page 0x\(String(format: "%04X", page)) usage 0x\(String(format: "%02X", usage))\(page == kVendorPage && usage == kVendorUsage ? "   <== 厂商配置接口" : "")")
    print("  report size  : in \(inSz) / out \(outSz) / feature \(featSz)")
}

func vendorDevice(_ o: Options) -> IOHIDDevice? {
    var opt = o
    if opt.page == nil { opt.page = kVendorPage }
    if opt.usage == nil { opt.usage = kVendorUsage }
    var list = devices(opt)
    // 有线模式（T88-USB, 0C45:8006）的配置接口是 Usage Page 0xFF13 / Usage 0x01，
    // 带 64 字节 feature report；2.4G 接收器则是 0xFF60/0x61 的 input/output。
    // 两者同时在线时若不指定 --page，把 0xFF13 一并纳入候选，由下面的排序优先选它。
    if o.page == nil {
        var all = o
        all.page = nil
        all.usage = nil
        list = devices(all).filter {
            (intProp($0, kIOHIDPrimaryUsagePageKey) ?? 0) >= 0xFF00
        }
    }
    // 有线模式(MI_02)的厂商接口未必声明 0xFF60/0x61；找不到时退回同 VID/PID 的
    // 全部厂商页接口（Usage Page >= 0xFF00）或带 feature report 的接口。
    if list.isEmpty && o.page == nil {
        var all = o
        all.page = nil
        all.usage = nil
        list = devices(all).filter {
            (intProp($0, kIOHIDPrimaryUsagePageKey) ?? 0) >= 0xFF00
                || (intProp($0, kIOHIDMaxFeatureReportSizeKey) ?? 0) >= 32
        }
    }
    // 优先有 feature report 的接口（有线通道走 feature 报文），
    // 其次取报文更大的那个（2.4G 的 64B 通道）。可用 --idx 覆盖。
    let sorted = list.sorted {
        let f0 = intProp($0, kIOHIDMaxFeatureReportSizeKey) ?? 0
        let f1 = intProp($1, kIOHIDMaxFeatureReportSizeKey) ?? 0
        if (f0 > 0) != (f1 > 0) { return f0 > 0 }
        return (intProp($0, kIOHIDMaxInputReportSizeKey) ?? 0) > (intProp($1, kIOHIDMaxInputReportSizeKey) ?? 0)
    }
    guard !sorted.isEmpty else { return nil }
    return sorted[min(max(o.idx, 0), sorted.count - 1)]
}

func open(_ dev: IOHIDDevice) -> Bool {
    let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    if r == kIOReturnSuccess { return true }
    let code = UInt32(bitPattern: r)
    if r == kIOReturnExclusiveAccess {
        FileHandle.standardError.write("设备已被其他进程独占打开。\n".data(using: .utf8)!)
    } else if code == 0xE00002E2 || code == 0xE00002C1 {
        FileHandle.standardError.write("打开设备被系统拒绝 (0x\(String(r, radix: 16)))。\n".data(using: .utf8)!)
        FileHandle.standardError.write("请在“系统设置 → 隐私与安全性 → 输入监控”中允许当前终端应用。\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("IOHIDDeviceOpen 失败: 0x\(String(r, radix: 16))\n".data(using: .utf8)!)
    }
    return false
}

// MARK: - 命令

func cmdList(_ o: Options) {
    let list = devices(o)
    if list.isEmpty {
        print("未发现匹配的 HID 设备。请确认键盘已连接（有线或 2.4G 接收器）。")
        return
    }
    print("发现 \(list.count) 个 HID 接口：")
    for (i, d) in list.enumerated() {
        print("[\(i)]")
        describe(d)
    }
}

func cmdDescriptor(_ o: Options) {
    guard let dev = vendorDevice(o) else {
        print("未找到厂商配置接口 (Usage Page 0xFF60 / Usage 0x61)。")
        return
    }
    guard let data = IOHIDDeviceGetProperty(dev, kIOHIDReportDescriptorKey as CFString) as? Data else {
        print("该设备未暴露报告描述符。")
        return
    }
    print("report descriptor, \(data.count) bytes:")
    print(hex([UInt8](data)))
}

func cmdGet(_ o: Options, id: Int, sizeOverride: Int?) {
    guard let dev = vendorDevice(o), open(dev) else {
        print("未找到或无法打开厂商配置接口。")
        return
    }
    let maxFeat = intProp(dev, kIOHIDMaxFeatureReportSizeKey) ?? 0
    let len = sizeOverride ?? (maxFeat > 0 ? maxFeat : 64)
    var buf = [UInt8](repeating: 0, count: len)
    var length = CFIndex(len)
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &length)
    if r != kIOReturnSuccess {
        print("GetReport(id=\(id)) 失败: 0x\(String(r, radix: 16))")
        return
    }
    print("feature report id=\(id), \(length) bytes:")
    print(hex(Array(buf[0..<Int(length)])))
}

func cmdSet(_ o: Options, id: Int, bytes: [UInt8]) {
    guard let dev = vendorDevice(o), open(dev) else {
        print("未找到或无法打开厂商配置接口。")
        return
    }
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), bytes, CFIndex(bytes.count))
    if r != kIOReturnSuccess {
        print("SetReport(id=\(id)) 失败: 0x\(String(r, radix: 16))")
        return
    }
    print("已发送 feature report id=\(id): \(hex(bytes))")
}

// 只读探测：对若干 report id 依次发起 GetReport，用于确认哪些 id 有响应。
// 这是采集证据，不代表任何协议语义。
func cmdProbe(_ o: Options, maxID: Int, len: Int) {
    guard let dev = vendorDevice(o), open(dev) else {
        print("未找到或无法打开厂商配置接口。")
        return
    }
    print("对 report id 1...\(maxID) 发起只读 GetReport（长度 \(len)）：")
    for id in 1...maxID {
        var buf = [UInt8](repeating: 0, count: len)
        var length = CFIndex(len)
        let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &length)
        if r == kIOReturnSuccess {
            let nonzero = buf.contains { $0 != 0 }
            print("  id=\(id) OK  \(hex(buf))\(nonzero ? "" : "  (全零)")")
        } else {
            print("  id=\(id) 0x\(String(r, radix: 16))")
        }
    }
}

// 通过中断 OUT 端点发送一帧原始报文（该键盘厂商接口只有 input/output report，
// 描述符中没有 feature report，因此不能用 SetFeature）。
func cmdSend(_ o: Options, bytes: [UInt8]) {
    guard let dev = vendorDevice(o), open(dev) else {
        print("未找到或无法打开厂商配置接口。")
        return
    }
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, bytes, CFIndex(bytes.count))
    if r != kIOReturnSuccess {
        print("SetReport(output) 失败: 0x\(String(r, radix: 16))")
        return
    }
    print("已发送 output report (\(bytes.count) 字节): \(hex(bytes))")
}

final class MonitorBox {
    var count = 0
}

func cmdMonitor(_ o: Options) {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var opt = o
    if opt.page == nil { opt.page = kVendorPage }
    IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts(opt) as CFArray)
    let box = MonitorBox()
    let ctx = Unmanaged.passUnretained(box).toOpaque()
    IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, reportID, report, length in
        guard let ctx = ctx else { return }
        let b = Unmanaged<MonitorBox>.fromOpaque(ctx).takeUnretainedValue()
        b.count += 1
        let bytes = [UInt8](UnsafeBufferPointer(start: report, count: Int(length)))
        print("[\(b.count)] reportID=\(reportID) len=\(length): \(hex(bytes))")
    }, ctx)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        print("打开失败: 0x\(String(r, radix: 16))（读取输入报文可能需要“输入监控”权限）")
        return
    }
    print("监听中，Ctrl+C 退出。")
    CFRunLoopRun()
}

// MARK: - 灯效协议
//
// 命令格式参考 iiaiiappa/lt104-keyboard-linux（同为 SONiX 方案，
// 并有 USBPcap 抓包与 Langtu LT104 实机验证），随后在本机 T88 2.4G 上验证传输层：
//   - 首包 [0x04,0x18] 握手，[0x04,0x13] byte8=0x01 进入灯效配置
//   - 64 字节配置包：mode,r,g,b, …, byte8=colortype, byte9=亮度, byte10=速度,
//     byte11=方向, byte14=0xAA, byte15=0x55
//   - [0x04,0x02] 应用；[0x04,0xF0] 写 EEPROM（可选，默认不写）
// T88 的 0xFF60 接口没有 feature report，只能走中断 OUT；LT104 则用 feature report。
// 两条通道的命令字节相同，因此同一套报文可复用。

// 灯效表与载荷构造已移到 src/T88Protocol.swift（CLI 与 GUI 共用）
let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/t88ctl")
let stateURL = stateDir.appendingPathComponent("light.json")
let backupURL = stateDir.appendingPathComponent("light.orig.json")

func loadState(_ url: URL) -> LightState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(LightState.self, from: data)
}

func saveState(_ s: LightState, to url: URL) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(s) { try? data.write(to: url) }
}

func loadJSON<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func saveJSON<T: Encodable>(_ value: T, to url: URL) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(value) { try? data.write(to: url) }
}

/// 一帧 64 字节的厂商报文通道。有 feature report 的设备走 SET/GET_REPORT(feature)，
/// 否则走中断 OUT + 输入报文中继（T88 2.4G 的实际情况）。
final class VendorLink {
    private let dev: IOHIDDevice
    private let featureSize: Int
    /// 最近一次 feature 回读的内容（有线模式下设备会把收到的帧连同状态回显）
    private(set) var lastStatus: [UInt8]?
    var hasFeature: Bool { featureSize > 0 }
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let runLoop = CFRunLoopGetCurrent()!
    private var acks = 0
    private var opened = false
    /// 最近收到的输入报文（用于只读查询，验证设备是否真的回了数据）
    private(set) var lastFrames: [[UInt8]] = []

    init?(_ o: Options) {
        guard let d = vendorDevice(o) else { return nil }
        dev = d
        featureSize = intProp(d, kIOHIDMaxFeatureReportSizeKey) ?? 0
        guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            buf.deallocate()
            FileHandle.standardError.write("无法打开厂商接口（可能需要在“隐私与安全性 → 输入监控”中授权）。\n".data(using: .utf8)!)
            return nil
        }
        opened = true
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            let link = Unmanaged<VendorLink>.fromOpaque(ctx).takeUnretainedValue()
            link.acks += 1
            let bytes = [UInt8](UnsafeBufferPointer(start: report, count: Int(length)))
            link.lastFrames.append(bytes)
            if link.lastFrames.count > 16 { link.lastFrames.removeFirst() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(d, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if opened {
            IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(dev, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        buf.deallocate()
    }

    var channel: String { featureSize > 0 ? "feature report" : "中断 OUT" }

    func send(_ bytes: [UInt8]) -> Bool {
        var pkt = [UInt8](repeating: 0, count: 64)
        for (i, v) in bytes.prefix(64).enumerated() { pkt[i] = v }
        let type: IOHIDReportType = featureSize > 0 ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        let ok = IOHIDDeviceSetReport(dev, type, 0, pkt, 64) == kIOReturnSuccess
        lastStatus = featureSize > 0 ? pollFeature() : nil
        return ok
    }

    private func pollFeature() -> [UInt8]? {
        var pkt = [UInt8](repeating: 0, count: 64)
        var len = CFIndex(64)
        let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &pkt, &len)
        return r == kIOReturnSuccess ? Array(pkt[0..<Int(len)]) : nil
    }

    /// 等待任意一帧输入报文（用于无 ACK 语义的数据包之后确认中继链路仍然通畅）。
    func waitForAnyFrame(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while acks == 0 {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return false }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(left, 0.01), true)
        }
        acks = 0
        return true
    }

    /// 清空已缓存的输入报文。
    func clearFrames() {
        lastFrames.removeAll()
        acks = 0
    }

    /// 在 timeout 内收集到的全部输入报文。
    func collectFrames(_ timeout: TimeInterval) -> [[UInt8]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
        }
        let frames = lastFrames
        lastFrames.removeAll()
        acks = 0
        return frames
    }

    /// 发送一条命令并等待回帧。feature 通道要求回帧前两字节等于命令码；
    /// 中断通道的 2.4G 中继只回固定的 0F 01 01 11 确认帧，因此任一输入帧即视为 ACK。
    func command(_ b0: UInt8, _ b1: UInt8, extra: [Int: UInt8] = [:]) -> Bool {
        var pkt = [UInt8](repeating: 0, count: 64)
        pkt[0] = b0
        pkt[1] = b1
        for (k, v) in extra { pkt[k] = v }
        for _ in 0..<8 {
            acks = 0
            guard send(pkt) else { return false }
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline {
                if featureSize > 0 {
                    if let r = pollFeature(), r.count >= 2, r[0] == b0, r[1] == b1 { return true }
                } else if acks > 0 {
                    acks = 0
                    return true
                }
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.005, true)
            }
        }
        return false
    }
}

func parseColor(_ s: String) -> (Int, Int, Int)? {
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
}

func cmdLight(_ o: Options, _ args: [String]) {
    let previous = loadState(stateURL) ?? LightState()
    var s = previous
    let sub = args.first ?? "state"
    var changed = false

    func needValue() -> Int? {
        guard args.count > 1, let v = parseInt(args[1]) else {
            print("缺少参数。用法见 t88ctl light 帮助。")
            return nil
        }
        return v
    }

    switch sub {
    case "state":
        print("工具记录状态: \(s.summary)")
        print("说明: 键盘固件没有“读回当前灯效”的命令，这里显示 t88ctl 上次写入的值（首次运行使用 config.xml 默认值）。")
        return
    case "modes":
        for (id, name) in kLightModes { print(String(format: "%2d  ", id) + name) }
        return
    case "mode":
        guard let v = needValue() else { return }
        if v == 0 { s.mode = 20 } else if (1...20).contains(v) { s.mode = v } else { print("模式范围 1...20（0 等同 20 关闭背光）"); return }
        changed = true
    case "color":
        guard args.count > 1, let c = parseColor(args[1]) else { print("颜色格式: RRGGBB 或 #RRGGBB"); return }
        s.r = c.0; s.g = c.1; s.b = c.2
        changed = true
    case "brightness":
        guard let v = needValue() else { return }
        guard (0...5).contains(v) else { print("亮度范围 0...5（0 = 关闭背光）"); return }
        if v == 0 { s.mode = 20 } else { s.brightness = v }
        changed = true
    case "speed":
        guard let v = needValue() else { return }
        guard (1...5).contains(v) else { print("速度范围 1...5"); return }
        s.speed = v
        changed = true
    case "direction":
        guard let v = needValue() else { return }
        guard (0...3).contains(v) else { print("方向范围 0...3"); return }
        s.direction = v
        changed = true
    case "restore":
        guard let orig = loadState(backupURL) else {
            print("没有可恢复的备份（\(backupURL.path) 不存在）。可用 light mode 11 手动恢复出厂灯效。")
            return
        }
        s = orig
        changed = true
    case "set":
        // 一次写入多个字段：light set --mode 7 --color FF8000 --brightness 4 --speed 3
        var k = 1
        while k < args.count {
            let flag = args[k]
            guard k + 1 < args.count else { print("\(flag) 缺少值"); return }
            let val = args[k + 1]
            switch flag {
            case "--mode":
                if let v = parseInt(val), (0...20).contains(v) { s.mode = v == 0 ? 20 : v } else { print("模式范围 1...20"); return }
            case "--color":
                guard let c = parseColor(val) else { print("颜色格式: RRGGBB"); return }
                s.r = c.0; s.g = c.1; s.b = c.2
            case "--brightness":
                guard let v = parseInt(val), (0...5).contains(v) else { print("亮度范围 0...5"); return }
                if v == 0 { s.mode = 20 } else { s.brightness = v }
            case "--speed":
                guard let v = parseInt(val), (1...5).contains(v) else { print("速度范围 1...5"); return }
                s.speed = v
            case "--direction":
                guard let v = parseInt(val), (0...3).contains(v) else { print("方向范围 0...3"); return }
                s.direction = v
            default:
                print("未知选项: \(flag)")
                return
            }
            k += 2
        }
        changed = true
    default:
        print("未知子命令: \(sub)")
        return
    }
    guard changed else { return }

    guard let link = VendorLink(o) else {
        print("未找到厂商配置接口 (Usage Page 0xFF60 / Usage 0x61)。")
        return
    }

    let payload = lightPayload(s)

    print("通道: \(link.channel)")
    print("写入: \(s.summary)")
    print("报文: 04 18 / 04 13 … / \(hex(payload)) / 04 02\(o.save ? " / 04 F0（写入 EEPROM）" : "")")

    if o.dryRun {
        print("--dry-run：未发送。")
        return
    }

    // 首次写入前记录一份“原状态”，用于 light restore
    if loadState(backupURL) == nil {
        saveState(previous, to: backupURL)
        print("已保存原状态备份到 \(backupURL.path)，可用 `t88ctl light restore` 恢复。")
    }

    guard link.command(0x04, 0x18) else { print("握手失败（设备无响应）。"); return }
    guard link.command(0x04, 0x13, extra: [8: 0x01]) else { print("进入灯效配置失败。"); return }
    _ = link.send(payload)
    printStatus(link, "载荷")
    _ = link.waitForAnyFrame(0.2)
    usleep(20_000)
    guard link.command(0x04, 0x02) else { print("应用灯效失败。"); return }
    if o.save {
        _ = link.command(0x04, 0xF0)
        print("已写入 EEPROM（掉电保留）。")
    }
    saveState(s, to: stateURL)
    print("已发送。")
}

// 设备参数块结构与组包已移到 src/T88Protocol.swift
let settingsURL = stateDir.appendingPathComponent("settings.json")

func cmdSettings(_ o: Options, _ args: [String]) {
    let sub = args.first ?? "show"
    var s = loadJSON(settingsURL, as: DeviceSettings.self) ?? DeviceSettings()

    switch sub {
    case "show":
        print("工具记录参数: \(s.summary)")
        print("报文: \(hex(s.packet))")
        print("说明: 2.4G 接收器不回读，固件当前值无法读取；这里显示 t88ctl 上次写入/默认的值。")
        return
    case "read":
        guard let link = VendorLink(o) else { print("未找到厂商配置接口。"); return }
        print("通道: \(link.channel)")
        guard link.command(0x04, 0x18) else { print("握手失败（设备无响应）。"); return }
        link.clearFrames()
        var q = [UInt8](repeating: 0, count: 64)
        q[0] = 0x04; q[1] = 0x17; q[2] = 1; q[8] = 1
        _ = link.send(q)
        let frames = link.collectFrames(1.0)
        if frames.isEmpty {
            print("未收到任何回帧。")
        } else {
            print("收到 \(frames.count) 帧：")
            for f in frames { print("  \(hex(f))") }
            print("若所有帧都是 0F 01 01 11…（固定确认帧），说明该通道不回读数据（2.4G 接收器实测如此）。")
        }
        return
    case "set":
        var k = 1
        while k < args.count {
            let flag = args[k]
            guard k + 1 < args.count else { print("\(flag) 缺少值"); return }
            guard let v = parseInt(args[k + 1]) else { print("\(flag) 的值不是整数"); return }
            switch flag {
            case "--fn-switch": s.fnSwitch = v
            case "--sleep": s.sleepTime = v
            case "--respond": s.respondTime = v
            case "--tick": s.tickRate = v
            case "--tachyon": s.tachyonMode = v
            case "--continuous-rt": s.continuousRT = v
            case "--sel-a", "--check-a": s.checkA = v
            case "--sel-b", "--check-b": s.checkB = v
            case "--sel-c", "--check-c": s.checkC = v
            default:
                print("未知选项: \(flag)")
                return
            }
            k += 2
        }
    default:
        print("未知子命令: \(sub)")
        return
    }

    let p = s.packet
    print("将写入参数: \(s.summary)")
    print("报文: \(hex(p))")
    if o.dryRun {
        print("--dry-run：未发送。")
        return
    }
    guard let link = VendorLink(o) else { print("未找到厂商配置接口。"); return }
    print("通道: \(link.channel)")
    guard link.command(0x04, 0x18) else { print("握手失败（设备无响应）。"); return }
    _ = link.send(p)
    printStatus(link, "参数块")
    _ = link.waitForAnyFrame(0.2)
    usleep(20_000)
    guard link.command(0x04, 0x02) else { print("应用参数失败。"); return }
    if o.save {
        _ = link.command(0x04, 0xF0)
        print("已写入 EEPROM（掉电保留）。")
    }
    saveJSON(s, to: settingsURL)
    print("已发送。")
}

// MARK: - 逐键灯效（04 23 / 04 20 / 04 F5）
//
// 布局见 docs/protocol.md §3.3：
//   - 04 20 只应用（不落盘）
//   - 04 23 → 数据块 → 04 02 → 04 F0（写 EEPROM）
//   - 04 F5 回读，把数据块每条 4 字节的 {idx,R,G,B} 写回键表
// 头部帧 [8] 选择布局：8 = 128 键布局（512 B 数据块），9 = 144 键布局（576 B），
// 3 = 单色模式（192 B，每键 1 字节，本工具不发）。数据块按 4 字节一条：
// {键索引, R, G, B}；未指定的键保持 0（熄灭）。
// 数据块分帧：以 64 字节一帧顺序下发，无帧序号【推断】。
func cmdKeys(_ o: Options, _ args: [String]) {
    let sub = args.first ?? "help"
    switch sub {
    case "set":
        var color = (255, 255, 255)
        var indexes: [Int] = []
        var layout = 128
        var persist = false
        var k = 1
        while k < args.count {
            switch args[k] {
            case "--color":
                guard k + 1 < args.count, let c = parseColor(args[k + 1]) else { print("颜色格式: RRGGBB"); return }
                color = c
                k += 2
            case "--keys":
                guard k + 1 < args.count else { print("--keys 缺少值"); return }
                for part in args[k + 1].split(separator: ",") {
                    let seg = part.split(separator: "-")
                    if seg.count == 2, let a = Int(seg[0]), let b = Int(seg[1]), a <= b {
                        indexes.append(contentsOf: a...b)
                    } else if let a = Int(seg[0]) {
                        indexes.append(a)
                    } else {
                        print("键索引格式: 0,3,5-10"); return
                    }
                }
                k += 2
            case "--all":
                indexes = Array(0..<88)
                k += 1
            case "--layout":
                guard k + 1 < args.count, let v = parseInt(args[k + 1]), v == 128 || v == 144 else { print("--layout 只能是 128 或 144"); return }
                layout = v
                k += 2
            case "--persist":
                persist = true
                k += 1
            default:
                print("未知选项: \(args[k])")
                return
            }
        }
        if o.includeAll && indexes.isEmpty { indexes = Array(0..<88) }
        guard !indexes.isEmpty else { print("需要 --keys 0,3,5-10 或 --all"); return }

        let blockLen = layout == 128 ? 512 : 576
        var block = [UInt8](repeating: 0, count: blockLen)
        for idx in indexes where idx >= 0 && idx < blockLen / 4 {
            block[idx * 4] = UInt8(idx & 0xFF)
            block[idx * 4 + 1] = UInt8(color.0)
            block[idx * 4 + 2] = UInt8(color.1)
            block[idx * 4 + 3] = UInt8(color.2)
        }
        let layoutCode: UInt8 = layout == 128 ? 8 : 9
        let cmdName = persist ? "04 23" : "04 20"
        print("逐键灯效: \(indexes.count) 个键 → #\(String(format: "%02X%02X%02X", color.0, color.1, color.2))  布局 \(layout) 键 / 数据块 \(blockLen) B")
        print("报文: 04 18 → \(cmdName) ([8]=\(layoutCode)) → \(blockLen / 64) 帧数据 → 04 02\(persist ? " → 04 F0" : "")")
        if o.dryRun {
            print("--dry-run：未发送。")
            return
        }
        guard let link = VendorLink(o) else { print("未找到厂商配置接口。"); return }
        print("通道: \(link.channel)")
        guard link.command(0x04, 0x18) else { print("握手失败（设备无响应）。"); return }
        guard link.command(persist ? 0x04 : 0x04, persist ? 0x23 : 0x20, extra: [8: layoutCode]) else {
            print("进入逐键灯效配置失败。")
            return
        }
        for off in stride(from: 0, to: blockLen, by: 64) {
            _ = link.send(Array(block[off..<min(off + 64, blockLen)]))
        }
        printStatus(link, "数据块末帧")
        _ = link.waitForAnyFrame(0.2)
        usleep(20_000)
        guard link.command(0x04, 0x02) else { print("应用逐键灯效失败。"); return }
        if persist {
            _ = link.command(0x04, 0xF0)
            print("已写入 EEPROM（掉电保留）。")
        }
        print("已发送。")
    case "read":
        guard let link = VendorLink(o) else { print("未找到厂商配置接口。"); return }
        print("通道: \(link.channel)")
        guard link.command(0x04, 0x18) else { print("握手失败（设备无响应）。"); return }
        link.clearFrames()
        var q = [UInt8](repeating: 0, count: 64)
        q[0] = 0x04; q[1] = 0xF5; q[8] = 9
        _ = link.send(q)
        let frames = link.collectFrames(1.0)
        if frames.isEmpty { print("未收到任何回帧。"); return }
        print("收到 \(frames.count) 帧：")
        for f in frames { print("  \(hex(f))") }
        if frames.allSatisfy({ $0[0] == 0x0F }) {
            print("全是固定确认帧：该通道不回读逐键数据（2.4G 接收器实测如此）。")
        }
    default:
        print("用法: t88ctl keys set --color FF0000 --keys 0,3,5-10 | --all [--layout 128|144] [--persist]")
        print("      t88ctl keys read")
    }
}

// MARK: - 入口

func usage() {
    print("""
    t88ctl — LANGTU T88 键盘用户态 HID 工具

    用法:
      t88ctl list [--all]            列出已知 T88 设备的全部 HID 接口
      t88ctl descriptor              打印厂商配置接口的报告描述符
      t88ctl get <reportID> [len]    读取 Feature Report（本机实测厂商接口无 feature report）
      t88ctl set <reportID> <hex..>  写入 Feature Report
      t88ctl send <hex..>            通过中断 OUT 发送一帧原始 output report
      t88ctl probe [maxID] [len]     依次只读探测 report id（默认 8 / 64）
      t88ctl monitor                 监听输入报文

    灯光（取值域按键盘固件）:
      t88ctl light state             显示工具记录的上次灯效（固件无读回命令）
      t88ctl light modes             列出 1...20 灯效模式
      t88ctl light mode <0-20>       切换模式（0/20 = 关闭背光）
      t88ctl light color <RRGGBB>    设置自定义颜色（仅模式 1/2/3/4/5/7 生效）
      t88ctl light brightness <0-5>  亮度（0 = 关闭背光）
      t88ctl light speed <1-5>       动画速度
      t88ctl light direction <0-3>   方向
      t88ctl light set --mode 7 --color FF8000 --brightness 4 --speed 3
      t88ctl light restore           恢复首次写入前记录的原状态

    设备参数块（00 01，字段含义见 docs/protocol.md §3.2）:
      t88ctl settings show           显示工具记录的参数与将要发送的报文
      t88ctl settings read           尝试读回参数（2.4G 接收器只回固定 ACK，读不到）
      t88ctl settings set --fn-switch 1 --sleep 0 --respond 1 --tick 1 --tachyon 1 --continuous-rt 1
      t88ctl settings set --check-a 1 --check-b 1 --check-c 1   [2][3][4] 三个复选框开关
                                      默认 04 18 → 00 01 参数块 → 04 02 应用

    逐键灯效（04 23 / 04 20 / 04 F5）:
      t88ctl keys set --color FF0000 --keys 0,3,5-10 [--layout 128|144]
      t88ctl keys set --color 00FF00 --all --persist   04 23 写入并写 EEPROM（掉电保留）
      t88ctl keys read               尝试回读逐键颜色（2.4G 接收器只回固定 ACK）

    通用选项:
      --vid 0xXXXX --pid 0xXXXX      指定 VID/PID
      --page 0xXXXX --usage 0xXX     指定 Usage Page/Usage 过滤
      --idx N                        多厂商接口时选择第 N 个（0 = 报文最大者）
      --save                         把灯效写入固件 EEPROM（默认只应用、不落盘）
      --dry-run                      只打印报文，不发送
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IONBF, 0)   // monitor 场景下保证逐行即时输出
guard let cmd = args.first else { usage(); exit(1) }

var opt = Options()
var positional: [String] = []
var i = 1
while i < args.count {
    switch args[i] {
    case "--all": opt.includeAll = true
    case "--vid":
        i += 1; if i < args.count { opt.vid = parseInt(args[i]) }
    case "--pid":
        i += 1; if i < args.count { opt.pid = parseInt(args[i]) }
    case "--page":
        i += 1; if i < args.count { opt.page = parseInt(args[i]) }
    case "--usage":
        i += 1; if i < args.count { opt.usage = parseInt(args[i]) }
    case "--idx":
        i += 1; if i < args.count { opt.idx = parseInt(args[i]) ?? 0 }
    case "--save": opt.save = true
    case "--dry-run": opt.dryRun = true
    default: positional.append(args[i])
    }
    i += 1
}

switch cmd {
case "list":
    cmdList(opt)
case "descriptor":
    cmdDescriptor(opt)
case "get":
    guard let id = positional.first.flatMap(parseInt) else { usage(); exit(1) }
    cmdGet(opt, id: id, sizeOverride: positional.count > 1 ? parseInt(positional[1]) : nil)
case "set":
    guard let id = positional.first.flatMap(parseInt), positional.count > 1,
          let bytes = parseHex(positional.dropFirst().joined()) else { usage(); exit(1) }
    cmdSet(opt, id: id, bytes: bytes)
case "send":
    guard positional.count > 0, let bytes = parseHex(positional.joined()) else { usage(); exit(1) }
    cmdSend(opt, bytes: bytes)
case "probe":
    let maxID = positional.first.flatMap(parseInt) ?? 8
    let len = positional.count > 1 ? (parseInt(positional[1]) ?? 64) : 64
    cmdProbe(opt, maxID: maxID, len: len)
case "monitor":
    cmdMonitor(opt)
case "light":
    cmdLight(opt, positional)
case "settings":
    cmdSettings(opt, positional)
case "keys":
    cmdKeys(opt, positional)
default:
    usage(); exit(1)
}
