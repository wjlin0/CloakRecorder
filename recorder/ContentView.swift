import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers
import AVFoundation

// ==================== ViewModel ====================

@MainActor
final class RecorderVM: ObservableObject {
    @Published var content: SCShareableContent?
    @Published var windows: [SCWindow] = []
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var excluded: Set<CGWindowID> = []
    @Published var isRecording = false
    @Published var recordingStart: Date?
    @Published var recordingBaseSeconds: Double = 0
    @Published var status = "准备就绪"
    @Published var resolution = "1080p"
    @Published var fps = 30
    @Published var capturesAudio = false
    @Published var lastOutput: URL?
    @Published var searchText = ""
    @Published var recordings: [URL] = []
    @Published var bitratePreset = "中" { didSet { UserDefaults.standard.set(bitratePreset, forKey: "bitratePreset") } }
    @Published var customBitrateMbps: Double = 12 { didSet { UserDefaults.standard.set(customBitrateMbps, forKey: "customBitrateMbps") } }
    @Published var saveLocation: URL?

    private let engine = RecorderEngine()
    private var iconCache: [String: NSImage] = [:]

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "recordings") {
            recordings = saved.compactMap { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let p = UserDefaults.standard.string(forKey: "bitratePreset") { bitratePreset = p }
        let mb = UserDefaults.standard.double(forKey: "customBitrateMbps")
        if mb > 0 { customBitrateMbps = mb }
        if let p = UserDefaults.standard.string(forKey: "saveLocation") { saveLocation = URL(fileURLWithPath: p) }
    }

    func load() async {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.content = c
            self.displays = c.displays
            self.selectedDisplayID = c.displays.first?.displayID
            self.windows = c.windows.sorted {
                ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "")
            }
        } catch {
            self.status = "载入失败：\(error.localizedDescription)（需授予“屏幕录制”权限）"
        }
    }

    func icon(for app: SCRunningApplication?) -> NSImage? {
        guard let app else { return nil }
        let bid = app.bundleIdentifier
        let key = bid.isEmpty ? app.applicationName : bid
        if let cached = iconCache[key] { return cached }
        var img: NSImage?
        if !bid.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSRunningApplication(processIdentifier: app.processID)?.icon
        }
        iconCache[key] = img
        return img
    }

    private func matches(_ w: SCWindow, _ q: String) -> Bool {
        if q.isEmpty { return true }
        let app = w.owningApplication
        let hay = "\(app?.applicationName ?? "") \(app?.bundleIdentifier ?? "") \(w.title ?? "") \(w.windowID) \(app?.processID ?? 0)"
        return hay.lowercased().contains(q.lowercased())
    }

    var groupedWindows: [(app: String, icon: NSImage?, wins: [SCWindow])] {
        let filtered = windows.filter { matches($0, searchText) }
        let d = Dictionary(grouping: filtered) { $0.owningApplication?.applicationName ?? "未知" }
        return d.map { key, wins in
            (app: key, icon: icon(for: wins.first?.owningApplication), wins: wins)
        }.sorted { $0.app < $1.app }
    }

    func binding(for wid: CGWindowID) -> Binding<Bool> {
        Binding(get: { self.excluded.contains(wid) },
                set: { on in if on { self.excluded.insert(wid) } else { self.excluded.remove(wid) } })
    }

    /// 一键全选/取消某个 App 的所有窗口
    func appExcludeBinding(for wins: [SCWindow]) -> Binding<Bool> {
        let ids = wins.map(\.windowID)
        return Binding(
            get: { !ids.isEmpty && ids.allSatisfy { self.excluded.contains($0) } },
            set: { on in
                if on { ids.forEach { self.excluded.insert($0) } }
                else { ids.forEach { self.excluded.remove($0) } }
            }
        )
    }

    func clearExclusions() { excluded.removeAll() }

    // MARK: 记录
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func fileInfo(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let date = ((attrs?[.creationDate] as? Date).map(f.string) ?? "")
        return String(format: "%.1f MB · %@", Double(size) / 1_048_576, date)
    }

    func deleteRecording(_ url: URL, deleteFile: Bool) {
        if deleteFile { try? FileManager.default.removeItem(at: url) }
        recordings.removeAll { $0 == url }
        persistRecordings()
    }

    func clearRecordings() {
        recordings.removeAll()
        persistRecordings()
    }

    private func persistRecordings() {
        UserDefaults.standard.set(recordings.map { $0.path }, forKey: "recordings")
    }

    func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择此文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url
            UserDefaults.standard.set(url.path, forKey: "saveLocation")
        }
    }

    // MARK: 录制
    func start() {
        guard let id = selectedDisplayID, let display = displays.first(where: { $0.displayID == id }),
              let content else { return }
        // 已设置默认保存位置 → 直接按时间命名保存，不再弹窗
        if let loc = saveLocation, FileManager.default.fileExists(atPath: loc.path) {
            let url = loc.appendingPathComponent("录屏-\(Self.timestamp()).mov")
            Task { @MainActor [weak self] in
                await self?.beginRecording(display: display, content: content, url: url)
            }
            return
        }
        let panel = NSSavePanel()
        panel.title = "选择保存位置"
        panel.nameFieldStringValue = "录屏-\(Self.timestamp()).mov"
        panel.allowedContentTypes = [UTType.movie]
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.beginRecording(display: display, content: content, url: url)
            }
        }
    }

    private func beginRecording(display: SCDisplay, content: SCShareableContent, url: URL) async {
        let ex = content.windows.filter { excluded.contains($0.windowID) }
        let spec = buildQuality(display: display)
        engine.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        engine.onFinished = { [weak self] ok, msg, u in
            DispatchQueue.main.async {
                self?.status = ok ? "已保存：\(u?.lastPathComponent ?? "")" : "保存失败：\(msg)"
                self?.isRecording = false
                self?.recordingStart = nil
                if ok, let u, !(self?.recordings.contains(u) ?? true) {
                    self?.recordings.append(u)
                    self?.persistRecordings()
                }
            }
        }
        do {
            try await engine.start(display: display, excluding: ex, quality: spec, outputURL: url)
            isRecording = true
            recordingStart = Date()
            recordingBaseSeconds = 0
            status = "已排除 \(ex.count) 个窗口"
        } catch {
            status = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        engine.stop()
        status = "正在保存…"
    }

    // MARK: 续录（接着某条记录继续录制）
    struct VideoInfo {
        var width: Int
        var height: Int
        var fps: Int
        var hasAudio: Bool
        var bitrate: Int
        var duration: Double
    }

    /// 读取某条录像的尺寸 / 帧率 / 是否有音轨 / 估算码率，用于延续录制
    static func readVideoInfo(_ url: URL) async -> VideoInfo? {
        let asset = AVURLAsset(url: url)
        guard let vt = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let size = (try? await vt.load(.naturalSize)) ?? .zero
        let fps = (try? await vt.load(.nominalFrameRate)) ?? 30
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        let dur = (try? await asset.load(.duration)) ?? .zero
        let secs = CMTimeGetSeconds(dur)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let bitrate = secs > 0 ? max(2_000_000, Int(Double(bytes) * 8 / secs)) : 8_000_000
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let intFps = max(1, Int(fps.rounded()))
        return VideoInfo(width: w, height: h, fps: intFps, hasAudio: hasAudio, bitrate: bitrate, duration: secs)
    }

    /// 选一条已有录像，用同样的参数继续录制并拼接到其后
    func continueRecording(_ url: URL) {
        guard let content, let id = selectedDisplayID,
              let display = displays.first(where: { $0.displayID == id }) else {
            status = "未能取得屏幕内容，无法续录"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let info = await Self.readVideoInfo(url) else {
                self.status = "无法读取所选视频，无法续录"
                return
            }
            self.beginContinue(display: display, content: content, url: url, info: info)
        }
    }

    private func beginContinue(display: SCDisplay, content: SCShareableContent, url: URL, info: VideoInfo) {
        let ex = content.windows.filter { excluded.contains($0.windowID) }
        let spec = QualitySpec(width: info.width, height: info.height, fps: info.fps,
                               bitrate: info.bitrate, capturesAudio: info.hasAudio)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("续录-\(Self.timestamp()).mov")

        engine.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        engine.onFinished = { [weak self] ok, msg, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecording = false
                self.recordingStart = nil
                if ok {
                    self.status = "正在合并到原视频…"
                    Task { await self.finalizeContinue(original: url, segment: tempURL) }
                } else {
                    self.status = "续录失败：\(msg)"
                }
            }
        }

        Task { @MainActor [weak self] in
            do {
                try await self?.engine.start(display: display, excluding: ex, quality: spec, outputURL: tempURL)
                self?.isRecording = true
                self?.recordingStart = Date()
                self?.recordingBaseSeconds = info.duration
                self?.status = "续录中（延续 \(url.lastPathComponent)）"
            } catch {
                self?.status = "启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func finalizeContinue(original: URL, segment: URL) async {
        let mergedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("合并-\(Self.timestamp()).mov")
        do {
            try await RecorderEngine.concatenate(existing: original, segment: segment, to: mergedURL)
            _ = try FileManager.default.replaceItemAt(original, withItemAt: mergedURL)
            try? FileManager.default.removeItem(at: segment)
            status = "已续录完成：\(original.lastPathComponent)"
        } catch {
            // 合并失败时保留续录片段，避免数据丢失
            status = "合并失败（续录片段保留在 \(segment.lastPathComponent)）：\(error.localizedDescription)"
        }
    }

    private func buildQuality(display: SCDisplay) -> QualitySpec {
        let resMap: [String: Int] = ["720p": 1280, "1080p": 1920, "1440p": 2560, "原画": display.width]
        let targetW = min(resMap[resolution] ?? 1920, max(1, display.width))
        let targetH = max(1, display.height * targetW / max(1, display.width))
        let presetMap: [String: Int] = ["低": 4_000_000, "中": 8_000_000, "高": 16_000_000, "超高": 32_000_000]
        let bitrate = bitratePreset == "自定义" ? Int(customBitrateMbps * 1_000_000) : (presetMap[bitratePreset] ?? 8_000_000)
        return QualitySpec(width: targetW, height: targetH, fps: fps, bitrate: bitrate, capturesAudio: capturesAudio)
    }

    static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }

    // MARK: 更新检查
    struct GitHubRelease {
        var tag: String
        var name: String
        var body: String
        var htmlURL: URL?
        var dmgURL: URL?
    }

    @Published var updateStatus = "尚未检查更新"
    @Published var latestRelease: GitHubRelease?
    @Published var isCheckingUpdate = false

    static let repoOwner = "wjlin0"
    static let repoName = "CloakRecorder"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var hasUpdate: Bool {
        guard let tag = latestRelease?.tag else { return false }
        return Self.isNewer(Self.strippedVersion(tag), than: currentVersion)
    }

    func checkForUpdates() {
        isCheckingUpdate = true
        updateStatus = "正在检查更新…"
        let current = currentVersion
        Task {
            do {
                let rel = try await Self.fetchLatestRelease(owner: Self.repoOwner, repo: Self.repoName)
                await MainActor.run {
                    self.latestRelease = rel
                    self.isCheckingUpdate = false
                    let latest = Self.strippedVersion(rel.tag)
                    self.updateStatus = Self.isNewer(latest, than: current)
                        ? "发现新版本 \(latest)（当前 \(current)）"
                        : "已是最新版本 \(current)"
                }
            } catch {
                await MainActor.run {
                    self.isCheckingUpdate = false
                    self.updateStatus = "检查失败：\(error.localizedDescription)"
                }
            }
        }
    }

    static func strippedVersion(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
    }

    static func versionComponents(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespaces)
            .split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = versionComponents(a), bv = versionComponents(b)
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw NSError(domain: "Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "仓库地址无效"])
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CloakRecorder", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "获取最新版本失败"])
        }
        struct GHRelease: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: String }
            var tag_name: String
            var name: String
            var body: String?
            var html_url: String?
            var assets: [Asset]
        }
        let rel = try JSONDecoder().decode(GHRelease.self, from: data)
        let dmg = rel.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        return GitHubRelease(
            tag: rel.tag_name,
            name: rel.name,
            body: rel.body ?? "",
            htmlURL: rel.html_url.flatMap(URL.init(string:)),
            dmgURL: dmg.flatMap { URL(string: $0.browser_download_url) }
        )
    }
}

// ==================== 导航 ====================

enum Page: String, CaseIterable, Identifiable, Hashable {
    case record = "录制"
    case records = "录制记录"
    case guide = "指南"
    case about = "关于"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .record: return "record.circle"
        case .records: return "list.and.film"
        case .guide: return "questionmark.circle"
        case .about: return "info.circle"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = RecorderVM()
    @State private var page: Page? = .record

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases) { p in
                    Label(p.rawValue, systemImage: p.icon).tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            detail
        }
        .frame(minWidth: 940, minHeight: 580)
        .onAppear { Task { await vm.load() } }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .record: RecordView(vm: vm)
        case .records: RecordsView(vm: vm, onContinue: { url in
            page = .record
            vm.continueRecording(url)
        })
        case .guide: GuideView(vm: vm)
        case .about: AboutView(vm: vm)
        default: RecordView(vm: vm)
        }
    }
}

// ==================== 录制页 ====================

struct RecordView: View {
    @ObservedObject var vm: RecorderVM
    @State private var showExcludeList = true

    var body: some View {
        Group {
            if showExcludeList {
                HSplitView {
                    controlPanel.frame(minWidth: 280, idealWidth: 320, maxWidth: 520)
                    windowPane
                }
            } else {
                controlPanel
                    .frame(width: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("录制")
    }

    // 左：主操作 + 设置
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if vm.isRecording {
                Button { vm.stop() } label: {
                    Label("停止录制", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button { vm.start() } label: {
                    Label("开始录制", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }

            if vm.isRecording, let s = vm.recordingStart {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let t = Int(vm.recordingBaseSeconds) + Int(Date().timeIntervalSince(s))
                    let h = t / 3600, m = (t / 60) % 60, sec = t % 60
                    let text = h > 0
                        ? String(format: "%02d:%02d:%02d", h, m, sec)
                        : String(format: "%02d:%02d", m, sec)
                    Text(text)
                        .font(.system(size: 32, weight: .medium, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
            }

            Text(vm.status)
                .font(.callout).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)

            Divider()

            Text("录制设置").font(.headline)

            Picker("显示器", selection: $vm.selectedDisplayID) {
                ForEach(vm.displays, id: \.displayID) { d in
                    Text("\(d.width)×\(d.height)").tag(Optional(d.displayID))
                }
            }
            Picker("分辨率", selection: $vm.resolution) {
                ForEach(["原画", "1440p", "1080p", "720p"], id: \.self) { Text($0) }
            }
            Picker("帧率", selection: $vm.fps) {
                ForEach([60, 30, 24], id: \.self) { Text("\($0) fps") }
            }
            Picker("码率", selection: $vm.bitratePreset) {
                ForEach(["低", "中", "高", "超高", "自定义"], id: \.self) { Text($0) }
            }
            if vm.bitratePreset == "自定义" {
                HStack(spacing: 8) {
                    Slider(value: $vm.customBitrateMbps, in: 1...50, step: 1)
                    Text("\(Int(vm.customBitrateMbps)) Mbps")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 74, alignment: .trailing)
                }
            }
            Toggle("录制系统声音", isOn: $vm.capturesAudio)
            Toggle("显示排除窗口列表", isOn: $showExcludeList)

            VStack(alignment: .leading, spacing: 6) {
                Text("默认保存位置").font(.caption).foregroundColor(.secondary)
                HStack {
                    Text(vm.saveLocation.map { "自动保存到：\($0.path)" } ?? "未设置（每次录制时询问）")
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button("更改…") { vm.chooseSaveLocation() }.font(.caption)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // 右：排除窗口（次要）
    private var windowPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("排除窗口").font(.headline)
                Text(vm.excluded.isEmpty ? "" : "已排除 \(vm.excluded.count)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !vm.excluded.isEmpty {
                    Button("清空") { vm.clearExclusions() }.font(.caption)
                }
                Button { showExcludeList = false } label: {
                    Image(systemName: "sidebar.right")
                }.buttonStyle(.plain).help("收起排除窗口列表")
            }
            .padding(10)
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索 App / 标题 / PID / 窗口号", text: $vm.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(10)
            Divider()

            List {
                ForEach(vm.groupedWindows, id: \.app) { group in
                    Section(header: HStack(spacing: 6) {
                        Toggle("", isOn: vm.appExcludeBinding(for: group.wins))
                            .labelsHidden().toggleStyle(.checkbox)
                            .help("全选 / 取消此应用的所有窗口")
                        if let ic = group.icon {
                            Image(nsImage: ic).resizable().frame(width: 14, height: 14)
                        }
                        Text(group.app).font(.caption).bold()
                        if group.wins.count > 1 {
                            Text("\(group.wins.count)").font(.caption2).foregroundColor(.secondary)
                        }
                    }) {
                        ForEach(group.wins, id: \.windowID) { w in
                            Toggle(isOn: vm.binding(for: w.windowID)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.title?.isEmpty == false ? w.title! : "（无标题）")
                                        .font(.system(size: 13))
                                    Text("PID \(w.owningApplication?.processID ?? 0) · \(Int(w.frame.width))×\(Int(w.frame.height))")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 320)
    }
}

// ==================== 录制记录页 ====================

struct RecordsView: View {
    @ObservedObject var vm: RecorderVM
    var onContinue: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("录制记录").font(.title2).bold()
                Spacer()
                Button("清空记录") { vm.clearRecordings() }
            }
            .padding()
            Divider()
            if vm.recordings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.largeTitle).foregroundColor(.secondary)
                    Text("还没有录制记录").foregroundColor(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(vm.recordings.reversed(), id: \.self) { url in
                        RecordRow(url: url,
                                  info: vm.fileInfo(url),
                                  onReveal: { vm.reveal(url) },
                                  onContinue: { onContinue(url) },
                                  onDeleteRecord: { vm.deleteRecording(url, deleteFile: false) },
                                  onDeleteAll: { vm.deleteRecording(url, deleteFile: true) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("录制记录")
    }
}

struct RecordRow: View {
    let url: URL
    let info: String
    let onReveal: () -> Void
    let onContinue: () -> Void
    let onDeleteRecord: () -> Void
    let onDeleteAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").font(.title3).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.body)
                Text(info).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onContinue) {
                Label("继续录制", systemImage: "arrow.uturn.forward.circle").font(.caption)
            }.help("接着这条视频继续录制，拼接在其后")
            Button(action: onReveal) {
                Image(systemName: "arrow.right.circle").font(.title3)
            }.help("在访达中显示")
            Button(action: onDeleteRecord) {
                Label("仅删记录", systemImage: "trash").font(.caption)
            }.help("只从列表移除，保留视频文件")
            Button(action: onDeleteAll) {
                Label("连同视频删除", systemImage: "trash.fill").font(.caption)
            }.tint(.red).help("从列表移除并删除视频文件")
        }
        .padding(.vertical, 4)
    }
}

// ==================== 指南页 ====================

struct GuideView: View {
    @ObservedObject var vm: RecorderVM
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    private let xattrCommand = "xattr -cr \"/Applications/CloakRecorder.app\""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("① 录屏权限") {
                    HStack(spacing: 10) {
                        Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(hasPermission ? .green : .orange)
                        Text(hasPermission ? "已获得录屏权限" : "尚未获得录屏权限")
                        Spacer()
                        Button(hasPermission ? "重新检测" : "去授权") {
                            if !hasPermission { CGRequestScreenCaptureAccess() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                hasPermission = CGPreflightScreenCaptureAccess()
                            }
                            Task { await vm.load() }
                        }.buttonStyle(.borderedProminent)
                    }
                    Text(hasPermission ? "" : "点击「去授权」会自动弹出系统授权弹窗；若没弹，去 系统设置 → 隐私与安全性 → 录屏与系统录音 手动勾选 CloakRecorder，然后回到本页点「重新检测」。")
                        .font(.callout).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("② 从 GitHub 下载后打不开（未签名）") {
                    VStack(alignment: .leading, spacing: 10) {
                        guideStep("1、右键点击 CloakRecorder.app → 选择「打开」→ 弹窗里再点一次「打开」。")
                        guideStep("2、或打开终端，执行下面这条命令后即可正常打开：")
                        HStack(spacing: 8) {
                            Text(xattrCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(6)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(xattrCommand, forType: .string)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }.help("复制命令")
                        }
                        guideStep("3、或到 系统设置 → 隐私与安全性 → 底部点「仍要打开」。")
                    }
                    Text("提示：发布时至少要用本仓库构建脚本做一次 ad-hoc 签名（codesign -s -），否则 Apple Silicon 上会直接拒绝运行。脚本已内置该步骤。")
                        .font(.callout).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("③ 使用提示") {
                    guideStep("勾选「排除」的窗口，在录制画面里会变成透明的洞（露出桌面），不会被录进去。")
                    guideStep("想连 CloakRecorder 自己的窗口一起隐藏，在录制页把它也勾上。")
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .navigationTitle("指南")
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }

    private func guideStep(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// ==================== 关于 / 更新页 ====================

struct AboutView: View {
    @ObservedObject var vm: RecorderVM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                Divider()
                updateSection
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .navigationTitle("关于")
        .onAppear { vm.checkForUpdates() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let ic = NSApplication.shared.applicationIconImage {
                Image(nsImage: ic).resizable().frame(width: 64, height: 64)
            } else {
                Image(systemName: "record.circle").font(.system(size: 56)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("CloakRecorder 录屏隐身").font(.title).bold()
                Text("版本 \(vm.currentVersion)").font(.callout).foregroundColor(.secondary)
                Text("基于 ScreenCaptureKit 的 macOS 录屏工具，可排除指定窗口，让它们不出现在画面里。")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检查更新").font(.headline)

            HStack(spacing: 12) {
                Button {
                    vm.checkForUpdates()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isCheckingUpdate)

                if vm.isCheckingUpdate { ProgressView().controlSize(.small) }

                Button {
                    if let u = URL(string: "https://github.com/\(RecorderVM.repoOwner)/\(RecorderVM.repoName)") {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Label("GitHub 仓库", systemImage: "link")
                }
            }

            Text(vm.updateStatus).font(.callout).foregroundColor(.secondary)

            if let rel = vm.latestRelease {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("最新版本 \(RecorderVM.strippedVersion(rel.tag))")
                        .font(.subheadline).bold()

                    if vm.hasUpdate, let dmg = rel.dmgURL {
                        Button {
                            NSWorkspace.shared.open(dmg)
                        } label: {
                            Label("下载 \(dmg.lastPathComponent)", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("在浏览器中下载新版 DMG")
                    }

                    if !rel.body.isEmpty {
                        Text("更新记录").font(.headline).padding(.top, 4)
                        Text(rel.body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()
            Text("本软件基于 MIT 协议开源。").font(.caption).foregroundColor(.secondary)
        }
    }
}