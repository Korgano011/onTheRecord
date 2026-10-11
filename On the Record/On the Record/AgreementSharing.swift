import CloudKit
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit

/// Receives invitations to shared agreements: when someone taps the link,
/// iOS opens the app and hands the share to the scene delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Invitation link tapped while the app wasn't running.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { accept(metadata) }
    }

    /// Invitation link tapped while the app was running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        accept(metadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { @MainActor in await CloudService.shared.accept(metadata) }
    }
}
#endif

/// Apple's sheet for inviting people to a shared agreement and managing
/// who has access. Presented from UIKit, since it misbehaves inside a
/// SwiftUI sheet.
@MainActor
enum CloudSharing {
    static var isAvailable: Bool {
        #if os(iOS)
        CloudService.isEnabled && !CloudService.isLocalTestMode
        #else
        false
        #endif
    }

    #if os(iOS)
    /// The controller holds its delegate weakly.
    private static var delegate: Delegate?

    static func present(_ share: CKShare, title: String) {
        let controller = UICloudSharingController(share: share, container: CKContainer.default())
        controller.availablePermissions = [.allowPrivate, .allowReadOnly]
        let delegate = Delegate(title: title)
        self.delegate = delegate
        controller.delegate = delegate

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        if let popover = controller.popoverPresentationController {   // iPad
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private final class Delegate: NSObject, UICloudSharingControllerDelegate {
        let title: String
        init(title: String) { self.title = title }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            CloudService.shared.shareError = error.localizedDescription
        }
    }
    #endif

    /// Opens the invite sheet for a shared agreement.
    static func invite(to agreement: Agreement) async throws {
        #if os(iOS)
        let share = try await CloudService.shared.share(for: agreement)
        present(share, title: agreement.title)
        #endif
    }
}
