import Foundation
import SQLite3

enum CodexActivityStatus: Equatable, Sendable {
  case running
  case needsConfirmation
  case completed
  case unavailable

  var menuBarIcon: String {
    switch self {
    case .running: "⚙️"
    case .needsConfirmation: "🔐"
    case .completed: "✅"
    case .unavailable: "💤"
    }
  }

  var menuTitle: String {
    switch self {
    case .running: "⚙️ Codex đang chạy"
    case .needsConfirmation: "🔐 Codex cần cấp quyền"
    case .completed: "✅ Codex đã chạy xong"
    case .unavailable: "💤 Chưa tìm thấy phiên Codex"
    }
  }
}

final class CodexActivityMonitor: @unchecked Sendable {
  private enum ConfirmationKind {
    case permission(Date)
    case userInput
  }

  private let queue = DispatchQueue(label: "ChatBMK.CodexActivityMonitor")
  private let onStatus: @MainActor @Sendable (CodexActivityStatus) -> Void
  private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private var activeRolloutURL: URL?
  private var readOffset: UInt64 = 0
  private var incompleteLine = Data()
  private var lifecycleStatus = CodexActivityStatus.unavailable
  private var pendingConfirmations: [String: ConfirmationKind] = [:]
  private var lastStatus: CodexActivityStatus?
  private var isRefreshing = false

  init(onStatus: @escaping @MainActor @Sendable (CodexActivityStatus) -> Void) {
    self.onStatus = onStatus
  }

  func refresh() {
    queue.async { [weak self] in
      guard let self, !self.isRefreshing else { return }
      self.isRefreshing = true
      let status = self.detectStatus()
      self.isRefreshing = false

      guard status != self.lastStatus else { return }
      self.lastStatus = status
      let onStatus = self.onStatus
      Task { @MainActor in
        onStatus(status)
      }
    }
  }

  private func detectStatus() -> CodexActivityStatus {
    guard let rolloutURL = latestRolloutURL() else {
      return .unavailable
    }

    if activeRolloutURL != rolloutURL {
      activeRolloutURL = rolloutURL
      readOffset = 0
      incompleteLine.removeAll(keepingCapacity: true)
      lifecycleStatus = .unavailable
      pendingConfirmations.removeAll()
    }

    guard let newData = try? readNewData(of: rolloutURL) else {
      return .unavailable
    }
    parse(newData)

    guard lifecycleStatus == .running else {
      return lifecycleStatus
    }

    let threadID = rolloutURL.deletingPathExtension().lastPathComponent.suffix(36)
    let lastApprovalAt = latestApprovalDate(threadID: String(threadID))
    let isWaiting = pendingConfirmations.values.contains { confirmation in
      switch confirmation {
      case .userInput:
        return true
      case .permission(let requestedAt):
        guard let lastApprovalAt else { return true }
        return lastApprovalAt < requestedAt
      }
    }

    return isWaiting ? .needsConfirmation : .running
  }

  private func parse(_ newData: Data) {
    var data = incompleteLine
    data.append(newData)
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    incompleteLine = data.last == 0x0A
      ? Data()
      : (lines.last.map { Data($0) } ?? Data())

    for line in lines.dropLast() where !line.isEmpty {
      parseLine(Data(line))
    }
  }

  private func parseLine(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line),
      let event = object as? [String: Any],
      let payload = event["payload"] as? [String: Any],
      let payloadType = payload["type"] as? String
    else {
      return
    }

    switch payloadType {
    case "task_started":
      lifecycleStatus = .running
      pendingConfirmations.removeAll()
    case "task_complete":
      lifecycleStatus = .completed
      pendingConfirmations.removeAll()
    case "custom_tool_call" where lifecycleStatus == .running:
      guard let callID = payload["call_id"] as? String,
        let input = payload["input"] as? String,
        let confirmation = confirmationKind(
          toolName: payload["name"] as? String,
          input: input,
          timestamp: event["timestamp"] as? String
        )
      else {
        return
      }
      pendingConfirmations[callID] = confirmation
    case "custom_tool_call_output":
      if let callID = payload["call_id"] as? String {
        pendingConfirmations.removeValue(forKey: callID)
      }
    default:
      break
    }
  }

  private func confirmationKind(
    toolName: String?,
    input: String,
    timestamp: String?
  ) -> ConfirmationKind? {
    if input.contains("tools.request_user_input") || toolName == "request_user_input" {
      return .userInput
    }

    let pattern = #""sandbox_permissions"\s*:\s*"require_escalated""#
    guard input.range(of: pattern, options: .regularExpression) != nil,
      let timestamp,
      let requestedAt = timestampFormatter.date(from: timestamp)
    else {
      return nil
    }
    return .permission(requestedAt)
  }

  private func latestApprovalDate(threadID: String) -> Date? {
    let databaseURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/logs_2.sqlite")
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      if database != nil { sqlite3_close(database) }
      return nil
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 50)

    let sql = """
      SELECT ts, ts_nanos
      FROM logs
      WHERE thread_id = ?
        AND target = 'codex_core::session::handlers'
        AND feedback_log_body LIKE '%op: ExecApproval %'
      ORDER BY ts DESC, ts_nanos DESC
      LIMIT 1
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      return nil
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, threadID, -1, transient)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    let seconds = TimeInterval(sqlite3_column_int64(statement, 0))
    let nanoseconds = TimeInterval(sqlite3_column_int64(statement, 1)) / 1_000_000_000
    return Date(timeIntervalSince1970: seconds + nanoseconds)
  }

  private func latestRolloutURL() -> URL? {
    let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"

    let dates = [Date(), Calendar.current.date(byAdding: .day, value: -1, to: Date())]
      .compactMap { $0 }
    var latest: (url: URL, modifiedAt: Date)?

    for date in dates {
      let directory = sessionsURL.appendingPathComponent(
        formatter.string(from: date),
        isDirectory: true
      )
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )

      for url in urls ?? [] where url.pathExtension == "jsonl" {
        guard let values = try? url.resourceValues(
          forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
          values.isRegularFile == true,
          let modifiedAt = values.contentModificationDate
        else {
          continue
        }

        if latest == nil || modifiedAt > latest!.modifiedAt {
          latest = (url, modifiedAt)
        }
      }
    }

    return latest?.url
  }

  private func readNewData(of url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let fileSize = try handle.seekToEnd()
    if fileSize < readOffset {
      readOffset = 0
      incompleteLine.removeAll(keepingCapacity: true)
      lifecycleStatus = .unavailable
      pendingConfirmations.removeAll()
    }

    try handle.seek(toOffset: readOffset)
    let data = try handle.readToEnd() ?? Data()
    readOffset = fileSize
    return data
  }
}
