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

                Section("Food") {
                    NavigationLink { DietForm() } label: { Label("My diet", systemImage: "leaf") }
                    NavigationLink { RequestsForm() } label: { Label("Food requests", systemImage: "hand.raised") }
                }

                Section {
                    NavigationLink { AboutView() } label: { Label("About", systemImage: "info.circle") }
                }

                if social.phase != .signedOut {
                    Section {
                        Button("Sign out") { confirmSignOut = true }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            HStack { Text("Delete my account"); if deleting { Spacer(); ProgressView() } }
                        }
                        .disabled(deleting)
                    } footer: {
                        Text("Deleting removes your profile, posts, photos, plans, and friends for good.")
                    }
                }
            }
            .navigationTitle("Me")
            .sheet(isPresented: $editing) { EditProfileSheet() }
            .sheet(isPresented: $signingIn) { SignInSheet(reason: "Sign in to eat with friends and post to the feed.") }
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
                Text("Your profile, posts, photos, plans, and friends are removed for good. This can't be undone.")
            }
        }
    }

    @ViewBuilder private var account: some View {
        switch social.phase {
        case .ready:
            if let me = social.me {
                Section {
                    HStack(spacing: 14) {
                        Avatar(person: me, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(me.name).font(.title2.bold())
                            if let year = me.classYear { Text("Class of \(String(year))").font(.subheadline).foregroundStyle(.secondary) }
                            if let email = social.email {
                                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = true }.buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                NavigationLink {
                    FriendsView(embedded: true)
                } label: {
                    Label("Friends and groups", systemImage: "person.2")
                        .badge(social.incoming.count)
                }
                InviteByTextButton {
                    Label("Invite friends by text", systemImage: "message")
                }
                Toggle(isOn: Bindable(PresenceMonitor.shared).enabled) {
                    Label("Check in automatically at FoCo", systemImage: "location")
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

    /// SUPPORT_EMAIL in Info.plist; shown as "Contact us" (App Store apps with posts need a published way to reach you).
    static var supportEmail: URL? {
        let address = (Bundle.main.object(forInfoDictionaryKey: "SUPPORT_EMAIL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return nil }
        return URL(string: "mailto:\(address)?subject=FoCo%20Social%20\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
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
                NavigationLink { CommunityRulesView() } label: { Label("Community rules", systemImage: "checkmark.shield") }
                if social.phase == .ready {
                    NavigationLink { BlockedPeopleView() } label: { Label("Blocked people", systemImage: "hand.raised.slash") }
                }
                NavigationLink { PrivacyView() } label: { Label("Privacy", systemImage: "lock") }
                if let support = AppInfo.supportEmail {
                    Link(destination: support) {
                        Label("Contact us", systemImage: "envelope")
                    }
                }
            }
            if social.isLocalDemo {
                Section {
                    LabeledContent {
                        Text("Local test server")
                    } label: {
                        Label("Server", systemImage: "server.rack")
                    }
                }
            }
            Section {
            } footer: {
                Text(AppInfo.versionLine).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CommunityRulesView: View {
    var body: some View {
        List {
            Section {
                Text("Be kind. No harassment, hate, nudity, or photos of people without their OK.")
                Text("Reported posts are hidden after three reports, and accounts that break the rules are removed.")
                Text("Block anyone from the ••• menu on their post or from your friends list. Unblock them in About → Blocked people.")
            }
        }
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
                        .buttonStyle(.bordered)
                }
            }
        }
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
                Text("FoCo Social is a student-made app for '53 Commons. It isn't run by Dartmouth College or Dartmouth Dining. No ads, no tracking, and your data is never sold.")
            }
            Section("Without an account") {
                Text("Your diet settings and the foods you follow stay on your phone. The menu comes from Dartmouth Dining's public menu.")
            }
            Section("Your account") {
                Text("Your Dartmouth email address (to sign in; other students never see it), name, class year, and profile photo if you add one.")
            }
            Section("What you share, and who sees it") {
                Text("Name, class year, and profile picture: other signed-in Dartmouth students, so they can find you.")
                Text("Check-ins (at FoCo, which room, when you'll arrive): only your friends. They disappear on their own within 3 hours.")
                Text("Meal plans: the friends, people, or group you post them to.")
                Text("Plate photos and captions: signed-in Dartmouth students. Photos are stored at hard-to-guess web addresses; anyone with the exact address can open one.")
                Text("Group name and photo: people in the group.")
                Text("Food requests: Dartmouth Dining gets one email a day with each food and how many students asked. Never names.")
                Text("Blocking someone hides your posts, plans, and check-ins from each other.")
            }
            Section("Location") {
                Text("Only if you turn on automatic check-in. Your phone checks whether you're at FoCo; your location never leaves your phone, and friends only see that you're there.")
            }
            Section("Where it's kept") {
                Text("Accounts, posts, and photos are stored with Supabase, a hosted database service. Sign-in codes are emailed through Gmail.")
            }
            Section("Deleting") {
                Text("Delete a post from its ••• menu. Me → Delete my account removes your profile, posts, photos, plans, check-ins, friends, and requests for good.")
            }
            if let support = AppInfo.supportEmail {
                Section("Questions") {
                    Link("Email us", destination: support)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
