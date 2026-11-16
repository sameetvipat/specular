import AVKit
import AetherEngine

/// Picture in Picture the way AetherEngine documents it for a host with its own controls:
/// an AVPictureInPictureController on the engine's AVPlayerLayer (native route) or on its
/// sample-buffer source (software route). The host tells the engine while the window is up.
@MainActor
final class PiP: NSObject, AVPictureInPictureControllerDelegate {
    private let engine: AetherEngine
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    var onFail: () -> Void = {}

    init(engine: AetherEngine) { self.engine = engine }

    func toggle() {
        if let c = controller, c.isPictureInPictureActive { c.stopPictureInPicture(); return }
        // A fresh controller each time: every load replaces the layer / source.
        guard let c = engine.nativePlayerLayer.flatMap({ AVPictureInPictureController(playerLayer: $0) })
                ?? engine.softwarePiPSource?.makePictureInPictureController() else { onFail(); return }
        c.delegate = self; controller = c
        // A new controller cannot start at once: wait until it says it can, 2 s at most.
        possible = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            guard c.isPictureInPicturePossible else { return }
            DispatchQueue.main.async {
                guard let self, self.possible != nil else { return }
                self.possible = nil; c.startPictureInPicture()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.possible != nil, self.controller === c else { return }
            self.possible = nil; self.onFail()
        }
    }

    func stop() {
        possible = nil
        controller?.stopPictureInPicture(); controller = nil
        if engine.pictureInPictureActive { engine.pictureInPictureActive = false }
    }

    // AVKit gives no thread promise for these: hop to main.
    nonisolated private func setActive(_ on: Bool, failed: Bool = false) {
        Task { @MainActor in
            if self.engine.pictureInPictureActive != on { self.engine.pictureInPictureActive = on }
            if failed { self.onFail() }
        }
    }
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { setActive(true) }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { setActive(false) }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        setActive(false, failed: true)
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true); done(true) }
    }
}

extension PlayerModel {
    /// False hides the button: no picture, or a route with no layer to hand over
    /// (Dolby Vision Profile 7 dual-layer output).
    var canPiP: Bool {
        !audioOnly && AVPictureInPictureController.isPictureInPictureSupported()
            && (engine.nativePlayerLayer != nil || engine.softwarePiPSource != nil)
    }
    var pipActive: Bool { engine.pictureInPictureActive }

    func togglePiP() {
        guard canPiP else { return }
        if pip == nil {
            pip = PiP(engine: engine)
            pip?.onFail = { [weak self] in self?.flash("Picture in Picture is not available") }
        }
        pip?.toggle(); poke()
    }
}
