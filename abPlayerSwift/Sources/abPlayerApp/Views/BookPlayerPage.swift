import AVFoundation
import SwiftUI
import abPlayerCore
#if os(iOS)
import MediaPlayer
import UIKit
#endif

@MainActor
final class PlaybackController: ObservableObject {
    @Published var book: Book?
    @Published var tracks: [AppStateStore.LocalAudioTrack] = []
    @Published var currentTrackIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var trackDuration: Double = 0
    @Published var loadError: String?

    private(set) var player = AVPlayer()

    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var lastSavedSecond: Int = -1
    private weak var store: AppStateStore?

#if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willResignActiveObserver: NSObjectProtocol?
    private var commandCenterConfigured = false
    private var shouldResumeAfterInterruption = false
    private var shouldMaintainPlaybackOnLifecycle = false
    private var audioSessionCategoryConfigured = false
    private var audioSessionActive = false
    private var playbackWasRunningOnBackgroundEntry = false
    private var timeControlObservation: NSKeyValueObservation?
#endif

    private let saveIntervalSeconds = 15

    init() {
#if os(iOS)
        player.allowsExternalPlayback = true
        // Local files don't need stall-minimization buffering, and leaving it on
        // can let the player enter a waiting state during the foreground ->
        // background transition (e.g. pressing Home) that never resumes.
        player.automaticallyWaitsToMinimizeStalling = false
        if #available(iOS 14.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        configureAudioSessionCategoryIfNeeded()
        installInterruptionObserverIfNeeded()
        installDidBecomeActiveObserverIfNeeded()
        installWillResignActiveObserverIfNeeded()
        installDidEnterBackgroundObserverIfNeeded()
        installRemoteCommandCenterIfNeeded()
        installPlaybackStallRecoveryIfNeeded()
        print("[abPlayer] PlaybackController init (build with bg-recovery + lifecycle logs)")
#endif
    }

    @MainActor
    func shutdown() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
#if os(iOS)
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
        if let token = didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(token)
            didEnterBackgroundObserver = nil
        }
        if let token = willResignActiveObserver {
            NotificationCenter.default.removeObserver(token)
            willResignActiveObserver = nil
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
#endif
    }

    func prepare(with store: AppStateStore, appLanguage: AppLanguageMode) async {
        self.store = store
        guard let selectedBook = store.selectedPlayerBook() else {
            book = nil
            tracks = []
            loadError = L10n.key("error.book_not_found", mode: appLanguage)
#if os(iOS)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
            return
        }

        if book?.id == selectedBook.id, !tracks.isEmpty {
            book = selectedBook
            loadError = nil
            return
        }

        book = selectedBook

        let resolved = await store.localAudioTracks(for: selectedBook)
        guard !resolved.isEmpty else {
            tracks = []
            loadError = L10n.key("player.no_downloaded_audio", mode: appLanguage)
#if os(iOS)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
            return
        }

        tracks = resolved
        currentTrackIndex = resolvedTrackListIndex(forItemIndex: selectedBook.stopFlag.item)
        lastSavedSecond = -1
        installObserversIfNeeded()
        playTrack(index: currentTrackIndex, seekSeconds: Double(max(0, selectedBook.stopFlag.time)), autoPlay: false)
        loadError = nil
        updateNowPlayingInfo()
    }

    func handlePageDisappear() {
        Task { [weak self] in
            await self?.persistStopFlag(force: true)
        }
    }

    func togglePlayPause() {
        guard !tracks.isEmpty else { return }

        let currentlyPlaying = player.rate > 0
        if isPlaying != currentlyPlaying {
            isPlaying = currentlyPlaying
        }

        if isPlaying {
            player.pause()
            isPlaying = false
#if os(iOS)
            shouldResumeAfterInterruption = false
            shouldMaintainPlaybackOnLifecycle = false
#endif
            updateNowPlayingInfo()
            Task { [weak self] in
                await self?.persistStopFlag(force: true)
            }
            return
        }

#if os(iOS)
        // User-initiated play must succeed even when the app is reported as
        // background (e.g. the in-app Play button tapped right after the screen
        // was locked). The `.playback` category is configured up front, so
        // background activation is legitimate here.
        if !activateAudioSessionIfNeeded(allowBackgroundActivation: true) {
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        shouldMaintainPlaybackOnLifecycle = true
#endif
        player.play()
        isPlaying = true
#if os(iOS)
        shouldResumeAfterInterruption = false
#endif
        updateNowPlayingInfo()
        Task { [weak self] in
            await self?.markStartedIfNeeded()
        }
    }

    func playPrevious() {
        playTrack(index: currentTrackIndex - 1, seekSeconds: 0, autoPlay: true)
    }

    func playNext() {
        playTrack(index: currentTrackIndex + 1, seekSeconds: 0, autoPlay: true)
    }

    func selectTrack(_ index: Int) {
        playTrack(index: index, seekSeconds: 0, autoPlay: true)
    }

    func seek(by delta: Double) {
        guard !tracks.isEmpty else { return }

        let itemDuration = player.currentItem?.duration.seconds
        let upperBound: Double
        if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
            upperBound = itemDuration
        } else if trackDuration > 0 {
            upperBound = trackDuration
        } else {
            upperBound = max(0, currentTime + abs(delta))
        }

        let target = max(0, min(upperBound, currentTime + delta))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func installObserversIfNeeded() {
        guard timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }

                currentTime = max(0, time.seconds)
                if let item = player.currentItem {
                    let duration = item.duration.seconds
                    if duration.isFinite, duration > 0 {
                        trackDuration = duration
                    }
                }

                let nowPlaying = player.rate > 0
                if isPlaying != nowPlaying {
                    isPlaying = nowPlaying
                }
                updateNowPlayingInfo()

                await persistStopFlag(force: false)
            }
        }
    }

    private func playTrack(index: Int, seekSeconds: Double, autoPlay: Bool) {
        guard tracks.indices.contains(index) else { return }

        currentTrackIndex = index
        let item = AVPlayerItem(url: tracks[index].url)
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleTrackEnded()
            }
        }
        player.replaceCurrentItem(with: item)

        currentTime = 0
        trackDuration = 0

        let seek = max(0, seekSeconds)
        if seek > 0 {
            player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            currentTime = seek
        }

        if autoPlay {
#if os(iOS)
            // Track changes / auto-advance can fire from the lock screen or a
            // remote command while the app is backgrounded, so allow activation
            // in that state too.
            guard activateAudioSessionIfNeeded(allowBackgroundActivation: true) else {
                isPlaying = false
                updateNowPlayingInfo()
                return
            }
            shouldMaintainPlaybackOnLifecycle = true
#endif
            player.play()
            isPlaying = true
#if os(iOS)
            shouldResumeAfterInterruption = false
#endif
            Task { [weak self] in
                await self?.markStartedIfNeeded()
            }
        } else {
            player.pause()
            isPlaying = false
#if os(iOS)
            shouldResumeAfterInterruption = false
            shouldMaintainPlaybackOnLifecycle = false
#endif
        }
        updateNowPlayingInfo()
    }

    private func markStartedIfNeeded() async {
        guard let store, let book, book.status == .new else { return }
        await store.updateBookStatus(bookID: book.id, status: .started)
        refreshBookFromStore()
    }

    private func handleTrackEnded() async {
        guard let store, let book else { return }
        let endedTrackListIndex = currentTrackIndex

        if endedTrackListIndex < tracks.count - 1 {
            let nextItemIndex = tracks[endedTrackListIndex + 1].itemIndex
            await store.updateListeningProgress(bookID: book.id, item: nextItemIndex, time: 0)
            refreshBookFromStore()
            lastSavedSecond = -1
            playTrack(index: endedTrackListIndex + 1, seekSeconds: 0, autoPlay: true)
            return
        }

        let itemIndex = tracks[endedTrackListIndex].itemIndex
        await store.updateListeningProgress(bookID: book.id, item: itemIndex, time: Int(max(0, trackDuration)))
        await store.updateBookStatus(bookID: book.id, status: .finished)
        refreshBookFromStore()
        isPlaying = false
#if os(iOS)
        shouldResumeAfterInterruption = false
        shouldMaintainPlaybackOnLifecycle = false
#endif
        updateNowPlayingInfo()
    }

    private func persistStopFlag(force: Bool) async {
        guard let store, let book, tracks.indices.contains(currentTrackIndex) else { return }
        if !force, !isPlaying { return }

        let second = Int(max(0, currentTime))
        if !force {
            if second <= 0 { return }
            if lastSavedSecond >= 0, second - lastSavedSecond < saveIntervalSeconds {
                return
            }
        }

        let itemIndex = tracks[currentTrackIndex].itemIndex
        await store.updateListeningProgress(bookID: book.id, item: itemIndex, time: second)
        refreshBookFromStore()
        lastSavedSecond = second
    }

    private func refreshBookFromStore() {
        guard let store else { return }
        if let selected = store.selectedPlayerBook() {
            book = selected
            return
        }
        if let id = book?.id {
            book = store.books.first(where: { $0.id == id })
        }
    }

    private func resolvedTrackListIndex(forItemIndex itemIndex: Int) -> Int {
        if let exact = tracks.firstIndex(where: { $0.itemIndex == itemIndex }) {
            return exact
        }
        if let next = tracks.firstIndex(where: { $0.itemIndex > itemIndex }) {
            return next
        }
        return max(0, tracks.count - 1)
    }

    private func updateNowPlayingInfo() {
#if os(iOS)
        guard let book else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let trackTitle: String = {
            guard tracks.indices.contains(currentTrackIndex) else { return book.name }
            let title = tracks[currentTrackIndex].title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? book.name : title
        }()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: trackTitle,
            MPMediaItemPropertyAlbumTitle: book.name,
            MPMediaItemPropertyArtist: book.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if trackDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = trackDuration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#endif
    }

#if os(iOS)
    @discardableResult
    private func configureAudioSessionCategoryIfNeeded() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if audioSessionCategoryConfigured, session.category == .playback {
            return true
        }

        // `.playback` is what grants background-audio rights; establishing it
        // up front (before the app ever backgrounds or the screen locks) is what
        // lets `setActive(true)` succeed later from the background. Without it,
        // activation from the lock screen fails with `!pla` (561015905).
        let configurations: [(AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.spokenAudio, []),
            (.default, [])
        ]

        for (mode, options) in configurations {
            do {
                try session.setCategory(.playback, mode: mode, options: options)
                audioSessionCategoryConfigured = true
                return true
            } catch {
                continue
            }
        }

        print("[abPlayer] AVAudioSession setCategory(.playback) failed")
        return false
    }

    @discardableResult
    private func activateAudioSessionIfNeeded(allowBackgroundActivation: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()

        guard configureAudioSessionCategoryIfNeeded() else {
            audioSessionActive = false
            return false
        }

        // Important: iOS denies an explicit `setActive(true)` issued from the
        // background (e.g. while the screen is locked) with `!pla` (561015905),
        // and a denied activation cascades into the AVPlayer's remote playback
        // process being torn down (`-12785`). The app already owns the `audio`
        // background mode, so `AVPlayer.play()` is allowed to activate the
        // session implicitly. We therefore only *explicitly* activate while in
        // the foreground; in the background we skip the explicit call and let
        // playback proceed, letting AVPlayer manage the session itself.
        if session.category != .playback {
            return false
        }

        let isForeground = UIApplication.shared.applicationState == .active
        guard isForeground else {
            // Don't fight the OS from the background. Report success so callers
            // proceed to `player.play()`, which can resume implicitly.
            return true
        }

        do {
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            // A foreground activation can still fail transiently. Don't block
            // playback on it — `AVPlayer.play()` will activate implicitly.
            audioSessionActive = false
            print("[abPlayer] AVAudioSession activate failed (state=\(UIApplication.shared.applicationState.rawValue)): \(error)")
            return true
        }
    }

    private func installInterruptionObserverIfNeeded() {
        guard interruptionObserver == nil else { return }
        installPlaybackStallRecoveryIfNeeded()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
    }

    private func handleAudioSessionInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        switch type {
        case .began:
            print("[abPlayer] interruption BEGAN rate=\(player.rate) isPlaying=\(isPlaying) maintain=\(shouldMaintainPlaybackOnLifecycle)")
            shouldResumeAfterInterruption = shouldMaintainPlaybackOnLifecycle && (isPlaying || player.rate > 0)
            isPlaying = false
            audioSessionActive = false
            updateNowPlayingInfo()
        case .ended:
            print("[abPlayer] interruption ENDED options=\(optionsRaw) shouldResume=\(shouldResumeAfterInterruption)")
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if shouldResumeAfterInterruption && options.contains(.shouldResume) {
                resumeAfterInterruptionIfNeeded(allowBackgroundActivation: true)
            } else {
                shouldResumeAfterInterruption = false
            }
        @unknown default:
            break
        }
    }

    private func installPlaybackStallRecoveryIfNeeded() {
        guard timeControlObservation == nil else { return }
        // Going to background via the Home button / app switcher does not post an
        // audio-session interruption (unlike locking the screen), so there is no
        // .ended event to trigger a resume. In that path the system can still
        // pause the player while it transitions; observe the player's control
        // status and immediately re-issue play() when it pauses unexpectedly
        // while we intend to keep playing in the background.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleTimeControlStatusChange(player.timeControlStatus)
            }
        }
    }

    private func handleTimeControlStatusChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            if !isPlaying { isPlaying = true }
        case .paused:
            // Only fight an *unexpected* pause: the user/our code clears
            // shouldMaintainPlaybackOnLifecycle whenever a pause is intentional.
            if shouldMaintainPlaybackOnLifecycle, player.currentItem != nil {
                print("[abPlayer] Player paused unexpectedly while playback should continue; re-playing.")
                player.play()
                if player.rate > 0 { isPlaying = true }
            } else if isPlaying {
                isPlaying = false
            }
            updateNowPlayingInfo()
        default:
            break
        }
    }

    private func installDidBecomeActiveObserverIfNeeded() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleDidBecomeActive()
            }
        }
    }

    private func installDidEnterBackgroundObserverIfNeeded() {
        guard didEnterBackgroundObserver == nil else { return }
        didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleDidEnterBackground()
            }
        }
    }

    private func handleDidBecomeActive() {
        isPlaying = player.rate > 0
        if playbackWasRunningOnBackgroundEntry, shouldMaintainPlaybackOnLifecycle, player.rate == 0, player.currentItem != nil {
            shouldResumeAfterInterruption = true
        }
        playbackWasRunningOnBackgroundEntry = false
        resumeAfterInterruptionIfNeeded(allowBackgroundActivation: false)
        recoverPlaybackIfNeeded(trigger: "didBecomeActive")
        updateNowPlayingInfo()
    }

    private func handleDidEnterBackground() {
        print("[abPlayer] didEnterBackground rate=\(player.rate) isPlaying=\(isPlaying) maintain=\(shouldMaintainPlaybackOnLifecycle)")
        // The screen lock posts an interruption (.began) that pauses the player
        // *before* this lifecycle callback, so `player.rate` may already be 0.
        // Fall back to the pending resume intent so we still treat playback as
        // "was running" and keep the session alive for background resume.
        let wasPlaying = player.rate > 0 || isPlaying || shouldResumeAfterInterruption || shouldMaintainPlaybackOnLifecycle
        playbackWasRunningOnBackgroundEntry = wasPlaying
        if wasPlaying {
            shouldMaintainPlaybackOnLifecycle = true
            _ = activateAudioSessionIfNeeded(allowBackgroundActivation: true)
        }
        isPlaying = player.rate > 0
        updateNowPlayingInfo()
    }

    private func installWillResignActiveObserverIfNeeded() {
        guard willResignActiveObserver == nil else { return }
        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleWillResignActive()
            }
        }
    }

    private func handleWillResignActive() {
        print("[abPlayer] willResignActive rate=\(player.rate) isPlaying=\(isPlaying)")
        let wasPlaying = player.rate > 0 || isPlaying || shouldResumeAfterInterruption || shouldMaintainPlaybackOnLifecycle
        playbackWasRunningOnBackgroundEntry = wasPlaying
        if wasPlaying {
            shouldMaintainPlaybackOnLifecycle = true
            _ = activateAudioSessionIfNeeded(allowBackgroundActivation: true)
        }
        updateNowPlayingInfo()
    }

    private func resumeAfterInterruptionIfNeeded(allowBackgroundActivation: Bool) {
        guard shouldResumeAfterInterruption else { return }
        guard player.currentItem != nil else {
            shouldResumeAfterInterruption = false
            return
        }
        if player.rate > 0 {
            shouldResumeAfterInterruption = false
            isPlaying = true
            shouldMaintainPlaybackOnLifecycle = true
            return
        }

        guard activateAudioSessionIfNeeded(allowBackgroundActivation: allowBackgroundActivation) else { return }
        player.play()
        isPlaying = true
        shouldResumeAfterInterruption = false
        shouldMaintainPlaybackOnLifecycle = true
        updateNowPlayingInfo()
    }

    private func recoverPlaybackIfNeeded(trigger: String) {
        guard shouldMaintainPlaybackOnLifecycle else { return }
        guard player.currentItem != nil else { return }
        guard player.rate == 0 else {
            isPlaying = true
            return
        }

        guard activateAudioSessionIfNeeded(allowBackgroundActivation: false) else { return }
        player.play()
        isPlaying = player.rate > 0
        if isPlaying {
            updateNowPlayingInfo()
        } else {
            print("[abPlayer] Playback recover failed at \(trigger)")
        }
    }

    private func installRemoteCommandCenterIfNeeded() {
        guard !commandCenterConfigured else { return }
        commandCenterConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard activateAudioSessionIfNeeded(allowBackgroundActivation: true) else {
                return .commandFailed
            }
            player.play()
            isPlaying = true
            shouldResumeAfterInterruption = false
            shouldMaintainPlaybackOnLifecycle = true
            updateNowPlayingInfo()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            player.pause()
            isPlaying = false
            shouldResumeAfterInterruption = false
            shouldMaintainPlaybackOnLifecycle = false
            updateNowPlayingInfo()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            playNext()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            playPrevious()
            return .success
        }

        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            seek(by: -15)
            return .success
        }

        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            seek(by: 15)
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let delta = event.positionTime - currentTime
            seek(by: delta)
            updateNowPlayingInfo()
            return .success
        }
    }
#endif
}

struct BookPlayerPage: View {
    @ObservedObject var store: AppStateStore
    @ObservedObject var playback: PlaybackController

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private var isCompactPhoneLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let loadError = playback.loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if let book = playback.book {
                bookMeta(book)
                playerControls
                chapterList
            } else {
                Text(L10n.key("player.not_selected", mode: store.appLanguage))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .onAppear {
            Task {
                await playback.prepare(with: store, appLanguage: store.appLanguage)
            }
        }
        .onDisappear {
            playback.handlePageDisappear()
        }
    }

    private var header: some View {
        Group {
            if isCompactPhoneLayout {
                VStack(alignment: .leading, spacing: 8) {
                    Button(L10n.key("player.back_to_library", mode: store.appLanguage)) {
                        store.closeBookPlayer()
                    }
                    .buttonStyle(.bordered)

                    Text(playback.book?.name ?? L10n.key("player.title", mode: store.appLanguage))
                        .font(.title3)
                        .bold()
                        .lineLimit(2)
                }
            } else {
                HStack {
                    Button(L10n.key("player.back_to_library", mode: store.appLanguage)) {
                        store.closeBookPlayer()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text(playback.book?.name ?? L10n.key("player.title", mode: store.appLanguage))
                        .font(.title2)
                        .bold()

                    Spacer()
                }
            }
        }
    }

    private func bookMeta(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteCoverView(
                urlString: book.preview,
                width: isCompactPhoneLayout ? 60 : 72,
                height: isCompactPhoneLayout ? 86 : 104,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(book.name)
                    .font(isCompactPhoneLayout ? .headline : .title3)
                    .bold()
                    .lineLimit(2)

                Text(book.author)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !book.description.isEmpty {
                    Text(book.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(isCompactPhoneLayout ? 2 : 3)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label(book.author, systemImage: "person")
                    Label(book.reader.isEmpty ? "-" : book.reader, systemImage: "mic")
                    Label(book.duration.isEmpty ? "-" : book.duration, systemImage: "clock")
                    Label(book.displaySeries.isEmpty ? "-" : book.displaySeries, systemImage: "tag")
                    Label(book.driver.isEmpty ? "-" : book.driver, systemImage: "network")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text("\(book.listeningProgress) \(L10n.key("common.listened", mode: store.appLanguage))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformControlBackground))
    }

    private var playerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCompactPhoneLayout {
                HStack(spacing: 8) {
                    controlButtons
                }

                Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.trackDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 8) {
                    controlButtons
                    Spacer()

                    Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.trackDuration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Slider(value: Binding(get: {
                playback.trackDuration > 0 ? playback.currentTime / playback.trackDuration : 0
            }, set: { value in
                guard playback.trackDuration > 0 else { return }
                let target = max(0, min(playback.trackDuration, value * playback.trackDuration))
                playback.seek(by: target - playback.currentTime)
            }), in: 0 ... 1)
            .disabled(playback.trackDuration <= 0)
        }
    }

    private var controlButtons: some View {
        Group {
            Button {
                playback.seek(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .disabled(playback.tracks.isEmpty)
            .help(L10n.key("player.rewind_15", mode: store.appLanguage))

            Button {
                playback.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(playback.currentTrackIndex <= 0)
            .help(L10n.key("player.previous", mode: store.appLanguage))

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(playback.tracks.isEmpty)
            .help(playback.isPlaying ? L10n.key("player.pause", mode: store.appLanguage) : L10n.key("player.play", mode: store.appLanguage))

            Button {
                playback.playNext()
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(playback.currentTrackIndex >= playback.tracks.count - 1)
            .help(L10n.key("player.next", mode: store.appLanguage))

            Button {
                playback.seek(by: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .disabled(playback.tracks.isEmpty)
            .help(L10n.key("player.forward_15", mode: store.appLanguage))
        }
    }

    private var chapterList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(playback.tracks.enumerated()), id: \.1.id) { index, track in
                    let fallbackTitle = "\(L10n.key("player.chapter", mode: store.appLanguage)) \(index + 1)"
                    Button {
                        playback.selectTrack(index)
                    } label: {
                        HStack {
                            Text(track.title.isEmpty ? fallbackTitle : track.title)
                                .lineLimit(1)
                            Spacer()
                            if index == playback.currentTrackIndex {
                                Text(playback.isPlaying ? L10n.key("player.playing", mode: store.appLanguage) : L10n.key("player.paused", mode: store.appLanguage))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index == playback.currentTrackIndex ? Color.accentColor.opacity(0.15) : Color.platformControlBackground)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "00:00" }
        let total = Int(value)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
