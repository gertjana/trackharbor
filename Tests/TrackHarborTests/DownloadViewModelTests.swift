import Foundation
import Testing
@testable import TrackHarbor

@MainActor
struct DownloadViewModelTests {
    @Test func startDownloadRejectsInvalidURL() {
        let model = DownloadViewModel()

        model.spotifyURL = "https://example.com/playlist/123"
        model.startDownload()

        #expect(model.statusTitle == "Check the playlist URL")
        #expect(model.statusIcon == "exclamationmark.triangle")
        #expect(model.errorMessage == "Paste a Spotify playlist or album URL beginning with https://open.spotify.com/.")
        #expect(model.isRunning == false)
    }

    @Test func startDownloadRejectsEmptyDirectory() {
        let model = DownloadViewModel()

        model.spotifyURL = "https://open.spotify.com/playlist/123"
        model.outputDirectory = "   "
        model.startDownload()

        #expect(model.statusTitle == "Choose a download folder")
        #expect(model.errorMessage == "The download folder cannot be empty.")
        #expect(model.isRunning == false)
    }

    @Test func resetForNewURLRestoresIdleState() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/2] Failed to download Song")
        model.startDownload()
        model.resetForNewURL()

        #expect(model.tracks.isEmpty)
        #expect(model.progress == 0)
        #expect(model.progressMessage == "Ready to download.")
        #expect(model.statusTitle == "Ready")
        #expect(model.statusIcon == "checkmark.circle")
        #expect(model.errorMessage == nil)
    }

    @Test func expandedDirectoryTrimsAndExpandsTilde() {
        let model = DownloadViewModel()

        model.outputDirectory = " ~/Music/Test Folder  "

        #expect(model.testExpandedDirectory == (NSHomeDirectory() as NSString).appendingPathComponent("Music/Test Folder"))
    }

    @Test func validURLAcceptsPlaylistAndAlbumOnly() {
        let model = DownloadViewModel()

        model.spotifyURL = "https://open.spotify.com/playlist/abc"
        #expect(model.testIsValidURL)

        model.spotifyURL = "https://open.spotify.com/album/abc"
        #expect(model.testIsValidURL)

        model.spotifyURL = "https://open.spotify.com/track/abc"
        #expect(model.testIsValidURL == false)
    }

    @Test func consumeParsesProgressAndDownloadingState() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/3] Downloading Artist - Song")

        #expect(model.tracks.count == 1)
        #expect(model.tracks[0].title == "Artist - Song")
        #expect(model.tracks[0].state == .downloading)
        #expect(model.progress == 1.0 / 3.0)
        #expect(model.progressMessage == "[1/3] Downloading Artist - Song")
    }

    @Test func consumeParsesUnbracketedProgress() async {
        let model = DownloadViewModel()
        await model.testConsume(line: "2/3 Downloading Second Song")
        #expect(model.tracks.count == 2)
        #expect(model.tracks[1].state == .downloading)
        #expect(model.progress == 2.0 / 3.0)
    }

    @Test func consumeMarksSucceededForSavedLine() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/2] Downloading Artist - Song")
        await model.testConsume(line: "Saved Artist - Song")

        #expect(model.tracks[0].state == .succeeded)
        #expect(model.tracks[0].detail == "Saved Artist - Song")
    }

    @Test func consumeMarksUnavailableForNoResultsLine() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/1] Searching for Artist - Missing Song")
        await model.testConsume(line: "No results found for \"Artist - Missing Song\"")

        #expect(model.tracks[0].state == .unavailable)
        #expect(model.tracks[0].detail.contains("No results"))
    }

    @Test func consumeMarksDownloadFailure() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/1] Downloading Artist - Song")
        await model.testConsume(line: "Failed to download Artist - Song")

        #expect(model.tracks[0].state == .downloadFailed)
    }

    @Test func consumeMarksConversionFailure() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/1] Downloading Artist - Song")
        await model.testConsume(line: "Failed to convert Artist - Song")

        #expect(model.tracks[0].state == .conversionFailed)
    }

    @Test func consumeMatchesQuotedTrackTitle() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/2] Downloading Artist - Song")
        await model.testConsume(line: "[2/2] Downloading Another Song")
        await model.testConsume(line: "No results found for \"Artist - Song\"")

        #expect(model.tracks[0].state == .unavailable)
        #expect(model.tracks[1].state == .downloading)
    }

    @Test func resetUnfinishedTracksOnlyTouchesDownloading() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[3/3] Downloading C")
        await model.testConsume(line: "Saved C")
        await model.testConsume(line: "[1/3] Downloading A")
        model.testResetUnfinishedTracks()

        #expect(model.tracks[0].state == .waiting)
        #expect(model.tracks[0].detail == "Waiting for retry")
        #expect(model.tracks[1].state == .waiting)
        #expect(model.tracks[1].detail.isEmpty)
        #expect(model.tracks[2].state == .succeeded)
    }

    @Test func finalizeUnfinishedTracksMarksWaitingAndDownloadingFailed() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[3/3] Downloading C")
        await model.testConsume(line: "Saved C")
        await model.testConsume(line: "[1/3] Downloading A")
        model.testFinalizeUnfinishedTracks()

        #expect(model.tracks[0].state == .downloadFailed)
        #expect(model.tracks[1].state == .downloadFailed)
        #expect(model.tracks[2].state == .succeeded)
    }

    @Test func trackSummaryCountsSucceededUnavailableAndFailed() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/5] Saved A")
        await model.testConsume(line: "[2/5] Saved B")
        await model.testConsume(line: "[3/5] No results found")
        await model.testConsume(line: "[4/5] Failed to download D")
        await model.testConsume(line: "[5/5] Failed to convert E")

        #expect(model.testTrackSummary == "2 succeeded, 1 not found, 2 failed.")
    }

    @Test func canRetryRequiresFailedTrackAndNotRunning() async {
        let model = DownloadViewModel()

        await model.testConsume(line: "[1/2] Saved A")
        #expect(model.canRetry == false)

        await model.testConsume(line: "[2/2] Failed to download B")
        #expect(model.canRetry)
    }

    @Test func cancelDownloadRestoresCancelledState() {
        let model = DownloadViewModel()

        model.cancelDownload()

        #expect(model.isRunning == false)
        #expect(model.statusTitle == "Cancelled")
        #expect(model.statusIcon == "xmark.circle")
        #expect(model.progressMessage == "The download was cancelled.")
        #expect(model.errorMessage == nil)
        #expect(model.progress == 1)
    }

    @Test func sanitizeDirectoryNameReplacesInvalidCharactersAndTrimsDots() {
        let model = DownloadViewModel()

        let value = model.testSanitizeDirectoryName(" ../AC/DC: Greatest Hits?*<>")

        #expect(value == "-AC-DC- Greatest Hits----")
    }

    @Test func sanitizeDirectoryNameIsLimitedTo80Characters() {
        let model = DownloadViewModel()

        let value = model.testSanitizeDirectoryName(String(repeating: "a", count: 100))

        #expect(value.count == 80)
    }

    @Test func lineTrackTitlePrefersQuotedValue() {
        let model = DownloadViewModel()

        #expect(model.testLineTrackTitle("No results found for \"Artist - Song\"") == "Artist - Song")
    }

    @Test func lineTrackTitleFallsBackToPrefixBeforeColon() {
        let model = DownloadViewModel()

        #expect(model.testLineTrackTitle("Artist - Song: failed to download") == "Artist - Song")
        #expect(model.testLineTrackTitle("https://example.com: failed") == nil)
    }

    @Test func titleFromExtractsTitleAndStripsProgressSuffix() {
        let model = DownloadViewModel()

        #expect(model.testTitleFrom("Downloading Artist - Song [1/3]") == "Artist - Song")
        #expect(model.testTitleFrom("Saved Artist - Song") == "Artist - Song")
        #expect(model.testTitleFrom("Completely unrelated log line") == nil)
    }
}
