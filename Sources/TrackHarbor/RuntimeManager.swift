import Foundation

struct RuntimeTools {
    let spotdl: String
    let deno: String
    let ffmpeg: String
    let searchPaths: [String]

    var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["HOME"] = RuntimeManager.runtimeDirectory.path
        let paths = searchPaths + [values["PATH"] ?? "/usr/bin:/bin"]
        values["PATH"] = paths.joined(separator: ":")
        return values
    }
}

enum RuntimeManager {
    fileprivate static let runtimeDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/TrackHarbor/runtime", isDirectory: true)

    static func ensure() async throws -> RuntimeTools {
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let python = try await ensurePython()
        let venv = runtimeDirectory.appendingPathComponent("venv", isDirectory: true)
        let venvPython = venv.appendingPathComponent("bin/python").path
        let spotdl = venv.appendingPathComponent("bin/spotdl").path

        if !FileManager.default.isExecutableFile(atPath: spotdl) {
            try await run(python, arguments: ["-m", "venv", venv.path])
            try await run(venvPython, arguments: ["-m", "pip", "install", "--disable-pip-version-check", "--quiet", "spotdl"])
        }
        guard FileManager.default.isExecutableFile(atPath: spotdl) else {
            throw RuntimeError.setupFailed("spotdl could not be installed in the managed environment.")
        }

        let managedEnvironment = [
            "HOME": runtimeDirectory.path,
            "PATH": [venv.appendingPathComponent("bin").path, "/usr/bin", "/bin"].joined(separator: ":")
        ]
        let spotdlDirectory = runtimeDirectory.appendingPathComponent(".spotdl", isDirectory: true)
        let localFFmpeg = spotdlDirectory.appendingPathComponent("ffmpeg").path
        if !FileManager.default.isExecutableFile(atPath: localFFmpeg) {
            try await run(spotdl, arguments: ["--download-ffmpeg"], environment: managedEnvironment)
        }
        guard FileManager.default.isExecutableFile(atPath: localFFmpeg) else {
            throw RuntimeError.setupFailed("FFmpeg could not be installed in the managed environment.")
        }

        let deno = spotdlDirectory.appendingPathComponent("deno").path
        if !FileManager.default.isExecutableFile(atPath: deno) {
            try await run(spotdl, arguments: ["--download-deno"], environment: managedEnvironment)
        }
        guard FileManager.default.isExecutableFile(atPath: deno) else {
            throw RuntimeError.setupFailed("Deno could not be installed in the managed environment.")
        }

        return RuntimeTools(
            spotdl: spotdl,
            deno: deno,
            ffmpeg: localFFmpeg,
            searchPaths: [venv.appendingPathComponent("bin").path, spotdlDirectory.path]
        )
    }

    private static func ensurePython() async throws -> String {
        let pythonDirectory = runtimeDirectory.appendingPathComponent("python", isDirectory: true)
        if let existing = pythonExecutable(in: pythonDirectory) {
            return existing
        }

        let architecture = currentArchitecture
        let requestURL = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")!
        var request = URLRequest(url: requestURL)
        request.setValue("TrackHarbor macOS app", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else {
            throw RuntimeError.setupFailed("The portable Python release list could not be retrieved.")
        }

        let architectureToken = architecture == "arm64" ? "aarch64" : "x86_64"
        let candidates = assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let downloadURL = asset["browser_download_url"] as? String,
                  name.contains("cpython-3.13"),
                  name.contains("\(architectureToken)-apple-darwin-install_only.tar.gz"),
                  !name.contains("freethreaded"),
                  let url = URL(string: downloadURL) else { return nil }
            return (name, url)
        }
        guard let (_, archiveURL) = candidates.first else {
            throw RuntimeError.setupFailed("No compatible portable Python build was found for this Mac.")
        }

        let archive = runtimeDirectory.appendingPathComponent("python.tar.gz")
        let (archiveData, archiveResponse) = try await URLSession.shared.data(from: archiveURL)
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw RuntimeError.setupFailed("The portable Python runtime could not be downloaded.")
        }
        try archiveData.write(to: archive, options: .atomic)
        try await run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", runtimeDirectory.path])
        try? FileManager.default.removeItem(at: archive)
        guard let python = pythonExecutable(in: pythonDirectory) else {
            throw RuntimeError.setupFailed("The portable Python archive did not contain a usable interpreter.")
        }
        return python
    }

    private static func pythonExecutable(in directory: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isExecutableKey]) else {
            return nil
        }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent.hasPrefix("python3") {
            if FileManager.default.isExecutableFile(atPath: fileURL.path) {
                return fileURL.path
            }
        }
        return nil
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil) async throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard status == 0 else {
            throw RuntimeError.setupFailed(output.suffix(1200).description.isEmpty ? "\(executable) failed." : output.suffix(1200).description)
        }
    }
}

private enum RuntimeError: LocalizedError {
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .setupFailed(let message): message
        }
    }
}
