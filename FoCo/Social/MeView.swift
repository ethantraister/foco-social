import UserNotifications
import SwiftUI

struct MeView: View {
    @Environment(SocialStore.self) private var social
    @State private var editing = false
    @State private var signingIn = false
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            List {
                account

                Section {
                    NavigationLink { DietForm() } label: { Label("My diet", systemImage: "carrot.fill").labelStyle(.tile(.orange)) }
                    if social.phase == .ready {
                        NavigationLink { NotificationSettingsView() } label: { Label("Notifications", systemImage: "bell.badge").labelStyle(.tile(.red)) }
                    }
                } header: {
                    SectionTitle("Preferences")
                }

                Section {
                    NavigationLink { AboutView() } label: { Label("About", systemImage: "info").labelStyle(.tile(.gray)) }
                }

                if social.phase != .signedOut {
                    Section {
                        Button("Sign out") { confirmSignOut = true }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            HStack { Text("Delete my account"); if deleting { Spacer(); ProgressView() } }
                        }
                        .disabled(deleting)
                    } footer: {
                        Text("Deleting removes your profile, photos, plans, and friends for good.")
                    }
                }
            }
            .onBackdrop()
            .navigationTitle("Me")
            .tabRoot()
            .sheet(isPresented: $editing) { EditProfileSheet() }
            .sheet(isPresented: $signingIn) { SignInSheet(reason: "Sign in to see when friends are at Foco and plan meals together.") }
            // Both in the middle of the screen, laid out the same: a title, a line, and two short buttons side by side
            // (a long button label makes iOS stack them).
            .alert("Sign out?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { social.signOut() }
            } message: {
                Text("You can sign back in with your NetID anytime.")
            }
            .alert("Delete your account?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        deleting = true
                        _ = await social.deleteAccount()
                        deleting = false
                    }
                }
            } message: {
                Text("Your profile, photos, plans, and friends are removed for good. This can't be undone.")
            }
        }
    }

    @ViewBuilder private var account: some View {
        switch social.phase {
        case .ready:
            if let me = social.me {
                // You, on the backdrop rather than in a card: big photo, name, and an Edit button.
                Section {
                    VStack(spacing: 6) {
                        Avatar(person: me, size: 96)
                            .padding(4)
                            .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.6)))
                            .padding(.bottom, 6)
                        Text(me.name)
                            .font(.system(.title, design: .serif).weight(.bold))
                            .multilineTextAlignment(.center)
                        Text([me.classYear.map { "Class of \(String($0))" }, social.email].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Button("Edit profile") { editing = true }
                            .glassButton()
                            .controlSize(.regular)
                            .padding(.top, 8)
                            .accessibilityLabel("Edit")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)
            }
            Section {
                NavigationLink {
                    FriendsView(embedded: true)
                } label: {
                    Label("Friends and groups", systemImage: "person.2").labelStyle(.tile(.indigo))
                        .badge(social.incoming.count)
                }
                InviteByTextButton {
                    Label("Invite friends by text", systemImage: "message").labelStyle(.tile(.green))
                }
                Toggle(isOn: Bindable(PresenceMonitor.shared).enabled) {
                    Label("Check in automatically at Foco", systemImage: "location").labelStyle(.tile(.blue))
                }
            } footer: {
                Text("Friends see you're at Foco when you walk in during a meal, and you're checked out when you leave.")
            }
        case .loading:
            Section {
                if social.loadFailed {
                    Button("Can't reach Foco Social. Tap to try again.") { Task { await social.bootstrap() } }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading your profile…").foregroundStyle(.secondary)
                    }
                }
            }
        case .needsProfile, .signedOut:
            Section {
                Button { signingIn = true } label: {
                    Label(social.phase == .needsProfile ? "Finish setting up your profile" : "Sign in with your NetID",
                          systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("The menu, alerts, and diet tools work without an account.")
            }
        }
    }
}

enum AppInfo {
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Foco Social \(version) (\(build))"
    }

    /// SUPPORT_EMAIL in Info.plist; shown as "Contact us" (App Store apps with profiles need a published way to reach you).
    static var supportEmail: URL? {
        guard let address = supportAddress else { return nil }
        return URL(string: "mailto:\(address)?subject=Foco%20Social%20\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
    }

    /// PRIVACY_POLICY_URL in Info.plist (the hosted docs/privacy.html); shown as "Privacy policy" once it's set.
    /// The App Store needs a privacy policy link inside the app.
    static var privacyPolicy: URL? {
        let address = (Bundle.main.object(forInfoDictionaryKey: "PRIVACY_POLICY_URL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return address.hasPrefix("https://") ? URL(string: address) : nil
    }

    /// "Report Maya": an email to SUPPORT_EMAIL saying who, for a person to look into.
    static func reportEmail(about person: Person) -> URL? {
        guard let address = supportAddress else { return nil }
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = address
        mail.queryItems = [
            URLQueryItem(name: "subject", value: "Report: \(person.name)"),
            URLQueryItem(name: "body", value: "What happened:\n\n\n(Their account, for our records: \(person.id.uuidString.lowercased()))"),
        ]
        return mail.url
    }

    private static var supportAddress: String? {
        let address = (Bundle.main.object(forInfoDictionaryKey: "SUPPORT_EMAIL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }
}

struct EditProfileSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var classYear = 2030
    @State private var photo: UIImage?
    @State private var removeSaved = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfilePictureEditor(name: name, newPhoto: $photo, removeSaved: $removeSaved, savedPath: social.me?.photoPath)
                }
                .listRowBackground(Color.clear)
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Class of", selection: $classYear) {
                        ForEach(2026...2033, id: \.self) { Text(String($0)).tag($0) }
                    }
                }
            }
            .disabled(saving)
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
            .onAppear {
                if let me = social.me {
                    name = me.name
                    classYear = me.classYear ?? 2030
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            saving = true
                            let change: SocialStore.PhotoChange = photo.map { .set($0) }
                                ?? (removeSaved && social.me?.photoPath != nil ? .remove : .keep)
                            let ok = await social.updateProfile(name: name.trimmingCharacters(in: .whitespaces), classYear: classYear, photo: change)
                            saving = false
                            if ok { dismiss() }   // on failure the sheet stays open with your changes
                        }
                    } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }
}

/// Blocked people, the privacy policy, and how to reach us, out of the way of everyday settings.
struct AboutView: View {
    @Environment(SocialStore.self) private var social

    var body: some View {
        List {
            Section {
                if social.phase == .ready {
                    NavigationLink { BlockedPeopleView() } label: { Label("Blocked people", systemImage: "hand.raised.slash").labelStyle(.tile(.red)) }
                }
                if let privacy = AppInfo.privacyPolicy {
                    Link(destination: privacy) {
                        Label("Privacy policy", systemImage: "lock").labelStyle(.tile(.blue))
                    }
                }
                if let support = AppInfo.supportEmail {
                    Link(destination: support) {
                        Label("Contact us", systemImage: "envelope").labelStyle(.tile(.cyan))
                    }
                }
            }
            if social.isLocalDemo {
                Section {
                    LabeledContent {
                        Text("Local test server")
                    } label: {
                        Label("Server", systemImage: "server.rack").labelStyle(.tile(.gray))
                    }
                }
            }
            Section {
            } footer: {
                Text(AppInfo.versionLine).frame(maxWidth: .infinity)
            }
        }
        .onBackdrop()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BlockedPeopleView: View {
    @Environment(SocialStore.self) private var social
    @State private var loaded = false

    var body: some View {
        List {
            if social.blocked.isEmpty {
                if loaded {
                    Text("You haven't blocked anyone.").foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            ForEach(social.blocked) { person in
                PersonRow(person: person) {
                    Button("Unblock") { Task { await social.unblock(person) } }
                        .glassButton()
                }
            }
        }
        .onBackdrop()
        .navigationTitle("Blocked people")
        .task {
            await social.refreshBlocked()
            loaded = true
        }
    }
}

/// What you get notified about. Friends' going soon and arrivals can be everyone, close friends, or off.
struct NotificationSettingsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.openURL) private var openURL
    @State private var settings = NotifySettings()
    @State private var loaded = false
    @State private var maybeReminders = MaybeReminders.enabled
    @State private var allowed = true

    var body: some View {
        Form {
            if !allowed {
                Section {
                    Button {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    } label: {
                        Label("Notifications are off for Foco Social. Tap to turn them on in Settings.", systemImage: "bell.slash")
                    }
                }
            }

            Section {
                Picker(selection: $settings.going) {
                    ForEach(NotifyScope.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Friends going soon", systemImage: "figure.walk").labelStyle(.tile(.dartmouthDeep))
                }
                Picker(selection: $settings.arrivals) {
                    ForEach(NotifyScope.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Friends getting to Foco", systemImage: "fork.knife").labelStyle(.tile(.orange))
                }
                Toggle(isOn: $settings.joins) { Label("Someone joins me", systemImage: "person.2").labelStyle(.tile(.indigo)) }
            } header: {
                Text("Friends")
            } footer: {
                Text("Going soon only notifies you when a friend chooses Notify friends. Close friends are the ones with a star in your friends list. “Someone joins me” is when a friend taps I'm coming, or Going on your plan.")
            }

            Section {
                Toggle(isOn: $settings.plans) { Label("Meal invites and changes", systemImage: "calendar").labelStyle(.tile(.red)) }
                Toggle(isOn: $settings.groups) { Label("Group invites and team meals", systemImage: "person.3").labelStyle(.tile(.purple)) }
                Toggle(isOn: $maybeReminders) { Label("Remind me 30 min before a Maybe", systemImage: "questionmark.circle").labelStyle(.tile(.yellow)) }
            } header: {
                Text("Plans and groups")
            } footer: {
                Text("The Maybe reminder lets you answer Going or Can't make it right from the notification.")
            }

        }
        .onBackdrop()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!loaded)
        .task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            allowed = status != .denied
            await Push.registerIfAllowed(ask: true)
            await social.loadNotifySettings()
            settings = social.notifySettings
            loaded = true
        }
        .onChange(of: settings) {
            guard loaded, settings != social.notifySettings else { return }
            Task { await social.save(settings) }
        }
        .onChange(of: maybeReminders) {
            MaybeReminders.enabled = maybeReminders
            MaybeReminders.schedule(for: social.together.plans.filter { $0.status(of: social.myId) == .maybe })
        }
    }
}
