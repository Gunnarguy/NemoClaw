import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit

enum ShellAppMode: String, Sendable {
  case desktop
  case status

  var title: String {
    switch self {
    case .desktop:
      return "NemoClaw"
    case .status:
      return "NemoClaw Status"
    }
  }

  var subtitle: String {
    switch self {
    case .desktop:
      return "Native NemoClaw workspace with overview, controls, and logs."
    case .status:
      return "Native control panel for lifecycle, status, and logs."
    }
  }

  var quitNote: String {
    switch self {
    case .desktop:
      return "Closing this app shuts down the local NemoClaw UI stack."
    case .status:
      return "Closing this control app also begins shutdown for the local NemoClaw UI stack."
    }
  }
}

struct ShellConfiguration: Sendable {
  let appMode: ShellAppMode
  let launcherPath: String
  let dashboardURL: URL
  let desktopAppPath: String
  let statusAppPath: String
  let desktopBundleIdentifier: String
  let statusBundleIdentifier: String
  let logDirectory: String

  var registryPath: String {
    (logDirectory as NSString).deletingLastPathComponent + "/sandboxes.json"
  }

  /// Returns true when at least one sandbox has been onboarded.
  func hasSandbox() -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sandboxes = json["sandboxes"] as? [String: Any] else {
      return false
    }
    return !sandboxes.isEmpty
  }

  var needsDocumentsAccess: Bool {
    let documentsRoot = NSHomeDirectory() + "/Documents/"
    return launcherPath.hasPrefix(documentsRoot)
  }

  var permissionHint: String {
    "macOS may prompt for Documents access because the NemoClaw repo lives under Documents. Click Allow so the native app can run the local launcher and read its logs."
  }

  static func load(bundle: Bundle = .main) -> ShellConfiguration {
    let info = bundle.infoDictionary ?? [:]
    let mode = ShellAppMode(rawValue: info["NemoClawAppMode"] as? String ?? "desktop") ?? .desktop
    let launcherPath = info["NemoClawLauncherPath"] as? String ?? ""
    let dashboardURLString = info["NemoClawDashboardURL"] as? String ?? "http://127.0.0.1:18789"
    let desktopAppPath = info["NemoClawDesktopAppPath"] as? String ?? (NSHomeDirectory() + "/Desktop/NemoClaw.app")
    let statusAppPath = info["NemoClawStatusAppPath"] as? String ?? (NSHomeDirectory() + "/Applications/NemoClaw Status.app")
    let desktopBundleIdentifier = info["NemoClawDesktopBundleIdentifier"] as? String ?? "local.nemoclaw.desktop"
    let statusBundleIdentifier = info["NemoClawStatusBundleIdentifier"] as? String ?? "local.nemoclaw.status"

    return ShellConfiguration(
      appMode: mode,
      launcherPath: launcherPath,
      dashboardURL: URL(string: dashboardURLString) ?? URL(string: "http://127.0.0.1:18789")!,
      desktopAppPath: desktopAppPath,
      statusAppPath: statusAppPath,
      desktopBundleIdentifier: desktopBundleIdentifier,
      statusBundleIdentifier: statusBundleIdentifier,
      logDirectory: NSHomeDirectory() + "/.nemoclaw/logs"
    )
  }
}

enum ShellAction: String, Sendable {
  case start = "--app-start"
  case stop = "--app-stop"
  case restart = "--app-restart"

  var title: String {
    switch self {
    case .start:
      return "Start"
    case .stop:
      return "Stop"
    case .restart:
      return "Restart"
    }
  }

  var progressText: String {
    switch self {
    case .start:
      return "Starting NemoClaw..."
    case .stop:
      return "Stopping NemoClaw..."
    case .restart:
      return "Restarting NemoClaw..."
    }
  }
}

enum ServiceState: Equatable {
  case checking
  case running
  case stopped
  case busy(String)
  case failed(String)

  var label: String {
    switch self {
    case .checking:
      return "Checking"
    case .running:
      return "Running"
    case .stopped:
      return "Stopped"
    case let .busy(text):
      return text
    case .failed:
      return "Error"
    }
  }

  var tint: Color {
    switch self {
    case .checking:
      return .orange
    case .running:
      return .green
    case .stopped:
      return .secondary
    case .busy:
      return .blue
    case .failed:
      return .red
    }
  }
}

enum LauncherExecutionError: LocalizedError {
  case missingLauncher(String)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case let .missingLauncher(path):
      return "Launcher script not found at \(path)."
    case let .commandFailed(message):
      return message
    }
  }
}

enum NativeTab: String, CaseIterable, Identifiable {
  case dashboard
  case overview
  case controls
  case logs

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dashboard:
      return "Web UI"
    case .overview:
      return "Overview"
    case .controls:
      return "Controls"
    case .logs:
      return "Logs"
    }
  }

  var symbol: String {
    switch self {
    case .dashboard:
      return "globe"
    case .overview:
      return "square.grid.2x2"
    case .controls:
      return "switch.2"
    case .logs:
      return "doc.text.magnifyingglass"
    }
  }
}

struct SandboxSummary: Codable, Identifiable, Sendable {
  let name: String
  let createdAt: String?
  let model: String?
  let nimContainer: String?
  let provider: String?
  let gpuEnabled: Bool?
  let policies: [String]?

  var id: String { name }
}

struct RegistrySnapshot: Codable, Sendable {
  let sandboxes: [String: SandboxSummary]
  let defaultSandbox: String?
}

struct GatewayInfo: Sendable {
  let name: String
  let server: String
  let isConnected: Bool

  static let unavailable = GatewayInfo(name: "Unavailable", server: "", isConnected: false)
}

struct ServiceSummary: Identifiable, Sendable {
  let name: String
  let isRunning: Bool
  let detail: String
  let logPath: String?

  var id: String { name }
}

struct NamedLog: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let path: String
  let content: String
}

struct OverviewSnapshot: Sendable {
  let dashboardReachable: Bool
  let gateway: GatewayInfo
  let sandboxes: [SandboxSummary]
  let defaultSandbox: String?
  let services: [ServiceSummary]
  let logs: [NamedLog]
  let tunnelURL: String?

  static let empty = OverviewSnapshot(
    dashboardReachable: false,
    gateway: .unavailable,
    sandboxes: [],
    defaultSandbox: nil,
    services: [],
    logs: [],
    tunnelURL: nil
  )

  var runningServiceCount: Int {
    services.filter { $0.isRunning }.count
  }

  var dashboardLabel: String {
    dashboardReachable ? "Reachable" : "Down"
  }

  var gatewayLabel: String {
    gateway.isConnected ? gateway.name : "Disconnected"
  }

  var summary: String {
    if dashboardReachable {
      return "Local NemoClaw dashboard is reachable."
    }
    if sandboxes.isEmpty {
      return "No sandbox is registered yet. Start NemoClaw to create or recover one."
    }
    return "The native app is live, but the forwarded dashboard is not reachable right now."
  }
}

enum CommandRunner {
  static func capture(_ command: String) -> String {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.standardOutput = pipe
    process.standardError = pipe

    var environment = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let basePath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = [
      home + "/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      basePath,
    ].joined(separator: ":")
    process.environment = environment

    do {
      try process.run()
    } catch {
      return ""
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum LauncherCLI {
  /// Maximum time (seconds) to wait for a launcher command before killing it.
  private static let timeoutSeconds: Double = 30

  static func run(_ action: ShellAction, configuration: ShellConfiguration, suppressBrowser: Bool = true) throws -> String {
    guard FileManager.default.fileExists(atPath: configuration.launcherPath) else {
      throw LauncherExecutionError.missingLauncher(configuration.launcherPath)
    }

    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [configuration.launcherPath, action.rawValue]

    var environment = ProcessInfo.processInfo.environment
    if suppressBrowser {
      environment["NEMOCLAW_OPEN_BROWSER"] = "0"
    }
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    // Prevent the child from blocking on interactive prompts
    process.standardInput = FileHandle.nullDevice

    try process.run()

    // Wait with a timeout so the GUI never freezes
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
    }
    if process.isRunning {
      process.terminate()
      throw LauncherExecutionError.commandFailed(
        "Launcher timed out after \(Int(timeoutSeconds))s. Run ./scripts/launch-macos.sh in Terminal instead."
      )
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard process.terminationStatus == 0 else {
      let message = output.isEmpty ? "Launcher exited with status \(process.terminationStatus)." : output
      throw LauncherExecutionError.commandFailed(message)
    }
    return output
  }

  static func stopForQuit(configuration: ShellConfiguration) {
    _ = try? run(.stop, configuration: configuration, suppressBrowser: true)

    if configuration.appMode == .status {
      terminateCompanionApp(bundleIdentifier: configuration.desktopBundleIdentifier)
    }
  }

  private static func terminateCompanionApp(bundleIdentifier: String) {
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    for app in runningApps where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      app.terminate()
    }
  }
}

enum DashboardProbe {
  static func isReachable(_ url: URL) async -> Bool {
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return false
      }
      return (200 ..< 400).contains(httpResponse.statusCode)
    } catch {
      return false
    }
  }
}

enum OverviewCollector {
  static func collect(configuration: ShellConfiguration, dashboardReachable: Bool) -> OverviewSnapshot {
    let registry = loadRegistry()
    let sandboxes = registry.sandboxes.values.sorted { lhs, rhs in
      if lhs.name == registry.defaultSandbox { return true }
      if rhs.name == registry.defaultSandbox { return false }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    let defaultSandbox = registry.defaultSandbox ?? sandboxes.first?.name
    let services = collectServices(defaultSandbox: defaultSandbox)
    let logs = collectLogs(configuration: configuration, defaultSandbox: defaultSandbox, services: services)

    return OverviewSnapshot(
      dashboardReachable: dashboardReachable,
      gateway: collectGateway(),
      sandboxes: sandboxes,
      defaultSandbox: defaultSandbox,
      services: services,
      logs: logs,
      tunnelURL: services.first(where: { $0.name == "cloudflared" && $0.isRunning })?.detail.hasPrefix("https://") == true ? services.first(where: { $0.name == "cloudflared" })?.detail : nil
    )
  }

  private static func loadRegistry() -> RegistrySnapshot {
    let registryPath = NSHomeDirectory() + "/.nemoclaw/sandboxes.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: registryPath)),
          let snapshot = try? JSONDecoder().decode(RegistrySnapshot.self, from: data) else {
      return RegistrySnapshot(sandboxes: [:], defaultSandbox: nil)
    }
    return snapshot
  }

  private static func collectGateway() -> GatewayInfo {
    let output = CommandRunner.capture("command -v openshell >/dev/null 2>&1 && openshell status 2>/dev/null || true")
    if output.isEmpty {
      return .unavailable
    }

    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let gateway = lines.first(where: { $0.hasPrefix("Gateway:") })?.replacingOccurrences(of: "Gateway:", with: "").trimmingCharacters(in: .whitespaces) ?? "Unavailable"
    let server = lines.first(where: { $0.hasPrefix("Server:") })?.replacingOccurrences(of: "Server:", with: "").trimmingCharacters(in: .whitespaces) ?? ""
    return GatewayInfo(name: gateway.isEmpty ? "Unavailable" : gateway, server: server, isConnected: !server.isEmpty)
  }

  private static func collectServices(defaultSandbox: String?) -> [ServiceSummary] {
    let sandboxName = defaultSandbox ?? "default"
    let pidDirectory = "/tmp/nemoclaw-services-\(sandboxName)"
    return [
      service(named: "telegram-bridge", pidDirectory: pidDirectory),
      service(named: "cloudflared", pidDirectory: pidDirectory),
    ]
  }

  private static func service(named name: String, pidDirectory: String) -> ServiceSummary {
    let pidPath = pidDirectory + "/\(name).pid"
    let logPath = pidDirectory + "/\(name).log"

    guard let rawPid = try? String(contentsOfFile: pidPath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let pid = Int32(rawPid),
      kill(pid, 0) == 0 else {
      return ServiceSummary(name: name, isRunning: false, detail: "stopped", logPath: FileManager.default.fileExists(atPath: logPath) ? logPath : nil)
    }

    if name == "cloudflared", let url = tunnelURL(from: logPath) {
      return ServiceSummary(name: name, isRunning: true, detail: url, logPath: logPath)
    }

    return ServiceSummary(name: name, isRunning: true, detail: "PID \(pid)", logPath: logPath)
  }

  private static func tunnelURL(from path: String) -> String? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return nil
    }
    let pattern = #"https://[a-z0-9-]*\.trycloudflare\.com"#
    let range = NSRange(location: 0, length: content.utf16.count)
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: content, options: [], range: range),
          let swiftRange = Range(match.range, in: content) else {
      return nil
    }
    return String(content[swiftRange])
  }

  private static func collectLogs(configuration: ShellConfiguration, defaultSandbox: String?, services: [ServiceSummary]) -> [NamedLog] {
    var logs: [NamedLog] = [
      log(id: "launcher", title: "Launcher", path: configuration.logDirectory + "/launcher.log"),
      log(id: "desktop", title: "Desktop App", path: configuration.logDirectory + "/desktop-app.log"),
      log(id: "status", title: "Status App", path: configuration.logDirectory + "/status-app.log"),
      log(id: "agent-error", title: "Launch Agent Errors", path: configuration.logDirectory + "/launch-agent.err.log"),
    ]

    if let defaultSandbox {
      let pidDirectory = "/tmp/nemoclaw-services-\(defaultSandbox)"
      logs.append(log(id: "telegram-service", title: "Telegram Bridge Service", path: pidDirectory + "/telegram-bridge.log"))
      logs.append(log(id: "cloudflared-service", title: "Cloudflared Service", path: pidDirectory + "/cloudflared.log"))
    }

    for service in services {
      if let path = service.logPath, !logs.contains(where: { $0.path == path }) {
        logs.append(log(id: service.name, title: service.name.capitalized, path: path))
      }
    }

    return logs.filter { FileManager.default.fileExists(atPath: $0.path) || !$0.content.isEmpty }
  }

  private static func log(id: String, title: String, path: String) -> NamedLog {
    NamedLog(id: id, title: title, path: path, content: tail(path: path, maxLines: 120))
  }

  private static func tail(path: String, maxLines: Int) -> String {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty else {
      return ""
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(maxLines).joined(separator: "\n")
  }
}

@MainActor
final class ShellRuntime: ObservableObject {
  let configuration: ShellConfiguration

  @Published var serviceState: ServiceState = .checking
  @Published var isBusy = false
  @Published var lastSummary = "Checking NemoClaw..."
  @Published var lastOutput = ""
  @Published var lastUpdated = Date()
  @Published var snapshot = OverviewSnapshot.empty
  @Published var selectedLogID = "launcher"

  private var pollTask: Task<Void, Never>?

  init(configuration: ShellConfiguration) {
    self.configuration = configuration
    startPolling()

    Task {
      if configuration.appMode == .desktop {
        await autoStartIfNeeded()
      } else {
        await refreshOverview()
      }
    }
  }

  deinit {
    pollTask?.cancel()
  }

  var selectedLog: NamedLog? {
    snapshot.logs.first(where: { $0.id == selectedLogID }) ?? snapshot.logs.first
  }

  func start() {
    Task { await perform(.start) }
  }

  func stop() {
    Task { await perform(.stop) }
  }

  func restart() {
    Task { await perform(.restart) }
  }

  func refreshNow() {
    Task { await refreshOverview() }
  }

  func openInBrowser() {
    NSWorkspace.shared.open(configuration.dashboardURL)
  }

  func openDesktopShell() {
    NSWorkspace.shared.open(URL(fileURLWithPath: configuration.desktopAppPath))
  }

  func openStatusPanel() {
    NSWorkspace.shared.open(URL(fileURLWithPath: configuration.statusAppPath))
  }

  func openLogDirectory() {
    NSWorkspace.shared.open(URL(fileURLWithPath: configuration.logDirectory))
  }

  func revealSelectedLog() {
    guard let selectedLog else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedLog.path)])
  }

  func quitApp() {
    NSApp.terminate(nil)
  }

  private func autoStartIfNeeded() async {
    let reachable = await DashboardProbe.isReachable(configuration.dashboardURL)
    if reachable {
      serviceState = .running
      lastSummary = "NemoClaw is already running."
      await refreshOverview()
      return
    }

    if !configuration.hasSandbox() {
      serviceState = .stopped
      lastSummary = "No sandbox found. Run \"./scripts/launch-macos.sh\" in Terminal first to complete onboarding."
      return
    }

    await perform(.start)
  }

  private func perform(_ action: ShellAction) async {
    guard !isBusy else {
      return
    }

    // The launcher script enters interactive onboarding when no sandbox
    // exists, which blocks forever in a GUI context. Fail fast instead.
    if action == .start || action == .restart {
      if !configuration.hasSandbox() {
        serviceState = .failed("No sandbox onboarded. Run ./scripts/launch-macos.sh in Terminal first.")
        lastSummary = "No sandbox onboarded. Run ./scripts/launch-macos.sh in Terminal first."
        return
      }
    }

    isBusy = true
    serviceState = .busy(action.progressText)
    lastSummary = action.progressText
    lastOutput = ""

    do {
      let configuration = self.configuration
      let output = try await Task.detached(priority: .userInitiated) {
        try LauncherCLI.run(action, configuration: configuration, suppressBrowser: true)
      }.value
      lastOutput = output
      lastSummary = output.isEmpty ? "\(action.title) completed." : output
    } catch {
      serviceState = .failed(error.localizedDescription)
      lastSummary = error.localizedDescription
      lastOutput = error.localizedDescription
    }

    isBusy = false
    lastUpdated = Date()
    await refreshOverview()
  }

  private func startPolling() {
    pollTask = Task {
      while !Task.isCancelled {
        await refreshOverview()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
      }
    }
  }

  private func refreshOverview() async {
    let reachable = await DashboardProbe.isReachable(configuration.dashboardURL)
    let configuration = self.configuration
    let collected = await Task.detached(priority: .utility) {
      OverviewCollector.collect(configuration: configuration, dashboardReachable: reachable)
    }.value

    snapshot = collected
    if selectedLogID.isEmpty || !snapshot.logs.contains(where: { $0.id == selectedLogID }) {
      selectedLogID = snapshot.logs.first?.id ?? "launcher"
    }

    if !isBusy {
      if collected.dashboardReachable {
        serviceState = .running
      } else if lastOutput.isEmpty {
        serviceState = .stopped
      }
      if case .failed = serviceState {
        // Preserve explicit failure state until the next successful action.
      } else {
        lastSummary = collected.summary
      }
    }

    lastUpdated = Date()
  }
}

struct StateBadge: View {
  let state: ServiceState

  var body: some View {
    Text(state.label)
      .font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(state.tint)
      .background(state.tint.opacity(0.14), in: Capsule())
  }
}

struct DetailCard: View {
  let title: String
  let bodyText: String

  var body: some View {
    GroupBox {
      Text(bodyText.isEmpty ? "No recent output." : bodyText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding(.top, 4)
    } label: {
      Text(title)
    }
  }
}

struct EmptyStateView: View {
  let title: String
  let message: String
  let symbol: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 36, weight: .medium))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

struct MetricCard: View {
  let title: String
  let value: String
  let detail: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.bold))
        .foregroundStyle(tint)
      Text(detail)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct SandboxRow: View {
  let sandbox: SandboxSummary
  let isDefault: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(sandbox.name)
          .font(.headline)
        if isDefault {
          Text("Default")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.blue)
            .background(Color.blue.opacity(0.12), in: Capsule())
        }
        Spacer()
        Text((sandbox.gpuEnabled ?? false) ? "GPU" : "CPU")
          .font(.caption.weight(.semibold))
          .foregroundStyle((sandbox.gpuEnabled ?? false) ? Color.green : Color.secondary)
      }

      Text("Model: \(sandbox.model ?? "unknown")")
        .foregroundStyle(.secondary)
      Text("Provider: \(sandbox.provider ?? "unknown")")
        .foregroundStyle(.secondary)
      Text("Policies: \((sandbox.policies ?? []).isEmpty ? "none" : (sandbox.policies ?? []).joined(separator: ", "))")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

struct ServiceRow: View {
  let service: ServiceSummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Circle()
        .fill(service.isRunning ? Color.green : Color.secondary)
        .frame(width: 10, height: 10)
        .padding(.top, 6)

      VStack(alignment: .leading, spacing: 4) {
        Text(service.name)
          .font(.headline)
        Text(service.detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 4)
  }
}

struct OverviewTabView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  private var snapshot: OverviewSnapshot { runtime.snapshot }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if runtime.configuration.needsDocumentsAccess {
          GroupBox {
            Text(runtime.configuration.permissionHint)
              .frame(maxWidth: .infinity, alignment: .leading)
          } label: {
            Text("Permissions")
          }
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
          MetricCard(
            title: "Dashboard",
            value: snapshot.dashboardLabel,
            detail: runtime.configuration.dashboardURL.absoluteString,
            tint: snapshot.dashboardReachable ? .green : .orange
          )
          MetricCard(
            title: "Gateway",
            value: snapshot.gatewayLabel,
            detail: snapshot.gateway.server.isEmpty ? "openshell status unavailable" : snapshot.gateway.server,
            tint: snapshot.gateway.isConnected ? .green : .orange
          )
          MetricCard(
            title: "Default Sandbox",
            value: snapshot.defaultSandbox ?? "None",
            detail: snapshot.sandboxes.isEmpty ? "No registered sandboxes" : "\(snapshot.sandboxes.count) registered",
            tint: snapshot.defaultSandbox == nil ? .orange : .blue
          )
          MetricCard(
            title: "Aux Services",
            value: "\(snapshot.runningServiceCount)/\(snapshot.services.count)",
            detail: snapshot.tunnelURL ?? "No public tunnel",
            tint: snapshot.runningServiceCount > 0 ? .green : .secondary
          )
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            if snapshot.sandboxes.isEmpty {
              Text("No sandboxes are registered yet. Use Start to recover or create the local sandbox and bring the UI stack online.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(snapshot.sandboxes) { sandbox in
                SandboxRow(sandbox: sandbox, isDefault: sandbox.name == snapshot.defaultSandbox)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        } label: {
          Text("Sandboxes")
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            if snapshot.services.isEmpty {
              Text("No auxiliary service state is available yet.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(snapshot.services) { service in
                ServiceRow(service: service)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        } label: {
          Text("Services")
        }

        DetailCard(title: "Last Launcher Output", bodyText: runtime.lastOutput)
      }
      .padding(20)
    }
  }
}

struct ControlsTabView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            Text("Run NemoClaw lifecycle actions directly from the native app.")
              .foregroundStyle(.secondary)

            HStack(spacing: 12) {
              Button("Start") { runtime.start() }
                .buttonStyle(.borderedProminent)
              Button("Restart") { runtime.restart() }
                .buttonStyle(.bordered)
              Button("Stop") { runtime.stop() }
                .buttonStyle(.bordered)
              Button("Refresh State") { runtime.refreshNow() }
                .buttonStyle(.bordered)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        } label: {
          Text("Lifecycle")
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            Text("Use the browser only when you want the forwarded dashboard explicitly. The native app remains the primary control surface.")
              .foregroundStyle(.secondary)

            HStack(spacing: 12) {
              Button("Open In Browser") { runtime.openInBrowser() }
                .buttonStyle(.bordered)
              if runtime.configuration.appMode == .desktop {
                Button("Open Controls") { runtime.openStatusPanel() }
                  .buttonStyle(.bordered)
              } else {
                Button("Open Full Shell") { runtime.openDesktopShell() }
                  .buttonStyle(.borderedProminent)
              }
              Button("Open Log Folder") { runtime.openLogDirectory() }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
              Button("Reveal Selected Log") { runtime.revealSelectedLog() }
                .buttonStyle(.bordered)
              Spacer()
              Button("Quit App") { runtime.quitApp() }
                .buttonStyle(.bordered)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        } label: {
          Text("Native App Actions")
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text(runtime.lastSummary)
            Text("Updated \(runtime.lastUpdated, style: .time)")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        } label: {
          Text("Current State")
        }

        DetailCard(title: "Last Action Output", bodyText: runtime.lastOutput)
      }
      .padding(20)
    }
  }
}

struct LogsTabView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Picker("Source", selection: $runtime.selectedLogID) {
          ForEach(runtime.snapshot.logs) { log in
            Text(log.title).tag(log.id)
          }
        }
        .pickerStyle(.menu)

        Button("Refresh") { runtime.refreshNow() }
          .buttonStyle(.bordered)
        Button("Reveal") { runtime.revealSelectedLog() }
          .buttonStyle(.bordered)
        Button("Open Log Folder") { runtime.openLogDirectory() }
          .buttonStyle(.bordered)
        Spacer()
      }

      if let selectedLog = runtime.selectedLog {
        Text(selectedLog.path)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)

        ScrollView {
          Text(selectedLog.content.isEmpty ? "No log output available." : selectedLog.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(16)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      } else {
        EmptyStateView(
          title: "No Logs Yet",
          message: "Start NemoClaw or open the log folder after the first run.",
          symbol: "doc.text.magnifyingglass"
        )
      }
    }
    .padding(20)
  }
}

struct DashboardWebView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView(frame: .zero)
    // Default to transparent so app background shows before loading
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    let request = URLRequest(url: url)
    webView.load(request)
  }
}

struct HeaderView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text(runtime.configuration.appMode.title)
            .font(.largeTitle.weight(.bold))
          Text(runtime.configuration.appMode.subtitle)
            .foregroundStyle(.secondary)
          Text(runtime.configuration.appMode.quitNote)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        StateBadge(state: runtime.serviceState)
      }

      HStack {
        Text(runtime.lastSummary)
          .foregroundStyle(.secondary)
        Spacer()
        Text("Updated \(runtime.lastUpdated, style: .time)")
          .foregroundStyle(.secondary)
      }
    }
    .padding(24)
  }
}

struct NativeShellTabs: View {
  @EnvironmentObject private var runtime: ShellRuntime
  @State private var selectedTab: NativeTab

  init(initialTab: NativeTab) {
    _selectedTab = State(initialValue: initialTab)
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      if runtime.configuration.appMode == .desktop {
        DashboardWebView(url: runtime.configuration.dashboardURL)
          .tabItem {
            Label(NativeTab.dashboard.title, systemImage: NativeTab.dashboard.symbol)
          }
          .tag(NativeTab.dashboard)
      }

      OverviewTabView()
        .tabItem {
          Label(NativeTab.overview.title, systemImage: NativeTab.overview.symbol)
        }
        .tag(NativeTab.overview)

      ControlsTabView()
        .tabItem {
          Label(NativeTab.controls.title, systemImage: NativeTab.controls.symbol)
        }
        .tag(NativeTab.controls)

      LogsTabView()
        .tabItem {
          Label(NativeTab.logs.title, systemImage: NativeTab.logs.symbol)
        }
        .tag(NativeTab.logs)
    }
  }
}

struct DesktopShellView: View {
  var body: some View {
    VStack(spacing: 0) {
      HeaderView()
      Divider()
      NativeShellTabs(initialTab: .dashboard)
    }
    .frame(minWidth: 1120, minHeight: 760)
  }
}

struct StatusShellView: View {
  var body: some View {
    VStack(spacing: 0) {
      HeaderView()
      Divider()
      NativeShellTabs(initialTab: .controls)
    }
    .frame(minWidth: 820, minHeight: 620)
  }
}

struct RootView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    Group {
      switch runtime.configuration.appMode {
      case .desktop:
        DesktopShellView()
      case .status:
        StatusShellView()
      }
    }
  }
}

final class ShellAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    LauncherCLI.stopForQuit(configuration: ShellConfiguration.load())
  }
}

struct ShellCommands: Commands {
  @ObservedObject var runtime: ShellRuntime

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
    }

    CommandMenu("NemoClaw") {
      Button("Start") { runtime.start() }
      Button("Restart") { runtime.restart() }
      Button("Stop") { runtime.stop() }
      Divider()
      Button("Refresh State") { runtime.refreshNow() }
      Button("Open In Browser") { runtime.openInBrowser() }
      if runtime.configuration.appMode == .desktop {
        Button("Open Controls") { runtime.openStatusPanel() }
      } else {
        Button("Open Full Shell") { runtime.openDesktopShell() }
      }
      Divider()
      Button("Quit") { runtime.quitApp() }
        .keyboardShortcut("q")
    }
  }
}

@main
struct NemoClawShellApp: App {
  @NSApplicationDelegateAdaptor(ShellAppDelegate.self) private var appDelegate
  @StateObject private var runtime = ShellRuntime(configuration: ShellConfiguration.load())

  var body: some Scene {
    WindowGroup(runtime.configuration.appMode.title) {
      RootView()
        .environmentObject(runtime)
    }
    .commands {
      ShellCommands(runtime: runtime)
    }
  }
}
