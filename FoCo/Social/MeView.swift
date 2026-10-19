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
                    NavigationLink { DietForm() } label: { Label("My diet", systemImage: "leaf").labelStyle(.tile(.teal)) }
                    NavigationLink { FoodAlertsView() } label: { Label("Food alerts", systemImage: "bell").labelStyle(.tile(.orange)) }
                } header: {
                    SectionTitle("Food")
                }

                if social.phase == .ready {
                    Section {
                        NavigationLink { NotificationSettingsView() } label: { Label("Notifications", systemImage: "bell.badge").labelStyle(.tile(.red)) }
                    }
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
            .sheet(isPresented: $signingIn) { SignInSheet(reason: "Sign in to see when friends are at FoCo and plan meals together.") }
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
                    Label("Check in automatically at FoCo", systemImage: "location").labelStyle(.tile(.blue))
                }
            } footer: {
                Text("Friends see you're at FoCo when you walk in during a meal, and you're checked out when you leave.")
            }
        case .loading:
            Section {
                if social.loadFailed {
                    Button("Can't reach FoCo Social. Tap to try again.") { Task { await social.bootstrap() } }
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
        return "FoCo Social \(version) (\(build))"
    }

    /// SUPPORT_EMAIL in Info.plist; shown as "Contact us" (App Store apps with profiles need a published way to reach you).
    static var supportEmail: URL? {
        guard let address = supportAddress else { return nil }
        return URL(string: "mailto:\(address)?subject=FoCo%20Social%20\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
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

/// Community rules, blocked people, privacy, and how to reach us, out of the way of everyday settings.
struct AboutView: View {
    @Environment(SocialStore.self) private var social

    var body: some View {
        List {
            Section {
                NavigationLink { CommunityRulesView() } label: { Label("Community rules", systemImage: "checkmark.shield").labelStyle(.tile(.dartmouthDeep)) }
                if social.phase == .ready {
                    NavigationLink { BlockedPeopleView() } label: { Label("Blocked people", systemImage: "hand.raised.slash").labelStyle(.tile(.red)) }
                }
                NavigationLink { PrivacyView() } label: { Label("Privacy", systemImage: "lock").labelStyle(.tile(.blue)) }
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

struct CommunityRulesView: View {
    var body: some View {
        List {
            Section {
                Text("Be kind. No harassment, hate, nudity, or photos of people without their OK.")
                Text("Report someone by pressing and holding their name. Reports are reviewed, and accounts that break the rules are removed.")
                Text("Block anyone the same way, or by swiping on them in your friends list. Unblock them in About → Blocked people.")
            }
        }
        .onBackdrop()
        .navigationTitle("Community rules")
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

/// The privacy policy, in plain words. Keep it in sync with the hosted copy in docs/privacy.html.
struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("FoCo Social is a student-made app for '53 Commons. It isn't run by Dartmouth College or Dartmouth Dining. No ads, nothing that follows you across other apps, and your data is never sold.")
            }
            Section("Without an account") {
                Text("Your diet settings and the foods you follow stay on your phone. The menu comes from Dartmouth Dining's public menu.")
            }
            Section("Your account") {
                Text("Your Dartmouth email address (to sign in; other students never see it), name, class year, and profile photo if you add one.")
                Text("Which features you used on which day, like opening the menu or posting going soon. No times, places, or anything you wrote. It only tells us what's working, and only we see it.")
            }
            Section("What you share, and who sees it") {
                Text("Name, class year, and profile picture: other signed-in Dartmouth students, so they can find you.")
                Text("Check-ins (at FoCo, which side, when you'll arrive): your friends, or only your close friends if you pick that. They disappear on their own within 3 hours.")
                Text("Meal plans: the friends, people, or group you post them to. Everyone invited to a plan can see who else is invited.")
                Text("Your close friends list: only you.")
                Text("Group name and photo: people in the group, and people invited to it.")
                Text("Blocking someone hides your plans and check-ins from each other.")
            }
            Section("Location") {
                Text("Only if you turn on automatic check-in. Your phone checks whether you're at FoCo; your location never leaves your phone, and friends only see that you're there.")
            }
            Section("Notifications") {
                Text("If you allow notifications, your phone's notification address is stored so friends' going soon and invites can reach you. Choose what you get in Me → Notifications.")
            }
            Section("Where it's kept") {
                Text("Accounts, plans, and photos are stored with Supabase, a hosted database service. Notifications are delivered by Apple. Sign-in codes are emailed through Gmail.")
            }
            Section("Deleting") {
                Text("Me → Delete my account removes your profile, photos, plans, check-ins, friends, and feature counts for good, plus anything from earlier test versions (like messages).")
            }
            if let support = AppInfo.supportEmail {
                Section("Questions") {
                    Link("Email us", destination: support)
                }
            }
        }
        .onBackdrop()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
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
                        Label("Notifications are off for FoCo Social. Tap to turn them on in Settings.", systemImage: "bell.slash")
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
                    Label("Friends getting to FoCo", systemImage: "fork.knife").labelStyle(.tile(.orange))
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
