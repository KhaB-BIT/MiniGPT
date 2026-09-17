import AppKit
import QuartzCore

@MainActor
final class AnimatedStatusBarView: NSView {
  private let imageView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    titleLabel.font = NSFont.menuBarFont(ofSize: 0)
    addSubview(imageView)
    addSubview(titleLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(title: String, activityStatus: CodexActivityStatus) {
    let isRunning = activityStatus == .running
    titleLabel.stringValue = isRunning ? title : "\(activityStatus.menuBarIcon) \(title)"
    titleLabel.sizeToFit()

    imageView.image =
      isRunning
      ? NSImage(
        systemSymbolName: "gearshape.fill",
        accessibilityDescription: "Codex đang chạy"
      )
      : nil
    imageView.isHidden = !isRunning
    imageView.frame = NSRect(x: 4, y: 3, width: 18, height: 18)
    titleLabel.frame = NSRect(
      x: isRunning ? 27 : 4,
      y: 2,
      width: titleLabel.frame.width,
      height: 20
    )
    frame.size = NSSize(
      width: titleLabel.frame.maxX + 4,
      height: 24
    )

    imageView.wantsLayer = isRunning
    if isRunning, let layer = imageView.layer {
      // Giữ tâm neo ở chính giữa bánh răng để icon không bị lệch quỹ đạo.
      layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      layer.position = CGPoint(
        x: imageView.frame.midX,
        y: imageView.frame.midY
      )
      layer.removeAnimation(forKey: "codexGearRotation")

      let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
      rotation.fromValue = 0
      rotation.toValue = Double.pi * 2
      rotation.duration = 1.2
      rotation.repeatCount = .infinity
      layer.add(rotation, forKey: "codexGearRotation")
    } else {
      imageView.layer?.removeAnimation(forKey: "codexGearRotation")
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var statusBarView: AnimatedStatusBarView?
  private var client: CodexAppServerClient?
  private var snapshot: CodexUsageSnapshot?
  private var refreshTimer: Timer?
  private var activityMonitor: CodexActivityMonitor?
  private var activityTimer: Timer?
  private var simulationTimer: Timer?
  private var isSimulatingRunning = false
  private var activityStatus = CodexActivityStatus.unavailable

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    self.statusItem = statusItem
    let statusBarView = AnimatedStatusBarView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    self.statusBarView = statusBarView
    statusItem.view = statusBarView
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
    statusBarView?.update(title: title, activityStatus: activityStatus)
    if let width = statusBarView?.frame.width {
      statusItem?.length = width
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
      return "\(days)d \(hours)h"
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
