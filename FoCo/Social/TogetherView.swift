import SwiftUI

struct TogetherView: View {
    @Environment(SocialStore.self) private var social
    @State private var showPlan = false
    @State private var showCheckIn = false
    @State private var showHeading = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showFriends = false
    @State private var planFor: Plan?

    var body: some View {
        NavigationStack {
            List {
                if social.isLocalDemo {
                    Section { DemoBanner() }
                }

                if social.isOffline {
                    Section { OfflineNote() }
                }

                if !social.invites.isEmpty {
                    Section("Invites for you") {
                        ForEach(social.invites) { plan in
                            PlanCard(plan: plan, prominent: true)
                        }
                    }
                }

                Section {
                    // Checking in is automatic, so the two things you do by hand lead the screen.
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        Button { showHeading = true } label: {
                            ActionTile(title: social.myHeading == nil ? "Going soon" : "Change time", icon: "figure.walk")
                        }
                        Button { showPlan = true } label: {
                            ActionTile(title: "Plan a meal", icon: "calendar.badge.plus")
                        }
                    }
                    .buttonStyle(ActionTileStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    if let mine = social.myCheckin {
                        MyCheckinRow(checkin: mine)
                    }
                    if social.friendsHere.isEmpty {
                        if social.loadedTogether && !social.friends.isEmpty {
                            Text(social.myCheckin == nil
                                 ? "None of your friends are at FoCo right now."
                                 : "None of your friends are here yet. They'll see you're here.")
                                .foregroundStyle(.secondary)
                        } else if social.loadedTogether {
                            Text("Friends at FoCo show up here.").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(social.friendsHere) { FriendHereRow(checkin: $0) }
                    }
                    // Without automatic check-in (off, or no location access), the only way to show up here.
                    if social.myCheckin == nil && !PresenceMonitor.shared.isWorking {
                        Button { showCheckIn = true } label: {
                            Label("Check in manually", systemImage: "hand.tap")
                        }
                    }
                } header: {
                    Text("At FoCo now")
                }

                if social.myHeading != nil || !social.friendsHeading.isEmpty {
                    Section {
                        if let mine = social.myHeading { MyHeadingRow(checkin: mine) }
                        ForEach(social.friendsHeading) { FriendHeadingRow(checkin: $0) }
                    } header: {
                        Text("Heading over")
                    }
                }

                Section {
                    if social.upcoming.isEmpty {
                        if social.loadedTogether {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No plans yet this week.")
                                Button("Start one") { showPlan = true }
                            }
                            .foregroundStyle(.secondary)
                        } else if !social.isOffline {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                    } else {
                        ForEach(social.upcoming) { plan in
                            PlanCard(plan: plan, prominent: false)
                                .swipeActions {
                                    if plan.host.id == social.myId {
                                        Button("Cancel plan", role: .destructive) { Task { await social.cancel(plan) } }
                                            .tint(.red)
                                    } else {
                                        Button("Remove", role: .destructive) { Task { await social.hide(plan) } }
                                            .tint(.red)
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Coming up")
                } footer: {
                    Text("Swipe left to remove a plan. Only friends can see your plans and check-ins.")
                }

                Section {
                    AutoCheckinSetting()
                } footer: {
                    Text("During meals, friends see you're at FoCo when you walk in, and you're checked out when you leave.")
                }

                if social.loadedPeople && social.friends.isEmpty && social.incoming.isEmpty {
                    Section { AddFriendsCard(findFriends: { showFriends = true }) }
                }
            }
            .navigationTitle("Together")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFriends = true } label: {
                        Image(systemName: "person.2")
                            .overlay(alignment: .topTrailing) {
                                if !social.incoming.isEmpty {
                                    Text("\(social.incoming.count)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(.red, in: .circle)
                                        .offset(x: 10, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel(social.incoming.isEmpty ? "Friends" : "Friends, \(social.incoming.count) new requests")
                }
            }
            .refreshable { await social.refreshAll() }
            .task {
                // Who's here refreshes every 30 s. During a meal, automatic check-in also takes a location reading then,
                // since iOS can take minutes to report walking in while the app is open.
                while !Task.isCancelled {
                    await social.refreshTogether()
                    if Meal.serving() != nil { PresenceMonitor.shared.refresh() }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .sheet(isPresented: $showPlan) { PlanComposer() }
            .sheet(isPresented: $showCheckIn) { CheckInSheet() }
            .sheet(isPresented: $showHeading) { HeadingSheet() }
            .sheet(isPresented: $showFriends) { FriendsView() }
            .toastHost()
        }
    }
}

/// One of the two big buttons at the top of Together: an icon over its name on Dartmouth Green.
private struct ActionTile: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold))
            Text(title).font(.headline)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 112)
        .padding(.vertical, 6)
        // The real Dartmouth Green in light and dark mode (the accent color is lighter in dark mode).
        .background(Color(red: 0, green: 0x69 / 255, blue: 0x3e / 255).gradient, in: .rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
    }
}

private struct ActionTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Shown when the app can't reach the server, in place of spinners.
struct OfflineNote: View {
    var body: some View {
        Label("No connection. Pull down to try again.", systemImage: "wifi.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// For someone with no friends on the app yet: the first thing to do.
private struct AddFriendsCard: View {
    let findFriends: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add your friends").font(.headline)
            Text("See when they're at FoCo and plan meals together. Find people by name, or text friends who aren't on FoCo Social yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: findFriends) { Text("Find friends").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.borderedProminent)
                InviteByTextButton { Text("Invite by text").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

private struct MyCheckinRow: View {
    @Environment(SocialStore.self) private var social
    let checkin: Checkin

    private var room: String? { checkin.spot.flatMap { FoCoRoom.all.contains($0) ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(person: checkin.user, size: 44, ring: .dartmouthGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're here").font(.headline)
                    Text([checkin.spot, "until \(checkin.expiresAt.formatted(date: .omitted, time: .shortened))"].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Leave") { Task { await social.checkOut() } }
                    .buttonStyle(.bordered)
            }
            .accessibilityElement(children: .combine)
            if room == nil {
                Text("Which room? Helps friends find you.").font(.caption).foregroundStyle(.secondary)
            }
            FlowLayout {
                ForEach(FoCoRoom.all, id: \.self) { r in
                    Chip(title: r, selected: room == r) { Task { await social.setSpot(r) } }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The same switch as in Me, so it's where you'd look for it.
private struct AutoCheckinSetting: View {
    @Bindable private var presence = PresenceMonitor.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Toggle(isOn: $presence.enabled) {
            Label("Check me in automatically", systemImage: "location")
        }
        if presence.enabled && (presence.isDenied || presence.needsAlways) {
            Button {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label(presence.isDenied
                      ? "Location is off for FoCo Social, so this can't work. Tap to turn it on in Settings."
                      : "Set Location to “Always” in Settings so FoCo Social can check you in when the app is closed.",
                      systemImage: "location.slash")
                    .font(.subheadline)
            }
        }
    }
}

private struct FriendHereRow: View {
    @Environment(SocialStore.self) private var social
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: checkin.user, size: 44, ring: .dartmouthGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkin.user.displayName).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if social.myCheckin == nil && social.myHeading == nil {
                Button("On my way") { Task { await social.headOver(in: 10) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Tells your friends you'll be there in about 10 minutes")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let mins = max(1, Int(Date.now.timeIntervalSince(checkin.startedAt) / 60))
        return [checkin.spot ?? "At FoCo", "here \(mins) min"].joined(separator: " · ")
    }
}

private func arrivalText(_ eta: Date?) -> String {
    guard let eta else { return "soon" }
    let mins = Int(eta.timeIntervalSinceNow / 60)
    if mins <= 1 { return "any minute" }
    return "around \(eta.formatted(date: .omitted, time: .shortened)) · in \(mins) min"
}

private struct MyHeadingRow: View {
    @Environment(SocialStore.self) private var social
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: checkin.user, size: 44, ring: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're heading over").font(.headline)
                Text(arrivalText(checkin.eta)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not going") { Task { await social.checkOut() } }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FriendHeadingRow: View {
    @Environment(SocialStore.self) private var social
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: checkin.user, size: 44, ring: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkin.user.displayName).font(.headline)
                Text(arrivalText(checkin.eta)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if social.myCheckin == nil && social.myHeading == nil, let eta = checkin.eta {
                Button("Me too") {
                    Task { await social.headOver(in: max(1, Int(eta.timeIntervalSinceNow / 60))) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Tells your friends you're going at the same time")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PlanCard: View {
    @Environment(SocialStore.self) private var social
    let plan: Plan
    let prominent: Bool
    @State private var showInvite = false

    private var isHost: Bool { plan.host.id == social.myId }
    private var myStatus: RSVP? { plan.status(of: social.myId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let group = plan.group {
                    Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 44)
                } else {
                    Avatar(person: plan.host, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(plan.timeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isHost {
                    Menu {
                        Button { showInvite = true } label: { Label("Invite friends", systemImage: "person.badge.plus") }
                        // Cancelling shows Undo, so no "are you sure?" (same as swiping the plan).
                        Button(role: .destructive) { Task { await social.cancel(plan) } } label: {
                            Label("Cancel plan", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .accessibilityLabel("Plan options")
                }
            }

            if let note = plan.note, !note.isEmpty {
                Text("“\(note)”").font(.subheadline)
            }

            HStack(spacing: 8) {
                AvatarStack(people: plan.going)
                Text(countLine).font(.caption).foregroundStyle(.secondary)
            }

            if !isHost {
                HStack(spacing: 8) {
                    ForEach([RSVP.going, .maybe, .declined], id: \.self) { status in
                        RSVPButton(status: status, selected: myStatus == status) {
                            Task { await social.respond(plan, status) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, prominent ? 6 : 2)
        .sheet(isPresented: $showInvite) { InviteFriendsSheet(plan: plan) }
    }

    private var title: String {
        let meal = plan.mealKind?.title ?? "Meal"
        if let group = plan.group { return "\(group.name) · \(meal.lowercased())" }
        if isHost { return "Your \(meal.lowercased())" }
        return "\(meal) with \(plan.host.firstName)"
    }

    private var countLine: String {
        var parts = ["\(plan.going.count) going"]
        if !plan.maybe.isEmpty { parts.append("\(plan.maybe.count) maybe") }
        let invited = plan.members.filter { $0.status == .invited }.count
        if invited > 0 && isHost { parts.append("\(invited) invited") }
        return parts.joined(separator: " · ")
    }
}

struct FriendPicker: View {
    let friends: [Person]
    @Binding var selection: Set<UUID>
    var excluded: Set<UUID> = []

    var body: some View {
        if friends.isEmpty {
            Text("Add friends first from the Friends button on the Together tab.").foregroundStyle(.secondary)
        }
        ForEach(friends.filter { !excluded.contains($0.id) }) { friend in
            Button {
                if selection.contains(friend.id) { selection.remove(friend.id) } else { selection.insert(friend.id) }
            } label: {
                HStack(spacing: 12) {
                    Avatar(person: friend, size: 34)
                    Text(friend.displayName).foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: selection.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(friend.id) ? Color.dartmouthGreen : .secondary)
                }
            }
            .accessibilityAddTraits(selection.contains(friend.id) ? .isSelected : [])
        }
    }
}

struct InviteFriendsSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let plan: Plan
    @State private var selection: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                FriendPicker(friends: social.friends, selection: $selection, excluded: Set(plan.members.map(\.user.id)))
            }
            .navigationTitle("Invite friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite \(selection.isEmpty ? "" : "\(selection.count)")") {
                        Task {
                            await social.invite(Array(selection), to: plan)
                            dismiss()
                        }
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}

private struct RSVPButton: View {
    let status: RSVP
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(status == .declined ? "Can't" : status.title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(selected ? (status == .declined ? Color.secondary : Color.dartmouthGreen) : Color.dartmouthGreen.opacity(0.1), in: .capsule)
            .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.dartmouthGreen)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// "Plan cancelled · Undo" and other short notes, shown for a few seconds at the bottom of the screen.
struct ToastBar: View {
    @Environment(SocialStore.self) private var social
    let toast: SocialStore.Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message).font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    social.toast = nil
                    Task { await action() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ToastHost: ViewModifier {
    @Environment(SocialStore.self) private var social

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if let toast = social.toast { ToastBar(toast: toast) }
            }
            .animation(.snappy, value: social.toast?.id)
    }
}

extension View {
    /// Shows the store's toast above the tab bar.
    func toastHost() -> some View { modifier(ToastHost()) }
}
