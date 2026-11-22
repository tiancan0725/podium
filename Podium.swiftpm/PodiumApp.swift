import SwiftUI
import UIKit

@main
struct PodiumApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { PresentationState.shared.saveNotesNow() }
        }
    }
}

/// Routes an external display (projector, AirPlay) to its own audience-only scene,
/// so the room sees clean slides while the iPad keeps the controls.
///
/// SwiftUI apps don't reliably get asked about this role (and a Playgrounds package can't add
/// it to the generated Info.plist), so `ExternalDisplay` also takes over the scene if it connects
/// with some other delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ExternalDisplay.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        debugLog("configurationForConnecting role=\(session.role.rawValue)")
        if session.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "Audience", sessionRole: session.role)
            config.delegateClass = AudienceSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

final class AudienceSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = ExternalDisplay.makeAudienceWindow(on: windowScene)
        PresentationState.shared.externalConnected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        PresentationState.shared.externalConnected = false
    }
}

/// Fallback for when the external-display scene connects with a delegate that isn't ours
/// (for example SwiftUI's own): put the audience window on top of whatever it shows.
@MainActor
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    func start() {
        let center = NotificationCenter.default
        for name in [UIScene.willConnectNotification, UIScene.didActivateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let scene = note.object as? UIWindowScene
                MainActor.assumeIsolated { if let scene { self?.adopt(scene) } }
            }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            let scene = note.object as? UIScene
            MainActor.assumeIsolated {
                guard let self, let scene, self.windows.removeValue(forKey: ObjectIdentifier(scene)) != nil else { return }
                PresentationState.shared.externalConnected = false
            }
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.forEach(adopt)
    }

    private func adopt(_ scene: UIWindowScene) {
        debugLog("scene event role=\(scene.session.role.rawValue) delegate=\(String(describing: scene.delegate))")
        guard scene.session.role == .windowExternalDisplayNonInteractive,
              !(scene.delegate is AudienceSceneDelegate),
              windows[ObjectIdentifier(scene)] == nil else { return }
        windows[ObjectIdentifier(scene)] = Self.makeAudienceWindow(on: scene)
        PresentationState.shared.externalConnected = true
    }

    static func makeAudienceWindow(on scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AudienceView())
        window.windowLevel = .normal + 1
        window.isHidden = false
        return window
    }
}

/// Prints only in debug builds, for checking which scenes iOS hands us.
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Podium] \(message())")
    #endif
}

extension UIApplication {
    /// The iPad's own window (not the projector's).
    @MainActor static var mainWindow: UIWindow? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }
        return scene?.keyWindow ?? scene?.windows.first { !$0.isHidden }
    }

    /// The view controller on top, to present pickers and share sheets from.
    @MainActor static var topViewController: UIViewController? {
        var top = mainWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
