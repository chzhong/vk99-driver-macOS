import AppKit
import IOKit.hid
import ServiceManagement
import UniformTypeIdentifiers
import VK99Core

@MainActor final class VK99GUI: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let loginPreferenceKey = "VK99LoginDesired"
    private let lastSentKey = "VK99LastClockSentAt"
    private let dailyDayKey = "VK99LastScheduledSyncDay"

    private var window: NSWindow!
    private var deviceLabel: NSTextField!
    private var clockLabel: NSTextField!
    private var lastSentLabel: NSTextField!
    private var syncFeedbackLabel: NSTextField!
    private var loginStatusLabel: NSTextField!
    private var loginSwitch: NSSwitch!
    private var syncButton: NSButton!
    private var statusLabels: [String: NSTextField] = [:]
    private var uploadLabel: NSTextField!
    private var preview: NSImageView!
    private var uploadButton: NSButton!
    private var verifyButton: NSButton!
    private var developerSwitch: NSSwitch!
    private var developerDetails: NSTextField!
    private var reportButton: NSButton!
    private var reportWindow: NSWindow?
    private var reportTextView: NSTextView?
    private var catalogPopups: [String: NSPopUpButton] = [:]

    private var catalog: SettingsCatalog?
    private var selectedPacked: [UInt8]?
    private var selectedName: String?
    private var hidManager: IOHIDManager?
    private var statusItem: NSStatusItem?
    private var clockTimer: Timer?
    private var dailyTimer: Timer?
    private var syncState = ClockSyncState(
        lastSatisfiedDay: UserDefaults.standard.string(forKey: "VK99LastScheduledSyncDay"))

    static func run() {
        let app = NSApplication.shared
        let delegate = VK99GUI()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadCatalog()
        buildWindow()
        buildStatusMenu()
        configureLoginItem()
        startDeviceMonitor()
        registerClockNotifications()
        refreshDevice()
        scheduleDailyTimer()
        perform(#selector(startupSyncIfNeeded), with: nil, afterDelay: 0.3)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateClockLabel()
                self?.updateCapsLock()
            }
        }
        showWindow()
        if ProcessInfo.processInfo.environment["VK99_GUI_SELFTEST"] == "1" {
            perform(#selector(runCloseReopenCheck), with: nil, afterDelay: 0.5)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        dailyTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "VK99 macOS"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let tabs = NSTabView(frame: NSRect(x: 18, y: 18, width: 724, height: 654))
        tabs.tabViewType = .topTabsBezelBorder
        window.contentView?.addSubview(tabs)

        let basic = NSTabViewItem(identifier: "basic")
        basic.label = "基本"
        basic.view = buildBasicTab()
        tabs.addTabViewItem(basic)

        let settings = NSTabViewItem(identifier: "settings")
        settings.label = "设置"
        settings.view = buildSettingsTab()
        tabs.addTabViewItem(settings)
    }

    private func buildBasicTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 710, height: 614))
        addLabel("时间同步", at: NSRect(x: 22, y: 552, width: 650, height: 27), size: 20, bold: true, to: view)
        deviceLabel = addLabel("正在查找键盘…", at: NSRect(x: 22, y: 524, width: 650, height: 24), size: 13, to: view)
        clockLabel = addLabel("", at: NSRect(x: 22, y: 488, width: 650, height: 24), size: 15, to: view)
        lastSentLabel = addLabel("", at: NSRect(x: 22, y: 459, width: 650, height: 23), size: 13, to: view)
        syncFeedbackLabel = addLabel("自动同步：启动、重新连接、每天本地时间 03:00；睡眠错过后唤醒补发。",
                                     at: NSRect(x: 22, y: 428, width: 660, height: 23), size: 12, to: view)
        syncButton = addButton("立即同步", at: NSRect(x: 22, y: 382, width: 120, height: 34),
                               action: #selector(syncNow), to: view)
        addLabel("开机启动", at: NSRect(x: 182, y: 388, width: 95, height: 22), size: 13, to: view)
        loginSwitch = NSSwitch(frame: NSRect(x: 274, y: 382, width: 50, height: 30))
        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged)
        view.addSubview(loginSwitch)
        loginStatusLabel = addLabel("", at: NSRect(x: 338, y: 388, width: 340, height: 22), size: 12, to: view)

        addLabel("键盘当前状态", at: NSRect(x: 22, y: 332, width: 650, height: 27), size: 20, bold: true, to: view)
        let rows: [(String, String)] = [
            ("连接模式", "connection"), ("Caps Lock（Mac 端）", "caps"),
            ("Num Lock", "num"), ("键盘系统模式", "system"),
            ("旋钮功能", "knob"), ("电量", "battery"), ("充电状态", "charging")
        ]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(301 - index * 32)
            addLabel(row.0, at: NSRect(x: 24, y: y, width: 175, height: 22), size: 13, to: view)
            statusLabels[row.1] = addLabel("暂无法读取", at: NSRect(x: 205, y: y, width: 440, height: 22), size: 13, to: view)
        }
        addButton("刷新设备", at: NSRect(x: 548, y: 28, width: 120, height: 32),
                  action: #selector(refreshDevice), to: view)
        updateClockLabel()
        updateLastSentLabel()
        updateCapsLock()
        return view
    }

    private func buildSettingsTab() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 710, height: 614))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 686, height: 1160))
        scroll.documentView = view
        root.addSubview(scroll)

        addLabel("按 Fn＋旋钮切换到设置模式，再通过旋钮切换屏幕或进行键盘设置。",
                 at: NSRect(x: 22, y: 1104, width: 640, height: 25), size: 13, to: view)
        addLabel("当前设置", at: NSRect(x: 22, y: 1066, width: 620, height: 27), size: 20, bold: true, to: view)
        let rows: [(String, Int)] = [
            ("当前屏幕", 1034), ("语言", 1004), ("灯光效果", 974),
            ("灯光颜色", 944), ("灯光速率", 914), ("灯光亮度", 884)
        ]
        for (title, y) in rows {
            addLabel(title, at: NSRect(x: 24, y: y, width: 130, height: 22), size: 13, to: view)
            addLabel("暂无法读取", at: NSRect(x: 164, y: y, width: 320, height: 22), size: 13, to: view)
        }
        addLabel("灯光速率 0–100%", at: NSRect(x: 22, y: 839, width: 170, height: 22), size: 12, to: view)
        let speed = NSSlider(frame: NSRect(x: 190, y: 833, width: 310, height: 28))
        speed.minValue = 0
        speed.maxValue = 100
        speed.isEnabled = false
        view.addSubview(speed)
        addLabel("灯光亮度 0–100%", at: NSRect(x: 22, y: 800, width: 170, height: 22), size: 12, to: view)
        let brightness = NSSlider(frame: NSRect(x: 190, y: 794, width: 310, height: 28))
        brightness.minValue = 0
        brightness.maxValue = 100
        brightness.isEnabled = false
        view.addSubview(brightness)
        addLabel("协议值确认后才会启用调节；当前不会向键盘写入设置。",
                 at: NSRect(x: 22, y: 765, width: 620, height: 20), size: 12, to: view)

        addLabel("选项目录（浏览不会修改键盘）", at: NSRect(x: 22, y: 724, width: 620, height: 27), size: 17, bold: true, to: view)
        addCatalogPopup("屏幕", group: "screens", y: 685, to: view)
        addCatalogPopup("语言", group: "languages", y: 645, to: view)
        addCatalogPopup("颜色", group: "colors", y: 605, to: view)
        addCatalogPopup("灯光效果", group: "effects", y: 565, to: view)

        addLabel("开发者模式", at: NSRect(x: 22, y: 520, width: 130, height: 22), size: 13, to: view)
        developerSwitch = NSSwitch(frame: NSRect(x: 150, y: 515, width: 50, height: 30))
        developerSwitch.target = self
        developerSwitch.action = #selector(developerModeChanged)
        view.addSubview(developerSwitch)
        reportButton = addButton("查看 HID 报文…", at: NSRect(x: 455, y: 512, width: 170, height: 32),
                                 action: #selector(showReportWindow), to: view)
        reportButton.isHidden = true
        developerDetails = addLabel("", at: NSRect(x: 22, y: 444, width: 630, height: 68),
                                    size: 12, to: view, wraps: true)
        developerDetails.isHidden = true

        addLabel("上传自定义图片", at: NSRect(x: 22, y: 403, width: 620, height: 27), size: 20, bold: true, to: view)
        preview = NSImageView(frame: NSRect(x: 22, y: 142, width: 412, height: 246))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 8
        view.addSubview(preview)
        addLabel("160 × 96 屏幕数据预览", at: NSRect(x: 452, y: 354, width: 190, height: 22),
                 size: 12, to: view)
        addLabel("上传后请检查键盘右上面板，并确认图片显示正确。",
                 at: NSRect(x: 452, y: 286, width: 190, height: 60), size: 12, to: view, wraps: true)
        addButton("选择图片…", at: NSRect(x: 22, y: 95, width: 118, height: 34),
                  action: #selector(chooseImage), to: view)
        uploadButton = addButton("上传到屏幕", at: NSRect(x: 150, y: 95, width: 120, height: 34),
                                 action: #selector(uploadImage), to: view)
        verifyButton = addButton("已在屏幕确认", at: NSRect(x: 282, y: 95, width: 132, height: 34),
                                 action: #selector(confirmImage), to: view)
        verifyButton.isEnabled = false
        uploadLabel = addLabel("支持 PNG、JPEG、GIF 的首帧；图像按比例居中。",
                               at: NSRect(x: 22, y: 53, width: 620, height: 26), size: 12, to: view)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: view.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        return root
    }

    private func addCatalogPopup(_ title: String, group: String, y: Int, to view: NSView) {
        addLabel(title, at: NSRect(x: 24, y: y, width: 130, height: 23), size: 13, to: view)
        let popup = NSPopUpButton(frame: NSRect(x: 160, y: y - 4, width: 290, height: 29))
        popup.identifier = NSUserInterfaceItemIdentifier(group)
        popup.addItems(withTitles: catalog?.options(in: group).map(\.label) ?? ["目录加载失败"])
        popup.target = self
        popup.action = #selector(catalogSelectionChanged)
        view.addSubview(popup)
        catalogPopups[group] = popup
    }

    private func loadCatalog() {
        guard let url = Bundle.main.url(forResource: "SettingsCatalog", withExtension: "yaml"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? SettingsCatalog(yaml: source) else {
            catalog = nil
            return
        }
        catalog = parsed
    }

    @discardableResult private func addLabel(_ value: String, at frame: NSRect, size: CGFloat,
        bold: Bool = false, to view: NSView, wraps: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.frame = frame
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = wraps ? 0 : 1
        view.addSubview(field)
        return field
    }

    @discardableResult private func addButton(_ title: String, at frame: NSRect,
        action: Selector, to view: NSView) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = frame
        view.addSubview(button)
        return button
    }

    private func buildStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "VK99"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 VK99", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即同步时间", action: #selector(syncNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: ""))
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func runCloseReopenCheck() {
        guard let tabs = window.contentView?.subviews.compactMap({ $0 as? NSTabView }).first else {
            fatalError("Missing tabs")
        }
        tabs.selectTabViewItem(at: 1)
        let original = window
        guard let openItem = statusItem?.menu?.items.first,
              let action = openItem.action else { fatalError("Missing status menu action") }
        for _ in 0..<3 {
            window.performClose(nil)
            precondition(!window.isVisible, "Window did not hide")
            precondition(NSApplication.shared.sendAction(action, to: openItem.target, from: openItem),
                         "Status menu action failed")
            precondition(window === original && window.isVisible, "Window was not preserved")
            precondition(tabs.selectedTabViewItem?.identifier as? String == "settings", "Tab state was lost")
        }
        developerSwitch.state = .on
        developerModeChanged()
        showReportWindow()
        readRawFeature()
        precondition(reportTextView?.string.contains("Feature Report") == true,
                     "Developer report view did not show the capture result")
        print("VK99 GUI close/reopen check passed")
        NSApplication.shared.terminate(nil)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func configureLoginItem() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: loginPreferenceKey) == nil {
            defaults.set(true, forKey: loginPreferenceKey)
        }
        do {
            if defaults.bool(forKey: loginPreferenceKey), SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
            } else if !defaults.bool(forKey: loginPreferenceKey), SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginStatusLabel.stringValue = "登录项设置失败：\(error.localizedDescription)"
        }
        updateLoginControl()
    }

    private func updateLoginControl() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginSwitch.state = .on
            loginStatusLabel.stringValue = "已启用"
        case .requiresApproval:
            loginSwitch.state = .off
            loginStatusLabel.stringValue = "待系统设置批准"
        default:
            loginSwitch.state = .off
            if !loginStatusLabel.stringValue.hasPrefix("登录项设置失败") {
                loginStatusLabel.stringValue = "未启用"
            }
        }
    }

    @objc private func loginSwitchChanged() {
        let enable = loginSwitch.state != .off
        UserDefaults.standard.set(enable, forKey: loginPreferenceKey)
        do {
            if enable {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            loginStatusLabel.stringValue = ""
        } catch {
            loginStatusLabel.stringValue = "登录项设置失败：\(error.localizedDescription)"
        }
        updateLoginControl()
    }

    private func startDeviceMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x024F,
            kIOHIDPrimaryUsagePageKey: VK99Transport.featurePage
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<VK99GUI>.fromOpaque(context).takeUnretainedValue().deviceChanged(removed: false)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<VK99GUI>.fromOpaque(context).takeUnretainedValue().deviceChanged(removed: true)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            syncFeedbackLabel.stringValue = String(format: "设备监听启动失败：0x%08X", result)
        }
        hidManager = manager
    }

    private func deviceChanged(removed: Bool) {
        refreshDevice()
        if removed && !directUSBIsConnected() {
            _ = syncState.reason(for: .disconnected, at: Date(), timeZone: .current,
                                 connected: false)
        } else if !removed {
            perform(#selector(connectionSyncIfNeeded), with: nil, afterDelay: 0.3)
        }
    }

    private func directUSBIsConnected() -> Bool {
        scan().contains {
            $0.usagePage == VK99Transport.featurePage && $0.usage == 1 &&
            $0.transport == "USB" && $0.product == "Valkyrie-99pro"
        }
    }

    private func updateClockLabel() {
        clockLabel.stringValue = "电脑时间：\(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium))"
    }

    private func updateLastSentLabel() {
        if let last = UserDefaults.standard.object(forKey: lastSentKey) as? Date {
            lastSentLabel.stringValue = "上次发送同步时间：\(DateFormatter.localizedString(from: last, dateStyle: .short, timeStyle: .medium))"
        } else {
            lastSentLabel.stringValue = "上次发送同步时间：尚未发送"
        }
    }

    private func updateCapsLock() {
        let enabled = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        statusLabels["caps"]?.stringValue = enabled ? "开启" : "关闭"
    }

    @objc private func refreshDevice() {
        let interfaces = scan()
        let feature = interfaces.first { $0.usagePage == VK99Transport.featurePage && $0.usage == 1 }
        let output = interfaces.first { $0.usagePage == VK99Transport.outputPage && $0.usage == 0x61 }
        if let feature {
            deviceLabel.stringValue = "已连接：\(feature.product) · \(feature.transport ?? "未知连接")"
            if feature.product == "Valkyrie-99pro" && feature.transport == "USB" {
                statusLabels["connection"]?.stringValue = "USB"
            } else if feature.product.contains("Receiver") {
                statusLabels["connection"]?.stringValue = "2.4G 接收器"
            } else if feature.transport == "Bluetooth" {
                statusLabels["connection"]?.stringValue = "蓝牙（版本暂无法读取）"
            } else {
                statusLabels["connection"]?.stringValue = "暂无法读取"
            }
        } else {
            deviceLabel.stringValue = "未找到 VK99 配置接口；请连接键盘。"
            statusLabels["connection"]?.stringValue = "未连接"
        }
        syncButton.isEnabled = directUSBIsConnected()
        uploadButton.isEnabled = syncButton.isEnabled && output != nil && selectedPacked != nil
        updateCapsLock()
    }

    private func registerClockNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clockChanged),
            name: Notification.Name("NSSystemClockDidChangeNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clockChanged),
            name: Notification.Name("NSSystemTimeZoneDidChangeNotification"), object: nil)
    }

    private func scheduleDailyTimer() {
        dailyTimer?.invalidate()
        let fire = ClockSyncPolicy(timeZone: .current).nextFire(after: Date())
        let timer = Timer(fireAt: fire, interval: 0, target: self,
                          selector: #selector(dailyTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    @objc private func dailyTimerFired() {
        attemptSync(for: .dailyCheck)
        scheduleDailyTimer()
    }

    @objc private func woke() {
        refreshDevice()
        attemptSync(for: .wake)
        scheduleDailyTimer()
    }

    @objc private func clockChanged() {
        updateClockLabel()
        attemptSync(for: .clockChanged)
        scheduleDailyTimer()
    }

    private func attemptSync(for event: ClockSyncState.Event) {
        let now = Date()
        guard let reason = syncState.reason(for: event, at: now, timeZone: .current,
                                            connected: directUSBIsConnected()) else { return }
        performClockSync(prefix: reason == .daily ? "每日自动同步" : "连接后自动同步")
    }

    @objc private func startupSyncIfNeeded() { attemptSync(for: .startup) }
    @objc private func connectionSyncIfNeeded() { attemptSync(for: .connected) }

    @objc private func syncNow() { performClockSync(prefix: "手动同步") }

    @discardableResult private func performClockSync(prefix: String) -> Bool {
        let now = Date()
        do {
            try VK99Transport.syncClock(at: now)
            UserDefaults.standard.set(now, forKey: lastSentKey)
            syncState.recordSuccessfulSend(at: now, timeZone: .current)
            if let day = syncState.lastSatisfiedDay {
                UserDefaults.standard.set(day, forKey: dailyDayKey)
            }
            updateLastSentLabel()
            syncFeedbackLabel.stringValue = "\(prefix)指令已发送，请检查键盘右上面板时间。"
            return true
        } catch {
            syncFeedbackLabel.stringValue = "\(prefix)失败：\(error)"
            return false
        }
    }

    @objc private func developerModeChanged() {
        developerDetails.isHidden = developerSwitch.state != .on
        reportButton.isHidden = developerSwitch.state != .on
        if developerSwitch.state != .on { reportWindow?.orderOut(nil) }
        updateDeveloperDetails(group: "effects")
    }

    @objc private func showReportWindow() {
        guard developerSwitch.state == .on else { return }
        if reportWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                                 styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
            panel.title = "VK99 HID 报文检查"
            panel.isReleasedWhenClosed = false
            let root = NSView(frame: panel.contentView!.bounds)
            root.autoresizingMask = [.width, .height]
            addLabel("只读取当前 Feature Report；不会发送设置指令。",
                     at: NSRect(x: 20, y: 427, width: 675, height: 22), size: 13, to: root)
            addButton("读取 Feature 报文", at: NSRect(x: 20, y: 383, width: 170, height: 32),
                      action: #selector(readRawFeature), to: root)
            let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 680, height: 350))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let report = NSTextView(frame: scroll.bounds)
            report.isEditable = false
            report.isSelectable = true
            report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            report.string = "Windows 驱动有无线电量查询路径：发送 20 01，再读取返回报文。\n" +
                "该路径仅在无线分支使用；本窗口不会对 USB 键盘发送这条未验证的查询。\n\n" +
                "点击上方按钮读取当前 HID Feature Report。"
            scroll.documentView = report
            root.addSubview(scroll)
            panel.contentView = root
            panel.center()
            reportWindow = panel
            reportTextView = report
        }
        reportWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func readRawFeature() {
        guard developerSwitch.state == .on else { return }
        do {
            let bytes = try VK99Transport.readFeature()
            let captured = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            reportTextView?.string = "读取时间：\(captured)\n接口：厂商页 0xFF13，Feature Report ID 0\n" +
                "长度：\(bytes.count) 字节\n\n\(FeatureReportInspection.interpretation(bytes))\n\n" +
                FeatureReportInspection.hexDump(bytes)
        } catch {
            reportTextView?.string = "Feature Report 读取失败：\(error)"
        }
    }

    @objc private func catalogSelectionChanged(_ sender: NSPopUpButton) {
        updateDeveloperDetails(group: sender.identifier?.rawValue ?? "effects")
    }

    private func updateDeveloperDetails(group: String) {
        guard developerSwitch.state == .on else { return }
        guard let popup = catalogPopups[group],
              let option = catalog?.options(in: group).first(where: { $0.label == popup.titleOfSelectedItem }) else {
            developerDetails.stringValue = "目录未加载。"
            return
        }
        developerDetails.stringValue = "\(group) · \(option.label)\n原始值：\(option.rawValue ?? "未确认")\n依据：\(option.evidence ?? "未记录")。此目录只读。"
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let packed = try TFTImage.packedFrame(at: url)
            selectedPacked = packed
            selectedName = url.lastPathComponent
            preview.image = NSImage(cgImage: try TFTImage.preview(packed),
                                    size: NSSize(width: TFTImage.width, height: TFTImage.height))
            uploadLabel.stringValue = "已生成屏幕数据：\(url.lastPathComponent) · \(packed.count / VK99Transport.outputBytes) 块"
            verifyButton.isEnabled = false
        } catch {
            selectedPacked = nil
            uploadLabel.stringValue = "图片处理失败：\(error)"
        }
        refreshDevice()
    }

    @objc private func uploadImage() {
        guard let packed = selectedPacked else { return }
        let alert = NSAlert()
        alert.messageText = "替换键盘屏幕上的当前图像？"
        alert.informativeText = "将上传所选图片的首帧。请在上传后检查键盘右上面板。"
        alert.addButton(withTitle: "上传")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uploadButton.isEnabled = false
        uploadLabel.stringValue = "正在上传…"
        uploadLabel.displayIfNeeded()
        do {
            try VK99Transport.uploadTFT(packed)
            uploadLabel.stringValue = "已发送 \(packed.count / VK99Transport.outputBytes) 块：\(selectedName ?? "图片")。请检查屏幕。"
            verifyButton.isEnabled = true
        } catch {
            uploadLabel.stringValue = "上传失败：\(error)"
            verifyButton.isEnabled = false
        }
        refreshDevice()
    }

    @objc private func confirmImage() {
        uploadLabel.stringValue = "已在键盘屏幕确认：\(selectedName ?? "图片")。"
        verifyButton.isEnabled = false
    }
}
