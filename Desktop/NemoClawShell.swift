import AppKit
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
      return "Native dashboard shell with explicit lifecycle ownership."
    case .status:
      return "Granular control panel for start, stop, restart, and shell launch."
    }
  }

  var quitNote: String {
    switch self {
    case .desktop:
      return "Closing this window quits the app and stops the NemoClaw UI stack."
    case .status:
      return "Closing this control panel also starts shutdown for the NemoClaw UI stack."
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

  var needsDocumentsAccess: Bool {
    let documentsRoot = NSHomeDirectory() + "/Documents/"
    return launcherPath.hasPrefix(documentsRoot)
  }

  var permissionHint: String {
    "macOS will ask for Documents access because this launcher lives under Documents. Click Allow so the shell can run the local NemoClaw scripts."
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
      statusBundleIdentifier: statusBundleIdentifier
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
      return "Starting NemoClaw…"
    case .stop:
      return "Stopping NemoClaw…"
    case .restart:
      return "Restarting NemoClaw…"
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

enum LauncherCLI {
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

    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let rawOutput = String(decoding: data, as: UTF8.self)
    let output = sanitize(rawOutput)
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

  private static func sanitize(_ output: String) -> String {
    output
      .replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
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

@MainActor
final class ShellRuntime: ObservableObject {
  let configuration: ShellConfiguration

  @Published var serviceState: ServiceState = .checking
  @Published var isBusy = false
  @Published var lastSummary = "Checking NemoClaw…"
  @Published var lastOutput = ""
  @Published var lastUpdated = Date()
  @Published var reloadToken = UUID()

  private var pollTask: Task<Void, Never>?

  init(configuration: ShellConfiguration) {
    self.configuration = configuration
    startPolling()

    Task {
      if configuration.appMode == .desktop {
        await autoStartIfNeeded()
      } else {
        await refreshServiceState(forceReload: false)
      }
    }
  }

  deinit {
    pollTask?.cancel()
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

  func openInBrowser() {
    NSWorkspace.shared.open(configuration.dashboardURL)
  }

  func openDesktopShell() {
    NSWorkspace.shared.open(URL(fileURLWithPath: configuration.desktopAppPath))
  }

  func openStatusPanel() {
    NSWorkspace.shared.open(URL(fileURLWithPath: configuration.statusAppPath))
  }

  func quitApp() {
    NSApp.terminate(nil)
  }

  func reloadDashboard() {
    reloadToken = UUID()
  }

  private func autoStartIfNeeded() async {
    let reachable = await DashboardProbe.isReachable(configuration.dashboardURL)
    if reachable {
      serviceState = .running
      lastSummary = "NemoClaw is already running in the native shell."
      lastUpdated = Date()
      reloadToken = UUID()
      return
    }

    await perform(.start)
  }

  private func perform(_ action: ShellAction) async {
    guard !isBusy else {
      return
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
      serviceState = action == .stop ? .stopped : .checking
      if action != .stop {
        reloadToken = UUID()
      }
    } catch {
      serviceState = .failed(error.localizedDescription)
      lastSummary = error.localizedDescription
      lastOutput = error.localizedDescription
    }

    isBusy = false
    lastUpdated = Date()
    await refreshServiceState(forceReload: action != .stop)
  }

  private func startPolling() {
    pollTask = Task {
      while !Task.isCancelled {
        await refreshServiceState(forceReload: false)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  private func refreshServiceState(forceReload: Bool) async {
    let reachable = await DashboardProbe.isReachable(configuration.dashboardURL)

    if reachable {
      if !isBusy {
        serviceState = .running
        lastSummary = "Dashboard reachable at \(configuration.dashboardURL.absoluteString)"
      }
      if forceReload {
        reloadToken = UUID()
      }
    } else if !isBusy {
      switch serviceState {
      case .failed:
        break
      default:
        serviceState = .stopped
        lastSummary = configuration.appMode == .desktop
          ? "Shell is stopped. Press Start to bring the dashboard back."
          : "UI stack is stopped. Use Start or open the full shell."
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
      Text(bodyText.isEmpty ? "No recent launcher output." : bodyText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding(.top, 4)
    } label: {
      Text(title)
    }
  }
}

struct DashboardWebView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    webView.allowsMagnification = true
    webView.load(URLRequest(url: url))
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    if webView.url != url {
      webView.load(URLRequest(url: url))
    }
  }
}

struct EmptyDashboardView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: runtime.isBusy ? "arrow.triangle.2.circlepath" : "rectangle.dashed")
        .font(.system(size: 42, weight: .medium))
        .foregroundStyle(runtime.isBusy ? Color.blue : Color.secondary)
      Text(runtime.isBusy ? "Working on the UI stack…" : "Dashboard is not currently reachable")
        .font(.title3.weight(.semibold))
      Text(runtime.lastSummary)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
      if runtime.configuration.needsDocumentsAccess {
        Text(runtime.configuration.permissionHint)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 620)
      }
      HStack(spacing: 12) {
        Button("Start") { runtime.start() }
          .buttonStyle(.borderedProminent)
        Button("Restart") { runtime.restart() }
          .buttonStyle(.bordered)
        Button("Open In Browser") { runtime.openInBrowser() }
          .buttonStyle(.bordered)
      }
      DetailCard(title: "Recent Output", bodyText: runtime.lastOutput)
        .frame(maxWidth: 760)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(48)
  }
}

struct DesktopShellView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
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

        HStack(spacing: 12) {
          Button("Start") { runtime.start() }
            .buttonStyle(.borderedProminent)
          Button("Restart") { runtime.restart() }
            .buttonStyle(.bordered)
          Button("Stop") { runtime.stop() }
            .buttonStyle(.bordered)
          Button("Reload") { runtime.reloadDashboard() }
            .buttonStyle(.bordered)
          Button("Open In Browser") { runtime.openInBrowser() }
            .buttonStyle(.bordered)
          Button("Controls") { runtime.openStatusPanel() }
            .buttonStyle(.bordered)
          Spacer()
          Button("Quit") { runtime.quitApp() }
            .buttonStyle(.bordered)
        }

        HStack {
          Text(runtime.lastSummary)
            .foregroundStyle(.secondary)
          Spacer()
          Text("Updated \(runtime.lastUpdated, style: .time)")
            .foregroundStyle(.secondary)
        }

        if runtime.configuration.needsDocumentsAccess {
          Text(runtime.configuration.permissionHint)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(24)

      Divider()

      if runtime.serviceState == .running {
        DashboardWebView(url: runtime.configuration.dashboardURL)
          .id(runtime.reloadToken)
      } else {
        EmptyDashboardView()
      }
    }
    .frame(minWidth: 1120, minHeight: 760)
  }
}

struct StatusShellView: View {
  @EnvironmentObject private var runtime: ShellRuntime

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
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

      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          Text("Use the shell app for the embedded dashboard, or use this panel when you only want explicit controls.")
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            Button("Open Shell") { runtime.openDesktopShell() }
              .buttonStyle(.borderedProminent)
            Button("Open In Browser") { runtime.openInBrowser() }
              .buttonStyle(.bordered)
          }

          HStack(spacing: 12) {
            Button("Start") { runtime.start() }
              .buttonStyle(.bordered)
            Button("Restart") { runtime.restart() }
              .buttonStyle(.bordered)
            Button("Stop") { runtime.stop() }
              .buttonStyle(.bordered)
            Spacer()
            Button("Quit") { runtime.quitApp() }
              .buttonStyle(.bordered)
          }
        }
        .padding(.top, 4)
      } label: {
        Text("Quick Actions")
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text(runtime.lastSummary)
          Text(runtime.configuration.dashboardURL.absoluteString)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
          Text("Updated \(runtime.lastUpdated, style: .time)")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      } label: {
        Text("Live Status")
      }

      DetailCard(title: "Recent Output", bodyText: runtime.lastOutput)
    }
    .padding(24)
    .frame(minWidth: 560, minHeight: 460)
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
      if runtime.configuration.appMode == .desktop {
        Button("Open Controls") { runtime.openStatusPanel() }
      } else {
        Button("Open Shell") { runtime.openDesktopShell() }
      }
      Button("Open In Browser") { runtime.openInBrowser() }
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