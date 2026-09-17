import Foundation

struct UsageWindow: Sendable {
  let remainingPercent: Int
  let resetsAt: Date?
}

struct CodexUsageSnapshot: Sendable {
  let email: String?
  let session5Hour: UsageWindow
  let weekly: UsageWindow
}

enum CodexClientError: LocalizedError {
  case codexNotFound

  var errorDescription: String? {
    switch self {
    case .codexNotFound:
      "Không tìm thấy Codex CLI. Hãy cài Codex rồi chạy codex để đăng nhập."
    }
  }
}

final class CodexAppServerClient: @unchecked Sendable {
  private enum RequestKind {
    case initialize
    case account
    case rateLimits
  }

  private let queue = DispatchQueue(label: "ChatBMK.CodexAppServerClient")
  private let onSnapshot: @MainActor @Sendable (CodexUsageSnapshot) -> Void
  private let onError: @MainActor @Sendable (String) -> Void

  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputBuffer = Data()
  private var pendingRequests: [Int: RequestKind] = [:]
  private var nextRequestID = 1
  private var isInitialized = false
  private var isStopping = false

  private var latestEmail: String?
  private var latestSession: UsageWindow?
  private var latestWeekly: UsageWindow?

  init(
    onSnapshot: @escaping @MainActor @Sendable (CodexUsageSnapshot) -> Void,
    onError: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.onSnapshot = onSnapshot
    self.onError = onError
  }

  func start() throws {
    let executableURL = try Self.findCodexExecutable()
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    process.executableURL = executableURL
    process.arguments = ["app-server", "--listen", "stdio://"]
    process.environment = Self.processEnvironment(for: executableURL)
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.queue.async { [weak self] in
        self?.consumeOutput(data)
      }
    }

    // App-server có thể ghi cảnh báo vào stderr; luôn đọc để tránh đầy pipe.
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }

    process.terminationHandler = { [weak self] process in
      self?.queue.async { [weak self] in
        guard let self, !self.isStopping else { return }
        self.publishError("Codex app-server đã dừng (mã \(process.terminationStatus)).")
      }
    }

    self.process = process
    self.inputPipe = inputPipe
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    isStopping = false

    try process.run()

    queue.async { [weak self] in
      self?.sendRequest(
        kind: .initialize,
        method: "initialize",
        params: [
          "clientInfo": [
            "name": "MiniGPTMenuBar",
            "version": "0.1.3",
          ],
          "capabilities": ["experimentalApi": true],
        ]
      )
    }
  }

  func refresh() {
    queue.async { [weak self] in
      guard let self, self.isInitialized else { return }
      self.requestLatestData()
    }
  }

  func stop() {
    queue.sync {
      isStopping = true
      outputPipe?.fileHandleForReading.readabilityHandler = nil
      errorPipe?.fileHandleForReading.readabilityHandler = nil
      try? inputPipe?.fileHandleForWriting.close()
      process?.terminationHandler = nil
      if process?.isRunning == true {
        process?.terminate()
      }
      process = nil
      inputPipe = nil
      outputPipe = nil
      errorPipe = nil
    }
  }

  private func requestLatestData() {
    sendRequest(
      kind: .account,
      method: "account/read",
      params: ["refreshToken": false]
    )
    sendRequest(kind: .rateLimits, method: "account/rateLimits/read", params: NSNull())
  }

  private func sendRequest(kind: RequestKind, method: String, params: Any) {
    let requestID = nextRequestID
    nextRequestID += 1
    pendingRequests[requestID] = kind

    let request: [String: Any] = [
      "id": requestID,
      "method": method,
      "params": params,
    ]

    do {
      var data = try JSONSerialization.data(withJSONObject: request)
      data.append(0x0A)
      try inputPipe?.fileHandleForWriting.write(contentsOf: data)
    } catch {
      pendingRequests.removeValue(forKey: requestID)
      publishError("Không gửi được yêu cầu tới Codex: \(error.localizedDescription)")
    }
  }

  private func consumeOutput(_ data: Data) {
    outputBuffer.append(data)

    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }

      do {
        let object = try JSONSerialization.jsonObject(with: Data(line))
        guard let message = object as? [String: Any] else { continue }
        handleMessage(message)
      } catch {
        publishError("Codex trả về dữ liệu không hợp lệ.")
      }
    }
  }

  private func handleMessage(_ message: [String: Any]) {
    if message["method"] as? String == "account/rateLimits/updated",
      let params = message["params"] as? [String: Any],
      let rateLimits = params["rateLimits"] as? [String: Any]
    {
      parseRateLimits(rateLimits)
      publishSnapshotIfReady()
      return
    }

    guard let requestID = (message["id"] as? NSNumber)?.intValue,
      let kind = pendingRequests.removeValue(forKey: requestID)
    else {
      return
    }

    if let error = message["error"] as? [String: Any] {
      let detail = error["message"] as? String ?? "Lỗi không xác định"
      publishError("Codex: \(detail)")
      return
    }

    guard let result = message["result"] as? [String: Any] else { return }

    switch kind {
    case .initialize:
      isInitialized = true
      requestLatestData()
    case .account:
      parseAccount(result)
      publishSnapshotIfReady()
    case .rateLimits:
      guard let rateLimits = result["rateLimits"] as? [String: Any] else {
        publishError("Tài khoản chưa có thông tin hạn mức Codex.")
        return
      }
      parseRateLimits(rateLimits)
      publishSnapshotIfReady()
    }
  }

  private func parseAccount(_ result: [String: Any]) {
    guard let account = result["account"] as? [String: Any] else {
      publishError("Codex CLI chưa đăng nhập ChatGPT.")
      return
    }

    latestEmail = account["email"] as? String
  }

  private func parseRateLimits(_ rateLimits: [String: Any]) {
    latestSession = parseWindow(rateLimits["primary"])
    latestWeekly = parseWindow(rateLimits["secondary"])
  }

  private func parseWindow(_ value: Any?) -> UsageWindow? {
    guard let window = value as? [String: Any],
      let usedPercent = (window["usedPercent"] as? NSNumber)?.intValue
    else {
      return nil
    }

    let remainingPercent = min(100, max(0, 100 - usedPercent))
    let resetsAt = (window["resetsAt"] as? NSNumber).map {
      Date(timeIntervalSince1970: $0.doubleValue)
    }
    return UsageWindow(remainingPercent: remainingPercent, resetsAt: resetsAt)
  }

  private func publishSnapshotIfReady() {
    guard let latestSession, let latestWeekly else { return }

    let snapshot = CodexUsageSnapshot(
      email: latestEmail,
      session5Hour: latestSession,
      weekly: latestWeekly
    )
    let onSnapshot = onSnapshot
    Task { @MainActor in
      onSnapshot(snapshot)
    }
  }

  private func publishError(_ message: String) {
    let onError = onError
    Task { @MainActor in
      onError(message)
    }
  }

  private static func findCodexExecutable() throws -> URL {
    let candidates = executableSearchDirectories().map { "\($0)/codex" }

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    throw CodexClientError.codexNotFound
  }

  private static func processEnvironment(for executableURL: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let executableDirectory = executableURL.deletingLastPathComponent().path
    let directories = uniqueDirectories(
      [executableDirectory] + executableSearchDirectories()
    )
    environment["PATH"] = directories.joined(separator: ":")
    return environment
  }

  private static func executableSearchDirectories() -> [String] {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser
    let environmentDirectories = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":")
      .map(String.init) ?? []
    let commonDirectories = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      homeURL.appendingPathComponent(".local/bin").path,
      homeURL.appendingPathComponent(".npm-global/bin").path,
      homeURL.appendingPathComponent(".bun/bin").path,
      homeURL.appendingPathComponent(".volta/bin").path,
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]

    let nvmVersionsURL = homeURL.appendingPathComponent(".nvm/versions/node")
    let nvmDirectories = (try? FileManager.default.contentsOfDirectory(
      at: nvmVersionsURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ))?.map { $0.appendingPathComponent("bin").path } ?? []

    return uniqueDirectories(environmentDirectories + commonDirectories + nvmDirectories)
  }

  private static func uniqueDirectories(_ directories: [String]) -> [String] {
    var seen = Set<String>()
    return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}
