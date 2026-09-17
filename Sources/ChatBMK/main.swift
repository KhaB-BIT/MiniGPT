import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var client: CodexAppServerClient?
  private var snapshot: CodexUsageSnapshot?
  private var refreshTimer: Timer?
  private var activityMonitor: CodexActivityMonitor?
  private var activityTimer: Timer?
  private var simulationTimer: Timer?
  private var isSimulatingRunning = false
  private var activityStatus = CodexActivityStatus.unavailable
  private var gearAnimationTimer: Timer?
  private var gearFrames: [NSImage] = []
  private var gearFrameIndex = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    self.statusItem = statusItem
    showLoadingState()

    let activityMonitor = CodexActivityMonitor { [weak self] status in
      guard self?.isSimulatingRunning != true else { return }
      self?.activityStatus = status
      self?.renderLatestSnapshot()
    }
    self.activityMonitor = activityMonitor
    activityMonitor.refresh()

    let client = CodexAppServerClient(
      onSnapshot: { [weak self] snapshot in
        self?.apply(snapshot)
      },
      onError: { [weak self] message in
        self?.showError(message)
      }
    )
    self.client = client

    do {
      try client.start()
    } catch {
      showError(error.localizedDescription)
    }

    refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.client?.refresh()
        self?.renderLatestSnapshot()
      }
    }

    activityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.activityMonitor?.refresh()
      }
    }

    if let duration = ProcessInfo.processInfo.environment["CHATBMK_SIMULATE_RUNNING_SECONDS"],
      let seconds = TimeInterval(duration), seconds > 0
    {
      isSimulatingRunning = true
      activityStatus = .running
      renderLatestSnapshot()
      simulationTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
        [weak self] _ in
        Task { @MainActor in
          self?.isSimulatingRunning = false
          self?.activityMonitor?.refresh()
        }
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    refreshTimer?.invalidate()
    activityTimer?.invalidate()
    simulationTimer?.invalidate()
    gearAnimationTimer?.invalidate()
    client?.stop()
  }

  func menuWillOpen(_ menu: NSMenu) {
    client?.refresh()
    renderLatestSnapshot()
  }

  private func apply(_ snapshot: CodexUsageSnapshot) {
    self.snapshot = snapshot
    renderLatestSnapshot()
  }

  private func renderLatestSnapshot() {
    guard let snapshot else { return }

    updateStatusBar(
      title: "\(snapshot.session5Hour.remainingPercent)% · ↻ "
        + relativeTime(until: snapshot.session5Hour.resetsAt),
      activityStatus: activityStatus
    )

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self

    menu.addItem(labelItem(title: "👤 \(snapshot.email ?? "Không rõ")"))
    menu.addItem(.separator())
    menu.addItem(
      labelItem(
        title: "🦾 Sức tay 5h: "
          + "\(snapshot.session5Hour.remainingPercent)%"
      )
    )
    menu.addItem(
      labelItem(
        title: "♻️ Hồi tay sau: \(resetDescription(snapshot.session5Hour.resetsAt))"
      )
    )

    let weeklyIcon = statusIcon(forRemainingPercent: snapshot.weekly.remainingPercent)
    menu.addItem(
      labelItem(
        title: "\(weeklyIcon) Sinh lực tuần: "
          + "\(snapshot.weekly.remainingPercent)%"
      )
    )
    menu.addItem(
      labelItem(title: "📅 Reset tuần: \(resetDescription(snapshot.weekly.resetsAt))")
    )
    menu.addItem(.separator())
    menu.addItem(actionItem(title: "↻ Làm mới", action: #selector(refreshUsage)))
    menu.addItem(actionItem(title: "Thoát MiniGPT", action: #selector(quitApplication)))

    statusItem?.menu = menu
  }

  private func showLoadingState() {
    updateStatusBar(title: "Đang tải…", activityStatus: .unavailable)

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    menu.addItem(labelItem(title: "⏳ Đang đọc thông tin từ Codex…"))
    menu.addItem(.separator())
    menu.addItem(actionItem(title: "Thoát MiniGPT", action: #selector(quitApplication)))
    statusItem?.menu = menu
  }

  private func showError(_ message: String) {
    guard snapshot == nil else { return }

    updateStatusBar(title: "Không có dữ liệu", activityStatus: .unavailable)

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    menu.addItem(labelItem(title: "⚠️ Không đọc được thông tin Codex"))
    menu.addItem(labelItem(title: message))
    menu.addItem(labelItem(title: "Hãy cài Codex CLI rồi chạy codex để đăng nhập"))
    menu.addItem(.separator())
    menu.addItem(actionItem(title: "↻ Thử lại", action: #selector(refreshUsage)))
    menu.addItem(actionItem(title: "Thoát MiniGPT", action: #selector(quitApplication)))
    statusItem?.menu = menu
  }

  private func labelItem(title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = true
    return item
  }

  private func actionItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    return item
  }

  private func updateStatusBar(
    title: String,
    activityStatus: CodexActivityStatus
  ) {
    guard let statusItem, let button = statusItem.button else { return }

    statusItem.length = NSStatusItem.variableLength
    let isRunning = activityStatus == .running
    button.title = isRunning ? title : "\(activityStatus.menuBarIcon) \(title)"
    button.imagePosition = isRunning ? .imageLeading : .noImage
    button.imageScaling = .scaleProportionallyDown

    if isRunning {
      startGearAnimation(on: button)
    } else {
      stopGearAnimation()
      button.image = nil
    }
  }

  private func startGearAnimation(on button: NSStatusBarButton) {
    if gearFrames.isEmpty {
      gearFrames = makeGearFrames()
    }
    guard !gearFrames.isEmpty else { return }

    button.image = gearFrames[gearFrameIndex]
    guard gearAnimationTimer == nil else { return }

    gearAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, let button = self.statusItem?.button, !self.gearFrames.isEmpty else {
          return
        }
        self.gearFrameIndex = (self.gearFrameIndex + 1) % self.gearFrames.count
        button.image = self.gearFrames[self.gearFrameIndex]
      }
    }
  }

  private func stopGearAnimation() {
    gearAnimationTimer?.invalidate()
    gearAnimationTimer = nil
    gearFrameIndex = 0
  }

  private func makeGearFrames() -> [NSImage] {
    guard let symbol = NSImage(
      systemSymbolName: "gearshape.fill",
      accessibilityDescription: "Codex đang chạy"
    )?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(hierarchicalColor: .white)
    ) else {
      return []
    }

    let imageSize = NSSize(width: 16, height: 16)
    return (0..<36).map { frameIndex in
      let angle = CGFloat(frameIndex) * .pi / 18
      return NSImage(size: imageSize, flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: angle)
        symbol.draw(
          in: NSRect(x: -8, y: -8, width: 16, height: 16)
        )
        context.restoreGState()
        return true
      }
    }
  }

  private func statusIcon(forRemainingPercent percentage: Int) -> String {
    switch percentage {
    case 50...100: "🟢"
    case 20..<50: "🟡"
    case 1..<20: "🔴"
    default: "⚪️"
    }
  }

  private func resetDescription(_ date: Date?) -> String {
    guard let date else { return "Không rõ" }
    return relativeTime(until: date)
  }

  private func relativeTime(until date: Date?) -> String {
    guard let date else { return "--" }

    let totalMinutes = max(0, Int(date.timeIntervalSinceNow / 60))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "\(days)d \(hours)h \(minutes)m"
    }
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  @objc private func refreshUsage() {
    client?.refresh()
  }

  @objc private func quitApplication() {
    NSApp.terminate(nil)
  }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
