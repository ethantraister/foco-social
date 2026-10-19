import MessageUI
import SwiftUI
import UIKit

/// "Invite friends by text": opens Messages with an invite already written. Pick who to send it to in the To: field.
enum AppInvite {
    /// Set APP_STORE_URL in Info.plist once the app has an App Store (or TestFlight) link; until then the text has no link.
    static var link: URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "APP_STORE_URL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : URL(string: raw)
    }

    static func message(from me: Person?) -> String {
        var text = "Get FOCO Social so we can see when we're both at FOCO and plan meals together. Sign in with your NetID"
        if let me { text += ", then add me: \(me.name)" }
        text += "."
        if let link { text += "\n\n\(link.absoluteString)" }
        return text
    }
}

/// A button that opens Messages with the invite.
struct InviteByTextButton<Label: View>: View {
    @Environment(SocialStore.self) private var social
    @ViewBuilder var label: () -> Label

    var body: some View {
        TextMessageButton(message: { AppInvite.message(from: social.me) }, label: label)
    }
}

/// A button that opens Messages with a message already written (you pick who it goes to), or the share sheet on
/// devices that can't text. Conversations stay in the group chats people already have.
struct TextMessageButton<Label: View>: View {
    let message: () -> String
    @ViewBuilder var label: () -> Label
    @State private var composing = false

    var body: some View {
        Button { composing = true } label: { label() }
            .sheet(isPresented: $composing) {
                let body = message()
                if MFMessageComposeViewController.canSendText() {
                    MessageComposer(body: body).ignoresSafeArea()
                } else {
                    ShareSheet(items: [body]).presentationDetents([.medium, .large])
                }
            }
    }
}

struct MessageComposer: UIViewControllerRepresentable {
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            dismiss()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
