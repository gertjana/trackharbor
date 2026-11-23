import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: DownloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            form
            statusCard
            trackList
            Spacer(minLength: 0)
            footer
        }
        .padding(32)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onSubmit { model.startDownload() }
        .onChange(of: model.spotifyURL) { _ in
            model.resetForNewURL()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                if let iconURL = Bundle.main.url(forResource: "TrackHarbor", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("TrackHarbor")
                    .font(.largeTitle.bold())
            }
            Text("Copy Spotify playlists to your music player")
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Spotify playlist or album URL")
                    .font(.headline)
                HStack {
                    Button("Paste") {
                        model.pasteSpotifyURL()
                    }
                    .disabled(model.isRunning)
                    TextField("https://open.spotify.com/playlist/...", text: $model.spotifyURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Download folder")
                    .font(.headline)
                HStack {
                    TextField("~/Music/TrackHarbor", text: $model.outputDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                    Button("Choose…") { model.chooseOutputDirectory() }
                        .disabled(model.isRunning)
                }
            }

            Toggle("Create a subfolder using the playlist or album title", isOn: $model.usePlaylistSubdirectory)
                .disabled(model.isRunning)

            HStack {
                Button {
                    model.startDownload()
                } label: {
                    Label(model.isRunning ? "Downloading…" : "Download music", systemImage: model.isRunning ? "arrow.down.circle" : "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isRunning)

                if model.canRetry {
                    Button {
                        model.startDownload()
                    } label: {
                        Label("Retry failed songs", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }

                if model.isRunning {
                    Button("Cancel") { model.cancelDownload() }
                        .controlSize(.large)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.statusTitle, systemImage: model.statusIcon)
                    .font(.headline)
                Spacer()
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.isRunning || model.progress > 0 {
                ProgressView(value: model.progress)
                    .tint(.accentColor)
                Text(model.progressMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        Text("First launch sets up Python, spotdl, Deno, and FFmpeg automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Songs")
                .font(.headline)
                .padding(.bottom, 8)
            HStack {
                Text("TRACK")
                Spacer()
                Text("STATUS")
                    .frame(width: 120, alignment: .leading)
                Text("DETAILS")
                    .frame(width: 240, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            ScrollView {
                if model.tracks.isEmpty {
                    Text("Playlist songs will appear here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                        .padding(8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tracks) { track in
                            HStack(spacing: 10) {
                                Image(systemName: track.state.icon)
                                    .foregroundStyle(color(for: track.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .lineLimit(1)
                                    if !track.detail.isEmpty {
                                        Text(track.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(track.state.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                Text(track.detail.isEmpty ? "—" : track.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 240, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
    }

    private func color(for state: TrackState) -> Color {
        switch state {
        case .succeeded: .green
        case .unavailable: .orange
        case .downloadFailed, .conversionFailed: .red
        case .waiting, .downloading: .secondary
        }
    }
}
