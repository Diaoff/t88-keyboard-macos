// T88 键盘 macOS 控制面板（AppKit，纯代码 UI，无 Xcode 工程）
//
// 与 t88ctl 共用同一套协议：
//   灯效  04 18 → 04 13 [8]=1 → 64B 载荷 → 04 02 (→ 04 F0)
//   参数  04 18 → 00 01 参数块 → 04 02 (→ 04 F0)
//   逐键  04 18 → 04 20/04 23 [8]=8/9 → 数据块分帧 → 04 02 (→ 04 F0)
// 2.4G 接收器对任何命令只回同一帧 0F 01 01 11，因此界面里的“已发送”只代表
// 报文送达，是否生效以键盘实际表现为准（详见 docs/protocol.md）。

import AppKit
import IOKit
import IOKit.hid

// 灯效/参数/逐键的常量与组包来自 src/T88Protocol.swift（与 CLI 共用）
let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/t88ctl")
let guiStateURL = stateDir.appendingPathComponent("gui.json")
let cliLightURL = stateDir.appendingPathComponent("light.json")
let cliBackupURL = stateDir.appendingPathComponent("light.orig.json")

func hexLine(_ bytes: [UInt8], limit: Int = 64) -> String {
    bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
}

// MARK: - HID 通道

final class T88Link {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuf: UnsafeMutablePointer<UInt8>?
    private(set) var channel = "未连接"
    private var featureSize = 0
    var usesFeature: Bool { featureSize > 0 }
    private(set) var lastStatus: [UInt8]?
    private var acks = 0
    private var frames: [[UInt8]] = []

    deinit { close() }

    var isOpen: Bool { device != nil }

    func open() -> String {
        close()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // 有线 T88-USB 的配置接口是 0xFF13/0x01（64B feature），2.4G 接收器是 0xFF60/0x61
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0xFF13, kIOHIDDeviceUsageKey: 0x01],
            [kIOHIDDeviceUsagePageKey: 0xFF60, kIOHIDDeviceUsageKey: 0x61],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            return "未找到厂商接口（Usage Page 0xFF60 / Usage 0x61）"
        }

        // 优先带 feature report 的接口（有线模式，Windows 驱动也走 HidD_SetFeature），
        // 其次是报文更大的那个（2.4G 的 64B 通道）
        let sorted = set.sorted { a, b in
            let fa = (IOHIDDeviceGetProperty(a, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
            let fb = (IOHIDDeviceGetProperty(b, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
            if (fa > 0) != (fb > 0) { return fa > 0 }
            let sa = (IOHIDDeviceGetProperty(a, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 0
            let sb = (IOHIDDeviceGetProperty(b, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 0
            return sa > sb
        }
        guard let dev = sorted.first else { return "未找到厂商接口" }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return "打开厂商接口失败（可能需要在“隐私与安全性 → 输入监控”里授权）"
        }
        device = dev

        let outSize = (IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 64
        let inSize = (IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        featureSize = (IOHIDDeviceGetProperty(dev, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
        channel = featureSize > 0
            ? "feature report \(featureSize)B（可回读状态）"
            : "中断 OUT    out \(outSize)B / in \(inSize)B"

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        inputBuf = buf
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            let link = Unmanaged<T88Link>.fromOpaque(ctx).takeUnretainedValue()
            link.acks += 1
            let bytes = [UInt8](UnsafeBufferPointer(start: report, count: Int(length)))
            link.frames.append(bytes)
            if link.frames.count > 32 { link.frames.removeFirst() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return "已连接：VID \(hexVID(dev))  \(channel)"
    }

    private func hexVID(_ dev: IOHIDDevice) -> String {
        let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        return String(format: "%04X:%04X", vid, pid)
    }

    func close() {
        if let dev = device {
            IOHIDDeviceRegisterInputReportCallback(dev, inputBuf!, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr = manager { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
        inputBuf?.deallocate()
        inputBuf = nil
        device = nil
        manager = nil
    }

    func send(_ bytes: [UInt8]) -> Bool {
        guard let dev = device else { return false }
        var pkt = [UInt8](repeating: 0, count: 64)
        for (i, v) in bytes.prefix(64).enumerated() { pkt[i] = v }
        let type: IOHIDReportType = featureSize > 0 ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        let ok = IOHIDDeviceSetReport(dev, type, 0, pkt, 64) == kIOReturnSuccess
        lastStatus = featureSize > 0 ? readFeature() : nil
        return ok
    }

    /// 读回 feature report（有线模式下设备把收到的帧连同状态字节回显）
    func readFeature() -> [UInt8]? {
        guard let dev = device, featureSize > 0 else { return nil }
        var pkt = [UInt8](repeating: 0, count: 64)
        var len = CFIndex(64)
        guard IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 0, &pkt, &len) == kIOReturnSuccess else { return nil }
        return Array(pkt[0..<Int(len)])
    }

    func waitFrame(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while acks == 0 {
            if deadline.timeIntervalSinceNow <= 0 { return false }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
        }
        acks = 0
        return true
    }

    func clearFrames() {
        frames.removeAll()
        acks = 0
    }

    func collect(_ timeout: TimeInterval) -> [[UInt8]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
        }
        let f = frames
        frames.removeAll()
        acks = 0
        return f
    }

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
                    if let r = readFeature(), r.count >= 2, r[0] == b0, r[1] == b1 { return true }
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

// MARK: - 键位视图

final class KeyGridView: NSView {
    var selection: Set<Int> = [] { didSet { needsDisplay = true } }
    var paintColor = NSColor.systemRed
    var scale: CGFloat = 1
    var onSelectionChange: (() -> Void)?
    private var dragValue: Bool?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(kKeyboardWidth) * scale, height: CGFloat(kKeyboardHeight) * scale)
    }

    private func capRect(_ cap: KeyCap) -> NSRect {
        NSRect(x: CGFloat(cap.x) * scale, y: CGFloat(cap.y) * scale,
               width: CGFloat(cap.w) * scale, height: CGFloat(cap.h) * scale)
    }

    func cap(at p: NSPoint) -> KeyCap? {
        for cap in kKeyCaps where capRect(cap).insetBy(dx: 1, dy: 1).contains(p) { return cap }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        for cap in kKeyCaps {
            let rect = capRect(cap)
            let selected = selection.contains(cap.lightIndex)
            let fill = selected ? paintColor.withAlphaComponent(0.85) : NSColor(calibratedWhite: 0.28, alpha: 1)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSColor(calibratedWhite: 0.06, alpha: 1).setStroke()
            let stroke = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            stroke.lineWidth = 1
            stroke.stroke()

            if scale > 0.8 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                ]
                let s = NSAttributedString(string: cap.name, attributes: attrs)
                let size = s.size()
                guard size.width < rect.width - 4 else { continue }
                s.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                   y: rect.maxY - size.height - 3))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let cap = cap(at: p) else { return }
        let willSelect = !selection.contains(cap.lightIndex)
        dragValue = willSelect
        if willSelect { selection.insert(cap.lightIndex) } else { selection.remove(cap.lightIndex) }
        onSelectionChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let want = dragValue else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let cap = cap(at: p) else { return }
        if want { selection.insert(cap.lightIndex) } else { selection.remove(cap.lightIndex) }
        onSelectionChange?()
    }

    override func mouseUp(with event: NSEvent) { dragValue = nil }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let link = T88Link()

    private var statusLabel: NSTextField!
    private var logView: NSTextView!

    // 灯效控件
    private var modePopup: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var brightnessSlider: NSSlider!
    private var speedSlider: NSSlider!
    private var brightnessLabel: NSTextField!
    private var speedLabel: NSTextField!
    private var directionSegment: NSSegmentedControl!
    private var payloadPreview: NSTextField!
    private var previewModeLabel: NSTextField!
    private var previewSwatch: NSView!

    // 参数控件
    private var checkA: NSButton!
    private var checkB: NSButton!
    private var checkC: NSButton!
    private var fnSwitch: NSButton!
    private var tachyon: NSButton!
    private var continuousRT: NSButton!
    private var sleepField: NSTextField!
    private var respondField: NSTextField!
    private var tickField: NSTextField!

    // 逐键控件
    private var grid: KeyGridView!
    private var gridColor: NSColorWell!
    private var gridInfoLabel: NSTextField!
    private var gridLayoutPopup: NSPopUpButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadState()
        refreshDevice()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 菜单

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Luma88", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    // MARK: 窗口与界面

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Luma88"
        window.minSize = NSSize(width: 920, height: 700)
        window.center()

        let content = NSView()
        window.contentView = content

        // 顶部状态栏
        statusLabel = NSTextField(labelWithString: "正在检测设备…")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let refreshButton = NSButton(title: "重新检测", target: self, action: #selector(refreshDevice))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        let header = NSStackView(views: [statusLabel, NSView(), refreshButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY

        // 标签页
        let tabs = NSTabView()
        tabs.addTabViewItem(tab("灯效", view: buildLightTab()))
        tabs.addTabViewItem(tab("设备参数", view: buildSettingsTab()))
        tabs.addTabViewItem(tab("逐键灯效", view: buildKeysTab()))
        tabs.addTabViewItem(tab("关于 / 日志", view: buildAboutTab()))
        if let env = ProcessInfo.processInfo.environment["T88_TAB"], let idx = Int(env),
           idx >= 0, idx < tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: idx)
        }

        // 日志
        logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 880, height: 120))
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.containerSize = NSSize(width: 880, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainer?.widthTracksTextView = true
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = NSColor.controlBackgroundColor
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        logView.textStorage?.setAttributedString(NSAttributedString(
            string: "操作日志（发送的报文、回帧、错误都会显示在这里）。\n",
            attributes: logView.typingAttributes))
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let clearLog = NSButton(title: "清空日志", target: self, action: #selector(clearLogAction))
        clearLog.bezelStyle = .rounded
        clearLog.controlSize = .small
        let logHeader = NSStackView(views: [sectionTitle("日志"), NSView(), clearLog])
        logHeader.orientation = .horizontal
        logHeader.alignment = .centerY

        let root = NSStackView(views: [header, tabs, logHeader, logScroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            logHeader.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
            logScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
        ])
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabs.heightAnchor.constraint(equalToConstant: 520).isActive = true

        window.makeKeyAndOrderFront(nil)
    }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 900).isActive = true
        view.heightAnchor.constraint(equalToConstant: 490).isActive = true
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 860
        return l
    }

    private func makeColorWell(_ color: NSColor) -> NSColorWell {
        let w = NSColorWell()
        w.color = color
        w.translatesAutoresizingMaskIntoConstraints = false
        w.widthAnchor.constraint(equalToConstant: 56).isActive = true
        w.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return w
    }

    // MARK: 灯效页

    private func buildLightTab() -> NSView {
        let container = NSView()

        modePopup = NSPopUpButton()
        for (id, name) in kLightModes {
            modePopup.addItem(withTitle: "\(id)  \(name)")
        }
        modePopup.target = self
        modePopup.action = #selector(lightModeChanged)

        colorWell = makeColorWell(.white)
        colorWell.target = self
        colorWell.action = #selector(lightInputChanged)
        brightnessSlider = NSSlider(value: 5, minValue: 1, maxValue: 5, target: nil, action: nil)
        brightnessSlider.numberOfTickMarks = 5
        brightnessSlider.allowsTickMarkValuesOnly = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(sliderChanged)
        speedSlider = NSSlider(value: 3, minValue: 1, maxValue: 5, target: nil, action: nil)
        speedSlider.numberOfTickMarks = 5
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.target = self
        speedSlider.action = #selector(sliderChanged)
        brightnessLabel = NSTextField(labelWithString: "5")
        speedLabel = NSTextField(labelWithString: "3")

        directionSegment = NSSegmentedControl(labels: ["0", "1", "2", "3"], trackingMode: .selectOne, target: self, action: #selector(lightInputChanged))
        directionSegment.selectedSegment = 0

        let apply = NSButton(title: "应用灯效", target: self, action: #selector(applyLightAction))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let applySave = NSButton(title: "应用并写入 EEPROM", target: self, action: #selector(applyLightSaveAction))
        applySave.bezelStyle = .rounded
        let restore = NSButton(title: "恢复首次备份", target: self, action: #selector(restoreLightAction))
        restore.bezelStyle = .rounded

        let rows = NSStackView(views: [
            row([NSTextField(labelWithString: "模式"), modePopup]),
            row([NSTextField(labelWithString: "自定义颜色"), colorWell,
                 NSTextField(labelWithString: "（仅模式 1/2/3/4/5/7 生效）")]),
            row([NSTextField(labelWithString: "亮度 1-5"), brightnessSlider, brightnessLabel]),
            row([NSTextField(labelWithString: "速度 1-5"), speedSlider, speedLabel]),
            row([NSTextField(labelWithString: "方向 0-3"), directionSegment]),
            row([apply, applySave, restore]),
            hint("亮度拉到 0 或选模式 20 会发关闭背光指令（载荷 [0]=0x80）。\n"
                 + "不带“写入 EEPROM”只改内存，断电后回到上次落盘的值。"),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        // 右侧预览：把空格子用来显示即将发送的报文
        payloadPreview = NSTextField(wrappingLabelWithString: "")
        payloadPreview.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        payloadPreview.textColor = .secondaryLabelColor
        payloadPreview.preferredMaxLayoutWidth = 320
        previewModeLabel = NSTextField(labelWithString: "")
        previewModeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        previewSwatch = NSView()
        previewSwatch.wantsLayer = true
        previewSwatch.translatesAutoresizingMaskIntoConstraints = false
        previewSwatch.widthAnchor.constraint(equalToConstant: 120).isActive = true
        previewSwatch.heightAnchor.constraint(equalToConstant: 40).isActive = true
        previewSwatch.layer?.cornerRadius = 6

        let previewStack = NSStackView(views: [
            sectionTitle("预览"),
            previewModeLabel,
            previewSwatch,
            payloadPreview,
        ])
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 8
        previewStack.translatesAutoresizingMaskIntoConstraints = false

        // 底部：模式速查，填掉左侧空白，也方便对照 CLI 的模式号
        var modeCells: [[NSView]] = []
        let perRow = 4
        for i in stride(from: 0, to: kLightModes.count, by: perRow) {
            var line: [NSView] = []
            for j in i..<min(i + perRow, kLightModes.count) {
                let (id, name) = kLightModes[j]
                let l = NSTextField(labelWithString: "\(id) \(name)")
                l.font = NSFont.systemFont(ofSize: 11)
                l.textColor = .secondaryLabelColor
                line.append(l)
            }
            while line.count < perRow { line.append(NSView()) }
            modeCells.append(line)
        }
        let modeGrid = NSGridView(views: modeCells)
        modeGrid.rowSpacing = 4
        modeGrid.columnSpacing = 18
        modeGrid.translatesAutoresizingMaskIntoConstraints = false

        let modeBox = NSStackView(views: [sectionTitle("模式速查（1-20）"), modeGrid])
        modeBox.orientation = .vertical
        modeBox.alignment = .leading
        modeBox.spacing = 8
        modeBox.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(rows)
        container.addSubview(previewStack)
        container.addSubview(modeBox)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            previewStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            previewStack.leadingAnchor.constraint(equalTo: rows.trailingAnchor, constant: 24),
            previewStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            modeBox.topAnchor.constraint(greaterThanOrEqualTo: rows.bottomAnchor, constant: 16),
            modeBox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            modeBox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            modeBox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        updateLightPreview()
        return container
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 10
        if let first = views.first as? NSTextField, first.stringValue.count > 0 {
            first.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        return s
    }

    // MARK: 参数页

    private func buildSettingsTab() -> NSView {
        let container = NSView()

        checkA = NSButton(checkboxWithTitle: "复选框 A（[2]）", target: nil, action: nil)
        checkB = NSButton(checkboxWithTitle: "复选框 B（[3]）", target: nil, action: nil)
        checkC = NSButton(checkboxWithTitle: "复选框 C（[4]）", target: nil, action: nil)

        fnSwitch = NSButton(checkboxWithTitle: "Fn 层开关（[5] fn_switch）", target: nil, action: nil)
        tachyon = NSButton(checkboxWithTitle: "极速模式（[13] perf_tachyon_mode）", target: nil, action: nil)
        continuousRT = NSButton(checkboxWithTitle: "连续快速触发（[14] continuous_rapidtrigger）", target: nil, action: nil)

        sleepField = NSTextField(string: "0")
        respondField = NSTextField(string: "1")
        tickField = NSTextField(string: "1")
        for f in [sleepField!, respondField!, tickField!] {
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }

        let apply = NSButton(title: "应用参数", target: self, action: #selector(applySettingsAction))
        apply.bezelStyle = .rounded
        let applySave = NSButton(title: "应用并写入 EEPROM", target: self, action: #selector(applySettingsSaveAction))
        applySave.bezelStyle = .rounded
        let read = NSButton(title: "尝试读回", target: self, action: #selector(readSettingsAction))
        read.bezelStyle = .rounded

        let rows = NSStackView(views: [
            sectionTitle("00 01 参数块"),
            checkA, checkB, checkC,
            fnSwitch, tachyon, continuousRT,
            row([NSTextField(labelWithString: "休眠时间 [6]"), sleepField]),
            row([NSTextField(labelWithString: "按键响应 [8]"), respondField]),
            row([NSTextField(labelWithString: "轮询率 [12]"), tickField]),
            row([apply, applySave, read]),
            hint("[2][3][4] 是三个复选框（布尔开关），不是下拉索引。\n"
                 + "2.4G 接收器不回读参数，点“尝试读回”只会看到固定确认帧。"),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    // MARK: 逐键页

    private func buildKeysTab() -> NSView {
        let container = NSView()

        grid = KeyGridView()
        grid.scale = 0.95
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: CGFloat(kKeyboardWidth) * 0.95).isActive = true
        grid.heightAnchor.constraint(equalToConstant: CGFloat(kKeyboardHeight) * 0.95).isActive = true

        gridColor = makeColorWell(NSColor.systemRed)
        gridInfoLabel = NSTextField(labelWithString: "已选 0 个键")
        gridInfoLabel.font = NSFont.systemFont(ofSize: 11)
        gridInfoLabel.textColor = .secondaryLabelColor

        gridLayoutPopup = NSPopUpButton()
        gridLayoutPopup.addItem(withTitle: "128 键布局（512B，[8]=8）")
        gridLayoutPopup.addItem(withTitle: "144 键布局（576B，[8]=9）")

        let selectAll = NSButton(title: "全选", target: self, action: #selector(selectAllKeys))
        selectAll.bezelStyle = .rounded
        let clear = NSButton(title: "清空选择", target: self, action: #selector(clearKeys))
        clear.bezelStyle = .rounded
        let apply = NSButton(title: "应用到选中键", target: self, action: #selector(applyKeysAction))
        apply.bezelStyle = .rounded
        let applySave = NSButton(title: "应用并写入 EEPROM", target: self, action: #selector(applyKeysSaveAction))
        applySave.bezelStyle = .rounded
        let read = NSButton(title: "尝试回读", target: self, action: #selector(readKeysAction))
        read.bezelStyle = .rounded

        let toolbar = NSStackView(views: [
            NSTextField(labelWithString: "颜色"), gridColor,
            NSTextField(labelWithString: "布局"), gridLayoutPopup,
            selectAll, clear, apply, applySave, read, gridInfoLabel,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8

        let rows = NSStackView(views: [
            sectionTitle("逐键颜色（点选/拖选键位）"),
            toolbar,
            grid,
            hint("协议：04 18 → 04 20（仅应用）或 04 23（应用+04 F0 落盘）→ 数据块分帧 → 04 02。\n"
                 + "记录格式 {键序号, R, G, B}，键序号取 T88-keyboard.xml 的 light_index（1..88），"
                 + "写入槽位按 0 基（light_index-1）【推断】。\n"
                 + "选中键填当前颜色，未选中的键保持黑色（= 熄灭）。"),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
        // 键位点击后刷新计数
        grid.onSelectionChange = { [weak self] in
            guard let self = self else { return }
            self.gridInfoLabel.stringValue = "已选 \(self.grid.selection.count) 个键"
        }
        return container
    }

    // MARK: 关于页

    private func buildAboutTab() -> NSView {
        let container = NSView()
        let text = """
        Luma88 · T88 键盘控制面板（macOS Intel）

        协议参数由本机实测整理，详见仓库 docs/protocol.md：
        · 灯效        04 18 → 04 13 [8]=1 → 64B 载荷 → 04 02 (→ 04 F0)
        · 设备参数    04 18 → 00 01 参数块 → 04 02 (→ 04 F0)
        · 逐键灯效    04 18 → 04 20 / 04 23 → 数据块 → 04 02 (→ 04 F0)
        · 回读        04 17 / 04 F5（2.4G 接收器只回固定帧 0F 01 01 11）

        命令行版：bin/t88ctl（同一协议，可脚本化）。
        状态目录：~/.config/t88ctl/
        """
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.preferredMaxLayoutWidth = 820
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
        ])
        return container
    }

    // MARK: 状态存取

    private func loadState() {
        var light = LightState()
        var settings = DeviceSettings()
        if let data = try? Data(contentsOf: cliLightURL),
           let s = try? JSONDecoder().decode(LightState.self, from: data) {
            light = s
        }
        if let data = try? Data(contentsOf: guiStateURL),
           let s = try? JSONDecoder().decode(DeviceSettings.self, from: data) {
            settings = s
        }

        modePopup.selectItem(at: max(0, min(kLightModes.count - 1, light.mode - 1)))
        colorWell.color = NSColor(srgbRed: CGFloat(light.r) / 255, green: CGFloat(light.g) / 255,
                                  blue: CGFloat(light.b) / 255, alpha: 1)
        brightnessSlider.integerValue = light.brightness
        speedSlider.integerValue = light.speed
        brightnessLabel.stringValue = "\(light.brightness)"
        speedLabel.stringValue = "\(light.speed)"
        directionSegment.selectedSegment = min(3, max(0, light.direction))

        checkA.state = settings.checkA != 0 ? .on : .off
        checkB.state = settings.checkB != 0 ? .on : .off
        checkC.state = settings.checkC != 0 ? .on : .off
        fnSwitch.state = settings.fnSwitch != 0 ? .on : .off
        tachyon.state = settings.tachyonMode != 0 ? .on : .off
        continuousRT.state = settings.continuousRT != 0 ? .on : .off
        sleepField.stringValue = "\(settings.sleepTime)"
        respondField.stringValue = "\(settings.respondTime)"
        tickField.stringValue = "\(settings.tickRate)"
    }

    private func saveLight(_ s: LightState) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: cliLightURL) }
    }

    private func saveSettings(_ s: DeviceSettings) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: guiStateURL) }
    }

    // MARK: 日志

    private func log(_ line: String) {
        // 追加文本必须带上属性：直接 string += 会用默认黑色字，在深色外观下看不见
        let color: NSColor = line.hasPrefix("✓") ? .systemGreen
            : (line.hasPrefix("✗") ? .systemRed : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: color,
        ]
        logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: attrs))
        logView.scrollRangeToVisible(NSRange(location: logView.string.count, length: 0))
        logView.needsDisplay = true
        print(line)
    }

    private func logStatus(_ label: String) {
        guard let st = link.lastStatus else { return }
        log("  状态[\(label)]: \(hexLine(st))")
    }

    private func logFail(_ action: String) {
        log("✗ \(action)失败（设备无响应或接口不可用）")
    }

    // MARK: 动作

    @objc private func refreshDevice() {
        let r = link.open()
        statusLabel.stringValue = r
        log("设备：\(r)")
        if !link.isOpen {
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func lightInputChanged() { updateLightPreview() }

    @objc private func clearLogAction() {
        logView.string = ""
    }

    /// 用当前控件值算出将要发送的 64 字节载荷，显示在右侧预览里。
    private func updateLightPreview() {
        guard payloadPreview != nil, modePopup != nil, colorWell != nil else { return }
        let s = currentLightState()
        let payload = lightPayload(s)
        previewModeLabel.stringValue = "\(s.mode) \(LightState.modeName(s.mode))"
            + (kSingleColorModes.contains(s.mode) ? "（单色模式，使用自定义颜色）" : "（多彩模式，固件忽略自定义颜色）")
        previewSwatch.layer?.backgroundColor = NSColor(srgbRed: CGFloat(s.r) / 255,
                                                      green: CGFloat(s.g) / 255,
                                                      blue: CGFloat(s.b) / 255,
                                                      alpha: 1).cgColor
        payloadPreview.stringValue = "04 18 → 04 13 [8]=01 → 载荷 →\n04 02（→ 04 F0 落盘）\n\n"
            + hexLine(payload)
    }

    @objc private func lightModeChanged() {
        // 只更新界面，不发送
        let idx = modePopup.indexOfSelectedItem + 1
        let isOff = idx == 20
        brightnessSlider.isEnabled = !isOff
        colorWell.isEnabled = kSingleColorModes.contains(idx)
        updateLightPreview()
    }

    @objc private func sliderChanged() {
        brightnessLabel.stringValue = "\(brightnessSlider.integerValue)"
        speedLabel.stringValue = "\(speedSlider.integerValue)"
        updateLightPreview()
    }

    private func currentLightState() -> LightState {
        var s = LightState()
        s.mode = modePopup.indexOfSelectedItem + 1
        if let c = colorWell.color.usingColorSpace(.sRGB) {
            s.r = Int(round(c.redComponent * 255))
            s.g = Int(round(c.greenComponent * 255))
            s.b = Int(round(c.blueComponent * 255))
        }
        s.brightness = brightnessSlider.integerValue
        s.speed = speedSlider.integerValue
        s.direction = directionSegment.selectedSegment
        return s
    }

    private func sendLight(_ s: LightState, save: Bool) {
        guard link.isOpen else { logFail("发送灯效"); return }

        let payload = lightPayload(s)

        log("→ 灯效 模式 \(s.mode) \(LightState.modeName(s.mode))  亮度 \(s.brightness)  速度 \(s.speed)")
        guard link.command(0x04, 0x18) else { logFail("握手"); return }
        guard link.command(0x04, 0x13, extra: [8: 0x01]) else { logFail("进入灯效配置"); return }
        _ = link.send(payload)
        logStatus("载荷")
        _ = link.waitFrame(0.2)
        usleep(20_000)
        log("  \(hexLine(payload))")
        guard link.command(0x04, 0x02) else { logFail("应用灯效"); return }
        if save {
            _ = link.command(0x04, 0xF0)
            log("  已写入 EEPROM（掉电保留）")
        }
        saveLight(s)
        log("✓ 已发送")
    }

    @objc private func applyLightAction() { sendLight(currentLightState(), save: false) }
    @objc private func applyLightSaveAction() { sendLight(currentLightState(), save: true) }

    @objc private func restoreLightAction() {
        guard let data = try? Data(contentsOf: cliBackupURL),
              let s = try? JSONDecoder().decode(LightState.self, from: data) else {
            log("没有备份（\(cliBackupURL.path) 不存在）。可用模式 11 手动恢复出厂灯效。")
            return
        }
        sendLight(s, save: true)
        log("已用备份恢复：模式 \(s.mode) 亮度 \(s.brightness) 速度 \(s.speed)")
    }

    private func currentSettings() -> DeviceSettings {
        var s = DeviceSettings()
        s.checkA = checkA.state == .on ? 1 : 0
        s.checkB = checkB.state == .on ? 1 : 0
        s.checkC = checkC.state == .on ? 1 : 0
        s.fnSwitch = fnSwitch.state == .on ? 1 : 0
        s.tachyonMode = tachyon.state == .on ? 1 : 0
        s.continuousRT = continuousRT.state == .on ? 1 : 0
        s.sleepTime = Int(sleepField.stringValue) ?? 0
        s.respondTime = Int(respondField.stringValue) ?? 1
        s.tickRate = Int(tickField.stringValue) ?? 1
        return s
    }

    private func sendSettings(save: Bool) {
        guard link.isOpen else { logFail("发送参数"); return }
        let s = currentSettings()
        let p = s.packet
        log("→ 参数块 checkA/B/C=\(s.checkA)/\(s.checkB)/\(s.checkC) fn=\(s.fnSwitch) 休眠=\(s.sleepTime) 响应=\(s.respondTime) 轮询=\(s.tickRate)")
        log("  \(hexLine(p))")
        guard link.command(0x04, 0x18) else { logFail("握手"); return }
        _ = link.send(p)
        logStatus("参数块")
        _ = link.waitFrame(0.2)
        usleep(20_000)
        guard link.command(0x04, 0x02) else { logFail("应用参数"); return }
        if save {
            _ = link.command(0x04, 0xF0)
            log("  已写入 EEPROM（掉电保留）")
        }
        saveSettings(s)
        log("✓ 已发送")
    }

    @objc private func applySettingsAction() { sendSettings(save: false) }
    @objc private func applySettingsSaveAction() { sendSettings(save: true) }

    @objc private func readSettingsAction() { readBlock(cmd: (0x04, 0x17), extra: [2: 1, 8: 1], title: "参数") }

    @objc private func readKeysAction() { readBlock(cmd: (0x04, 0xF5), extra: [8: 9], title: "逐键") }

    private func readBlock(cmd: (UInt8, UInt8), extra: [Int: UInt8], title: String) {
        guard link.isOpen else { logFail("读回"); return }
        guard link.command(0x04, 0x18) else { logFail("握手"); return }
        link.clearFrames()
        var q = [UInt8](repeating: 0, count: 64)
        q[0] = cmd.0; q[1] = cmd.1
        for (k, v) in extra { q[k] = v }
        _ = link.send(q)
        if link.usesFeature {
            if let st = link.lastStatus {
                log("← \(title) 状态: \(hexLine(st))")
            } else {
                log("← \(title)：feature 回读无内容")
            }
            return
        }
        let frames = link.collect(1.0)
        if frames.isEmpty {
            log("← \(title)：未收到回帧")
            return
        }
        log("← \(title)：收到 \(frames.count) 帧")
        for f in frames.prefix(8) { log("  \(hexLine(f))") }
        if frames.allSatisfy({ $0.first == 0x0F }) {
            log("  全是固定确认帧 0F 01 01 11，说明该通道不回读业务数据（2.4G 接收器实测如此）")
        }
    }

    @objc private func selectAllKeys() {
        grid.selection = Set(kKeyCaps.map { $0.lightIndex })
        grid.onSelectionChange?()
    }

    @objc private func clearKeys() {
        grid.selection = []
        grid.onSelectionChange?()
    }

    private func sendKeys(save: Bool) {
        guard link.isOpen else { logFail("发送逐键灯效"); return }
        guard !grid.selection.isEmpty else { log("请先点选键位。"); return }

        let layout = gridLayoutPopup.indexOfSelectedItem == 0 ? 128 : 144
        let blockLen = kKeyLayouts[layout]?.blockLen ?? 512
        let layoutCode: UInt8 = kKeyLayouts[layout]?.header ?? 8

        var c = (UInt8(255), UInt8(0), UInt8(0))
        if let col = gridColor.color.usingColorSpace(.sRGB) {
            c = (UInt8(round(col.redComponent * 255)),
                 UInt8(round(col.greenComponent * 255)),
                 UInt8(round(col.blueComponent * 255)))
        }

        let block = keyColorBlock(indexes: grid.selection, layout: layout, color: c)

        let cmdName = save ? "04 23" : "04 20"
        log("→ 逐键 \(grid.selection.count) 个键 颜色 #\(String(format: "%02X%02X%02X", c.0, c.1, c.2))  布局 \(layout)  数据块 \(blockLen)B")
        guard link.command(0x04, 0x18) else { logFail("握手"); return }
        guard link.command(0x04, save ? 0x23 : 0x20, extra: [8: layoutCode]) else { logFail("进入逐键配置"); return }
        for off in stride(from: 0, to: blockLen, by: 64) {
            _ = link.send(Array(block[off..<min(off + 64, blockLen)]))
        }
        logStatus("数据块末帧")
        _ = link.waitFrame(0.2)
        usleep(20_000)
        guard link.command(0x04, 0x02) else { logFail("应用逐键灯效"); return }
        if save {
            _ = link.command(0x04, 0xF0)
            log("  已写入 EEPROM（掉电保留）")
        }
        log("✓ 已发送（\(cmdName)）")
    }

    @objc private func applyKeysAction() { sendKeys(save: false) }
    @objc private func applyKeysSaveAction() { sendKeys(save: true) }
}

let appDelegate = AppDelegate()

@main
struct T88App {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
