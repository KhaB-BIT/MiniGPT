import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var client: CodexAppServerClient?
  private var snapshot: CodexUsageSnapshot?
  private var refreshTimer: Timer?
  private var activityMonitor: CodexActivityMonitor?
  private var activityTimer: Timer?
  private var activityStatus = CodexActivityStatus.unavailable

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength
    )
    self.statusItem = statusItem
    showLoadingState()

    let activityMonitor = CodexActivityMonitor { [weak self] status in
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
  }

  func applicationWillTerminate(_ notification: Notification) {
    refreshTimer?.invalidate()
    activityTimer?.invalidate()
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

    statusItem?.button?.title =
      "\(activityStatus.menuBarIcon) MiniGPT \(snapshot.session5Hour.remainingPercent)% · ↻ "
      + relativeTime(until: snapshot.session5Hour.resetsAt)

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self

    menu.addItem(labelItem(title: "👤 \(snapshot.email ?? "Không rõ")"))
    menu.addItem(labelItem(title: activityStatus.menuTitle))
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
    statusItem?.button?.title = "⚪️ MiniGPT · Đang tải…"

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

    statusItem?.button?.title = "⚪️ MiniGPT · Không có dữ liệu"

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
