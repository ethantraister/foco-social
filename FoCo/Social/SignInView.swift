import PhotosUI
import SwiftUI

/// Shown in place of the social tabs until you're signed in with a profile.
struct SignInGate<Content: View>: View {
    @Environment(SocialStore.self) private var social
    let reason: String
    /// Set when the gate is shown in a sheet, to offer a Cancel button.
    var onCancel: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch social.phase {
        case .ready: content()
        case .loading: NavigationStack { ProfileLoadingView().toolbar { cancelButton }.tabRoot() }
        case .needsProfile: NavigationStack { ProfileSetupView().toolbar { cancelButton }.tabRoot() }
        // In a sheet the keyboard comes up right away; on a tab it waits for a tap, so the bottom bar stays.
        case .signedOut: NavigationStack { SignInView(reason: reason, autofocus: onCancel != nil).toolbar { cancelButton }.tabRoot() }
        }
    }

    @ToolbarContentBuilder private var cancelButton: some ToolbarContent {
        if let onCancel {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        }
    }
}

/// Sign in from somewhere that works without an account (Me, food requests, a dish): a sheet that closes itself once you're in.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reason: String

    var body: some View {
        SignInGate(reason: reason, onCancel: { dismiss() }) {
            Color.clear.onAppear { dismiss() }
        }
    }
}

/// Signed in, waiting for your profile. Only seen the first time on a phone.
private struct ProfileLoadingView: View {
    @Environment(SocialStore.self) private var social

    var body: some View {
        Group {
            if social.loadFailed {
                ContentUnavailableView {
                    Label("Can't reach FoCo Social", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try again") { Task { await social.bootstrap() } }
                        .glassButton(prominent: true)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SignInView: View {
    @Environment(SocialStore.self) private var social
    let reason: String
    var autofocus = true
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var sentTo: String?
    @State private var sentAt: Date?
    @State private var working = false
    @FocusState private var focused: Bool

    /// Supabase sends at most one code a minute to the same address.
    private static let resendDelay: TimeInterval = 60

    private var normalized: String {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        return e.contains("@") ? e : e + "@dartmouth.edu"
    }
    private var validEmail: Bool { normalized.hasSuffix("@dartmouth.edu") && normalized.count > "@dartmouth.edu".count }

    /// The App Review account can't receive the emailed code, so it signs in with a password (set REVIEW_NETID in Info.plist).
    private var isReviewAccount: Bool {
        let review = (Bundle.main.object(forInfoDictionaryKey: "REVIEW_NETID") as? String ?? "").lowercased()
        return !review.isEmpty && normalized == review + "@dartmouth.edu"
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    BrandHeader(title: "Eat with friends", subtitle: reason)
                }
                .listRowBackground(Color.clear)

                if let sentTo {
                    Section {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title2.monospacedDigit())
                            .focused($focused)
                            .disabled(working)
                            .onChange(of: code) {
                                // Digits only; a pasted or autofilled code signs you in without another tap.
                                let digits = String(code.filter(\.isNumber).prefix(6))
                                if digits != code { code = digits }
                                if digits.count == 6 && !working { Task { await verify(sentTo) } }
                            }
                        Button {
                            Task { await verify(sentTo) }
                        } label: {
                            HStack { Text("Sign in"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(code.count < 6 || working)
                    } header: {
                        Text("Enter the code we emailed to \(sentTo)")
                    } footer: {
                        VStack(alignment: .leading, spacing: 10) {
                            if social.isLocalDemo { Text("Local test server: the code is printed in the server window, and 123456 always works.") }
                            Text("It can take a minute to arrive. Check your junk folder too.")
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let wait = Int(ceil((sentAt ?? .distantPast).addingTimeInterval(Self.resendDelay).timeIntervalSince(context.date)))
                                Button(wait > 0 ? "Send a new code in \(wait)s" : "Send a new code") {
                                    Task { await sendCode(to: sentTo) }
                                }
                                .disabled(wait > 0 || working)
                            }
                            Button("Use a different NetID") { self.sentTo = nil; code = "" }
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 2) {
                            TextField("NetID", text: $email)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .submitLabel(.continue)
                                .focused($focused)
                                .onSubmit { if validEmail && !isReviewAccount { Task { await sendCode(to: normalized) } } }
                            if !email.contains("@") {
                                Text("@dartmouth.edu").foregroundStyle(.secondary)
                            }
                        }
                        if isReviewAccount {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                            Button {
                                Task {
                                    working = true
                                    _ = await social.signIn(email: normalized, password: password)
                                    working = false
                                }
                            } label: {
                                HStack { Text("Sign in"); if working { Spacer(); ProgressView() } }
                            }
                            .disabled(password.isEmpty || working)
                            .id("reviewSignIn")
                        } else {
                            Button {
                                Task { await sendCode(to: normalized) }
                            } label: {
                                HStack { Text("Email me a code"); if working { Spacer(); ProgressView() } }
                            }
                            .disabled(!validEmail || working)
                        }
                    } header: {
                        Text("Your NetID")
                    } footer: {
                        Text(verbatim: "Type your NetID (like f00abcd) and we'll email a sign-in code to NetID@dartmouth.edu. Only Dartmouth students can join. No password needed.")
                    }
                }
            }
            // The password and its Sign in button appear under the NetID, where the keyboard would cover them.
            .onChange(of: isReviewAccount) { _, review in
                if review { withAnimation { proxy.scrollTo("reviewSignIn", anchor: .bottom) } }
            }
        }
        .onBackdrop()
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sentTo) {
            // Always for the emailed code; for the NetID only when asked (not on a tab, where it would hide the bottom bar).
            guard sentTo != nil || autofocus else { return }
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    private func sendCode(to address: String) async {
        working = true
        if await social.sendCode(to: address) {
            sentTo = address
            sentAt = .now
            code = ""
        }
        working = false
    }

    private func verify(_ address: String) async {
        guard !working else { return }
        working = true
        if !(await social.verify(email: address, code: code)) { code = "" }
        working = false
    }
}

struct ProfileSetupView: View {
    @Environment(SocialStore.self) private var social
    @State private var name = ""
    @State private var classYear = 2030
    @State private var photo: UIImage?
    @State private var removeSaved = false
    @State private var agreed = false
    @State private var working = false

    var body: some View {
        Form {
            Section {
                ProfilePictureEditor(name: name, newPhoto: $photo, removeSaved: $removeSaved, savedPath: nil)
            }
            .listRowBackground(Color.clear)

            Section {
                TextField("First and last name", text: $name)
                    .textContentType(.name)
                Picker("Class of", selection: $classYear) {
                    ForEach(2026...2033, id: \.self) { Text(String($0)).tag($0) }
                }
            } header: {
                Text("How friends will see you")
            }

            Section {
                Toggle(isOn: $agreed) {
                    Text("I'll keep it kind: no harassment, hate, nudity, or posting people without asking. Messages that break this get removed and accounts banned.")
                        .font(.subheadline)
                }
            } header: {
                Text("Community rules")
            }

            Section {
                Button {
                    Task {
                        working = true
                        _ = await social.createProfile(name: name.trimmingCharacters(in: .whitespaces), classYear: classYear, photo: photo)
                        working = false
                    }
                } label: {
                    ZStack {
                        Text("Join FoCo Social").font(.headline).opacity(working ? 0 : 1)
                        if working { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .glassButton(prominent: true)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !agreed || working)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Button("Use a different NetID") { social.signOut() }
                    .font(.footnote)
                    .padding(.top, 8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onBackdrop()
        .navigationTitle("Set up your profile")
    }
}

struct Avatar: View {
    @Environment(SocialStore.self) private var social
    let person: Person
    var size: CGFloat = 40
    var ring: Color? = nil

    var body: some View {
        Group {
            if let path = person.photoPath {
                RemoteImage(url: social.photoURL(path: path), maxPixels: size * 3) { initials }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().stroke(ring ?? .clear, lineWidth: 2.5))
        .accessibilityHidden(true)
    }

    /// No photo: initials on a color that stays the same for each person.
    private var initials: some View {
        ZStack {
            Circle().fill(Self.tints[Int(person.id.uuid.15) % Self.tints.count].gradient)
            if let letters = Self.initials(person.name) {
                Text(letters)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white)
            }
        }
    }

    /// Dark enough for white letters in light and dark mode.
    private static let tints: [Color] = [
        Color(red: 0.00, green: 0.41, blue: 0.24), Color(red: 0.16, green: 0.42, blue: 0.55),
        Color(red: 0.33, green: 0.31, blue: 0.62), Color(red: 0.55, green: 0.27, blue: 0.48),
        Color(red: 0.70, green: 0.33, blue: 0.20), Color(red: 0.42, green: 0.40, blue: 0.16),
    ]

    /// "Ethan Traister" → "ET", "Ethan" → "E".
    static func initials(_ name: String) -> String? {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return nil }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }
}

extension Avatar {
    /// A group's picture: its photo, or its initials.
    init(groupId: UUID, name: String, photoPath: String?, size: CGFloat = 40) {
        self.init(person: Person(id: groupId, name: name, emoji: "", photoPath: photoPath), size: size)
    }
}

struct AvatarStack: View {
    let people: [Person]
    var max = 5
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(people.prefix(max)) { Avatar(person: $0, size: size).background(Circle().fill(Color(uiColor: .systemBackground))) }
            if people.count > max {
                Text("+\(people.count - max)")
                    .font(.caption2.bold())
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.2), in: .circle)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(ListFormatter.localizedString(byJoining: people.map(\.name)))
    }
}

struct DemoBanner: View {
    var body: some View {
        Label("Local test server: these people, plans, and messages are made up so you can try things out.", systemImage: "testtube.2")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
