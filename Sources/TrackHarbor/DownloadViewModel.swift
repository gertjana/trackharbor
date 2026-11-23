import AppKit
import Foundation

enum TrackState {
    case waiting
    case downloading
    case succeeded
    case unavailable
    case downloadFailed
    case conversionFailed

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .downloading: "Downloading"
        case .succeeded: "Succeeded"
        case .unavailable: "Not found"
        case .downloadFailed: "Download failed"
        case .conversionFailed: "Conversion failed"
        }
    }

    var icon: String {
        switch self {
        case .waiting: "circle"
        case .downloading: "arrow.down.circle"
        case .succeeded: "checkmark.circle.fill"
        case .unavailable: "questionmark.circle"
        case .downloadFailed, .conversionFailed: "xmark.circle"
        }
    }
}

struct TrackProgress: Identifiable {
    let id = UUID()
    var title: String
    var state: TrackState = .waiting
    var detail = ""
}

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var spotifyURL = ""
    @Published var outputDirectory = "~/Music/TrackHarbor"
    @Published var usePlaylistSubdirectory = false
    @Published private(set) var progress = 0.0
    @Published private(set) var progressMessage = "Ready to download."
    @Published private(set) var statusTitle = "Ready"
    @Published private(set) var statusIcon = "checkmark.circle"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var tracks: [TrackProgress] = []

    private var task: Task<Void, Never>?
    private var process: Process?
    private var currentTrackIndex: Int?
    private var expectedTrackCount: Int?
    private var outputLines: [String] = []

    var canRetry: Bool {
        !isRunning && tracks.contains {
            $0.state == .unavailable || $0.state == .downloadFailed || $0.state == .conversionFailed
        }
    }

    deinit {
        task?.cancel()
        process?.terminate()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    func pasteSpotifyURL() {
        if let clipboardText = NSPasteboard.general.string(forType: .string) {
            spotifyURL = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func resetForNewURL() {
        guard !isRunning else { return }
        tracks = []
        progress = 0
        progressMessage = "Ready to download."
        statusTitle = "Ready"
        statusIcon = "checkmark.circle"
        errorMessage = nil
        currentTrackIndex = nil
        expectedTrackCount = nil
    }

    func startDownload() {
        guard !isRunning else { return }
        errorMessage = nil
        guard isValidURL else {
            statusTitle = "Check the playlist URL"
            statusIcon = "exclamationmark.triangle"
            errorMessage = "Paste a Spotify playlist or album URL beginning with https://open.spotify.com/."
            return
        }
        let directory = expandedDirectory
        guard !directory.isEmpty else {
            statusTitle = "Choose a download folder"
            statusIcon = "exclamationmark.triangle"
            errorMessage = "The download folder cannot be empty."
            return
        }

        isRunning = true
        statusTitle = "Preparing download"
        statusIcon = "arrow.down.circle"
        progress = 0
        progressMessage = "Checking spotdl and creating the download folder…"
        tracks = []
        currentTrackIndex = nil
        expectedTrackCount = nil
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(url: spotifyURL.trimmingCharacters(in: .whitespacesAndNewlines), directory: directory)
        }
    }

    func cancelDownload() {
        process?.terminate()
        task?.cancel()
        finish(title: "Cancelled", icon: "xmark.circle", message: "The download was cancelled.", error: nil)
    }

    private func run(url: String, directory: String) async {
        do {
            update(title: "Setting up TrackHarbor", icon: "gearshape", message: "Preparing the managed downloader environment…", progress: 0)
            let tools = try await RuntimeManager.ensure()
            update(title: "Reading playlist", icon: "music.note.list", message: "Extracting songs from Spotify…", progress: 0)
            tracks = try await extractTracks(executable: tools.spotdl, environment: tools.environment, url: url)
            expectedTrackCount = tracks.count
            guard !tracks.isEmpty else {
                throw DownloadError.processFailed("No songs were found in this playlist.")
            }
            let destination = try await destinationDirectory(baseDirectory: directory, url: url)
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

            for attempt in 1...3 {
                if Task.isCancelled { return }
                update(title: attempt == 1 ? "Downloading playlist" : "Retrying download (\(attempt)/3)", icon: "arrow.down.circle", message: "Attempt \(attempt) of 3", progress: attempt == 1 ? 0 : progress)
                do {
                    outputLines = []
                    _ = try await executeSpotdl(executable: tools.spotdl, environment: tools.environment, ffmpeg: tools.ffmpeg, url: url, directory: destination)
                    if let expectedTrackCount,
                       tracks.count >= expectedTrackCount,
                       tracks.contains(where: { $0.state != .succeeded }) {
                        throw DownloadError.processFailed("spotdl finished before every song was downloaded and converted.")
                    }
                    finish(title: "Download complete", icon: "checkmark.circle.fill", message: "Your music is ready in \(destination)", error: nil)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if attempt < 3 {
                        resetUnfinishedTracks()
                        update(title: "A song failed", icon: "arrow.clockwise.circle", message: "Retrying automatically…", progress: progress)
                    }
                }
            }
            finalizeUnfinishedTracks()
            finish(title: "Download finished with errors", icon: "exclamationmark.triangle", message: trackSummary, error: trackSummary)
        } catch is CancellationError {
            return
        } catch {
            finish(title: "Could not start download", icon: "xmark.circle", message: "Fix the issue below and try again.", error: error.localizedDescription)
        }
    }

    private func executeSpotdl(executable: String, environment: [String: String], ffmpeg: String, url: String, directory: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["download", url, "--output", directory, "--format", "mp3", "--bitrate", "320k", "--ffmpeg", ffmpeg, "--overwrite", "skip", "--simple-tui", "--print-errors"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = environment
        self.process = process

        let outputTask = Task { [weak self] in
            var buffer = ""
            for try await byte in pipe.fileHandleForReading.bytes {
                if Task.isCancelled { break }
                if byte == 10 || byte == 13 {
                    if !buffer.isEmpty {
                        await self?.consume(line: buffer)
                        buffer = ""
                    }
                } else {
                    buffer.append(Character(UnicodeScalar(byte)))
                }
            }
            if !buffer.isEmpty {
                await self?.consume(line: buffer)
            }
        }
        try process.run()
        let terminationStatus = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }
        _ = try? await outputTask.value
        self.process = nil
        let output = outputLines.joined(separator: "\n")
        guard terminationStatus == 0 else {
            throw DownloadError.processFailed(output.isEmpty ? "spotdl exited with code \(terminationStatus)." : output.suffix(1200).description)
        }
        return output
    }

    private func extractTracks(executable: String, environment: [String: String], url: String) async throws -> [TrackProgress] {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotdl-\(UUID().uuidString).spotdl")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        let output = try await executeCommand(
            executable: executable,
            arguments: ["save", url, "--save-file", metadataURL.path],
            environment: environment
        )
        guard let data = try? Data(contentsOf: metadataURL),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.processFailed(output.isEmpty ? "spotdl did not return playlist metadata." : output)
        }
        return records.compactMap { record in
            let name = (record["name"] as? String) ?? (record["title"] as? String)
            guard let name, !name.isEmpty else { return nil }
            let artist = (record["artist"] as? String)
                ?? (record["artists"] as? [String])?.joined(separator: ", ")
                ?? ""
            return TrackProgress(title: artist.isEmpty ? name : "\(artist) - \(name)")
        }
    }

    private func destinationDirectory(baseDirectory: String, url: String) async throws -> String {
        guard usePlaylistSubdirectory else { return baseDirectory }
        update(title: "Preparing destination", icon: "folder", message: "Reading the playlist or album title…", progress: 0)
        guard let title = try await spotifyFolderTitle(for: url) else {
            throw DownloadError.processFailed("Spotify did not provide a playlist or album title.")
        }
        let safeTitle = sanitizeDirectoryName(title)
        guard !safeTitle.isEmpty else {
            throw DownloadError.processFailed("The Spotify title cannot be used as a folder name.")
        }
        return (baseDirectory as NSString).appendingPathComponent(safeTitle)
    }

    private func spotifyFolderTitle(for url: String) async throws -> String? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: url)]
        guard let metadataURL = components?.url else {
            throw DownloadError.processFailed("The Spotify URL could not be prepared for metadata lookup.")
        }
        let (data, response) = try await URLSession.shared.data(from: metadataURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.processFailed("Spotify metadata could not be retrieved for this URL.")
        }
        let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let title = metadata?["title"] as? String else { return nil }
        let isAlbum = URL(string: url)?.path.contains("/album/") == true
        if isAlbum, let artist = metadata?["author_name"] as? String, !artist.isEmpty {
            return "\(artist) - \(title)"
        }
        return title
    }

    private func sanitizeDirectoryName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = value.unicodeScalars.map {
            invalidCharacters.contains($0) ? "-" : Character($0)
        }
        return String(sanitized)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
            .prefix(80)
            .description
    }

    private func executeCommand(executable: String, arguments: [String], environment: [String: String]) async throws -> String {
        let command = Process()
        let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.environment = environment
        command.standardOutput = pipe
        command.standardError = pipe
        process = command
        try command.run()
        let status = await withCheckedContinuation { continuation in
            command.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }
        process = nil
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard status == 0 else {
            throw DownloadError.processFailed(output.isEmpty ? "spotdl exited with code \(status)." : output.suffix(1200).description)
        }
        return output
    }

    private func consume(line: String) async {
        let text = line.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        outputLines.append(text)
        let pattern = #"\[?(\d+)\s*/\s*(\d+)\]?"#
        if let match = text.range(of: pattern, options: .regularExpression) {
            let values = text[match].dropFirst().dropLast().split(separator: "/").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            if values.count == 2, values[1] > 0 {
                let index = max(0, Int(values[0]) - 1)
                expectedTrackCount = Int(values[1])
                currentTrackIndex = index
                ensureTrack(index: index, title: titleFrom(text) ?? "Track \(index + 1)")
                progress = min(1, values[0] / values[1])
            }
        }
        let lowercased = text.lowercased()
        if lowercased.contains("failed to convert") || lowercased.contains("ffmpegerror") || lowercased.contains("conversion failed") {
            updateTrack(state: .conversionFailed, detail: text, title: lineTrackTitle(text))
        } else if lowercased.contains("no results") || lowercased.contains("not found") || lowercased.contains("could not find") || lowercased.contains("no song") {
            updateTrack(state: .unavailable, detail: text, title: lineTrackTitle(text))
        } else if lowercased.contains("failed to download") || lowercased.contains("could not download") || lowercased.contains("unable to download") {
            updateTrack(state: .downloadFailed, detail: text, title: lineTrackTitle(text))
        } else if lowercased.contains("downloaded") || lowercased.contains("download complete") || lowercased.contains("saved") || lowercased.contains("skipped") || lowercased.contains("skipping") {
            updateTrack(state: .succeeded, detail: text, title: lineTrackTitle(text))
        } else if lowercased.contains("searching") || lowercased.contains("downloading") || lowercased.contains("converting") {
            updateTrack(state: .downloading, detail: text, title: lineTrackTitle(text))
        }
        if lowercased.contains("download") || lowercased.contains("convert") || lowercased.contains("save") || lowercased.contains("search") {
            progressMessage = text
        }
    }

    private func ensureTrack(index: Int, title: String) {
        while tracks.count <= index {
            let number = tracks.count + 1
            tracks.append(TrackProgress(title: expectedTrackCount == nil ? title : "Track \(number)"))
        }
        if tracks[index].title.hasPrefix("Track "), !title.hasPrefix("Track ") {
            tracks[index].title = title
        }
    }

    private func updateTrack(state: TrackState, detail: String, title: String?) {
        let parsedTitle = title ?? titleFrom(detail)
        let index: Int
        if let parsedTitle,
           let matchingIndex = tracks.firstIndex(where: {
                      let existing = $0.title.lowercased()
                      let parsed = parsedTitle.lowercased()
                      return existing.contains(parsed) || parsed.contains(existing)
                  }) {
            index = matchingIndex
        } else if let currentTrackIndex {
            index = currentTrackIndex
        } else if expectedTrackCount != nil {
            index = tracks.firstIndex(where: { $0.state == .waiting }) ?? max(0, tracks.count - 1)
        } else if let parsedTitle, tracks.last?.title != parsedTitle {
            index = tracks.count
        } else {
            index = max(0, tracks.count - 1)
        }
        ensureTrack(index: index, title: titleFrom(detail) ?? "Track \(index + 1)")
        tracks[index].state = state
        tracks[index].detail = detail
    }

    private func lineTrackTitle(_ text: String) -> String? {
        if let firstQuote = text.firstIndex(of: "\""),
           let lastQuote = text[text.index(after: firstQuote)...].firstIndex(of: "\"") {
            let quoted = String(text[text.index(after: firstQuote)..<lastQuote])
            if !quoted.isEmpty { return quoted }
        }

        guard let separator = text.firstIndex(of: ":") else { return nil }
        let candidate = String(text[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !candidate.isEmpty, !candidate.contains("://") else { return nil }
        return candidate
    }

    private func resetUnfinishedTracks() {
        for index in tracks.indices where tracks[index].state == .downloading {
            tracks[index].state = .waiting
            tracks[index].detail = "Waiting for retry"
        }
    }

    private func finalizeUnfinishedTracks() {
        for index in tracks.indices where tracks[index].state == .downloading || tracks[index].state == .waiting {
            tracks[index].state = .downloadFailed
            tracks[index].detail = "spotdl did not complete this song"
        }
    }

    private var trackSummary: String {
        let succeeded = tracks.filter { $0.state == .succeeded }.count
        let unavailable = tracks.filter { $0.state == .unavailable }.count
        let failed = tracks.filter { $0.state == .downloadFailed || $0.state == .conversionFailed }.count
        return "\(succeeded) succeeded, \(unavailable) not found, \(failed) failed."
    }

    private func titleFrom(_ text: String) -> String? {
        let keywords = ["failed to convert", "failed to download", "downloading", "searching for", "downloaded", "saved", "skipping", "skipped"]
        let lowercased = text.lowercased()
        guard let keyword = keywords.first(where: { lowercased.contains($0) }),
              let range = lowercased.range(of: keyword) else { return nil }
        var title = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let bracket = title.range(of: #"\s*\[\d+\s*/\s*\d+\]"#, options: .regularExpression) {
            title.removeSubrange(bracket)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return title.isEmpty ? nil : title
    }

    private func update(title: String, icon: String, message: String, progress: Double) {
        statusTitle = title
        statusIcon = icon
        progressMessage = message
        self.progress = progress
    }

    private func finish(title: String, icon: String, message: String, error: String?) {
        isRunning = false
        task = nil
        statusTitle = title
        statusIcon = icon
        progressMessage = message
        errorMessage = error
        if error == nil { progress = 1 }
    }

    private var isValidURL: Bool {
        let value = spotifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("https://open.spotify.com/playlist/") || value.hasPrefix("https://open.spotify.com/album/")
    }

    private var expandedDirectory: String {
        (outputDirectory as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DownloadError: LocalizedError {
    case missingTool(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let message), .processFailed(let message): message
        }
    }
}

