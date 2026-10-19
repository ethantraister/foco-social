import SwiftUI

struct TogetherView: View {
    @Environment(SocialStore.self) private var social
    @State private var router = AppRouter.shared
    @State private var showPlan = false
    @State private var showCheckIn = false
    @State private var showHeading = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showFriends = false
    @State private var openPlan: UUID?
    @State private var closedAlert: Date?
    @Environment(\.tabIsActive) private var active

    var body: some View {
        NavigationStack {
            List {
                if social.isOffline {
                    Section { OfflineNote() }
                }

                Section {
                    // Checking in is automatic, so the two things you do by hand lead the screen.
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                            Button { showHeading = true } label: {
                                ActionTile(title: social.myHeading == nil ? "Going soon" : "Change time",
                                           detail: social.myHeading == nil ? "Let friends know" : "You're heading over",
                                           icon: "figure.walk")
                            }
                            .accessibilityLabel(social.myHeading == nil ? "Going soon" : "Change time")
                            Button { showPlan = true } label: {
                                ActionTile(title: "Plan a meal", detail: "Pick a time, invite people", icon: "calendar.badge.plus")
                            }
                            .accessibilityLabel("Plan a meal")
                    }
                    .buttonStyle(ActionTileStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !social.invites.isEmpty || !social.groupInvites.isEmpty {
                    Section {
                        ForEach(social.groupInvites) { GroupInviteRow(group: $0) }
                        ForEach(social.invites) { plan in
                            PlanCard(plan: plan, prominent: true) { openPlan = plan.id }
                        }
                    } header: {
                        SectionTitle("Invites for you")
                    }
                }

                Section {
                    if let mine = social.myCheckin {
                        MyCheckinRow(checkin: mine)
                    }
                    if social.friendsHere.isEmpty {
                        if social.loadedTogether && !social.friends.isEmpty {
                            Text(social.myCheckin == nil
                                 ? "None of your friends are at Foco right now."
                                 : "None of your friends are here yet. They'll see you're here.")
                                .foregroundStyle(.secondary)
                        } else if social.loadedTogether {
                            Text("Friends at Foco show up here.").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(social.friendsHere) { FriendHereRow(checkin: $0) }
                    }
                    // Without automatic check-in (off, or no location access), the only way to show up here.
                    if social.myCheckin == nil && !PresenceMonitor.shared.isWorking {
                        Button {
                            if FoCoHours.isOpen(at: .now) { showCheckIn = true } else { closedAlert = .now }
                        } label: {
                            Label("Check in manually", systemImage: "hand.tap")
                        }
                    }
                } header: {
                    SectionTitle("At Foco now")
                }

                if social.myHeading != nil || !social.friendsHeading.isEmpty {
                    Section {
                        if let mine = social.myHeading { MyHeadingRow(checkin: mine) }
                        ForEach(social.friendsHeading) { FriendHeadingRow(checkin: $0) }
                    } header: {
                        SectionTitle("Heading over")
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
                        } else if social.togetherFailed && !social.isOffline {
                            HStack {
                                Text("Couldn't load plans.").foregroundStyle(.secondary)
                                Spacer()
                                Button("Try again") { Task { await social.refreshTogether() } }
                            }
                        } else if !social.isOffline {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        }
                    } else {
                        ForEach(social.upcoming) { plan in
                            PlanCard(plan: plan, prominent: false) { openPlan = plan.id }
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
                    SectionTitle("Coming up")
                } footer: {
                    Text("Tap a plan to see who's coming. Swipe left to remove one.")
                }

                Section {
                    AutoCheckinSetting()
                    ShareWithSetting()
                } footer: {
                    Text("During meals, friends see you're at Foco when you walk in, and you're checked out when you leave.")
                }

                if social.loadedPeople && social.friends.isEmpty && social.incoming.isEmpty {
                    Section { AddFriendsCard(findFriends: { showFriends = true }) }
                }

                if social.isLocalDemo {
                    Section { DemoBanner() }
                }
            }
            .onBackdrop()
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
            .navigationDestination(item: $openPlan) { PlanDetailView(planId: $0) }
            .tabRoot()
            .refreshable { await social.refreshAll() }
            .task(id: active) {
                guard active else { return }
                social.noteUse(.together)
                // Asked when it means something (adding friends, posting going soon or a plan), not on arrival.
                await Push.registerIfAllowed(ask: false)
                // Who's here refreshes every 30 s. During a meal, automatic check-in also takes a location reading then,
                // since iOS can take minutes to report walking in while the app is open.
                while !Task.isCancelled {
                    await social.refreshTogether()
                    if Meal.serving() != nil { PresenceMonitor.shared.refresh() }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: router.pendingPlan, initial: true) {
                guard let plan = router.pendingPlan else { return }
                router.pendingPlan = nil
                openPlan = plan
            }
            .sheet(isPresented: $showPlan) { PlanComposer() }
            .sheet(isPresented: $showCheckIn) { CheckInSheet() }
            .sheet(isPresented: $showHeading) { HeadingSheet() }
            .sheet(isPresented: $showFriends) { FriendsView() }
            .closedAlert($closedAlert)
        }
    }
}

/// One of the two big buttons at the top of Together: Dartmouth Green glass, icon up top, name below.
private struct ActionTile: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.16), in: .circle)
            Spacer(minLength: 20)
            Text(title).font(.system(.title3, design: .serif).weight(.bold))
            Text(detail).font(.footnote.weight(.medium)).opacity(0.82)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(16)
        .glass(in: .rect(cornerRadius: 28), tint: .dartmouthDeep, interactive: true)
        .contentShape(.rect(cornerRadius: 28))
    }
}

private struct ActionTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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

extension View {
    /// "Foco is closed at 9:00 PM", for when you pick a time Foco isn't open.
    func closedAlert(_ time: Binding<Date?>) -> some View {
        alert(time.wrappedValue.map(FoCoHours.closedTitle) ?? "Foco is closed",
              isPresented: Binding(get: { time.wrappedValue != nil }, set: { if !$0 { time.wrappedValue = nil } }),
              presenting: time.wrappedValue) { _ in
            Button("OK", role: .cancel) {}
        } message: { date in
            Text(FoCoHours.closedMessage(at: date))
        }
    }
}

/// For someone with no friends on the app yet: the first thing to do.
private struct AddFriendsCard: View {
    let findFriends: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add your friends").font(.headline)
            Text("See when they're at Foco and plan meals together. Find people by name, or text friends who aren't on Foco Polo yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: findFriends) { Text("Find friends").frame(maxWidth: .infinity, minHeight: 36) }
                    .glassButton(prominent: true)
                InviteByTextButton { Text("Invite by text").frame(maxWidth: .infinity, minHeight: 36) }
                    .glassButton()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

/// "Priya invited you to Rocket Team": join or decline, right on Together.
struct GroupInviteRow: View {
    @Environment(SocialStore.self) private var social
    let group: SocialGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline)
                    Text(line).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                Button { Task { await social.acceptInvite(to: group) } } label: {
                    Text("Join").frame(maxWidth: .infinity, minHeight: 34)
                }
                .glassButton(prominent: true)
                Button { Task { await social.declineInvite(to: group) } } label: {
                    Text("Decline").frame(maxWidth: .infinity, minHeight: 34)
                }
                .glassButton()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private var line: String {
        let who = group.inviter(of: social.myId)?.firstName ?? "Someone"
        let count = group.people.count
        return "\(who) invited you · \(count) member\(count == 1 ? "" : "s")"
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
                    // Which side and who sees it. Not when it runs out: how long you'll stay isn't anyone's business.
                    let detail = [checkin.spot, checkin.audience == .close ? "close friends" : nil].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Leave") { Task { await social.checkOut() } }
                    .glassButton()
            }
            .accessibilityElement(children: .combine)
            if room == nil {
                Text("Which side? Helps friends find you.").font(.caption).foregroundStyle(.secondary)
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

/// The automatic check-in switch, with a way to fix location access when it can't work. On Together, in Me, and on
/// the last step of signing up.
struct AutoCheckinSetting: View {
    @Bindable private var presence = PresenceMonitor.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Toggle(isOn: $presence.enabled) {
            Label("Check me in automatically", systemImage: "location").labelStyle(.tile(.blue))
        }
        if presence.enabled && (presence.isDenied || presence.needsAlways) {
            Button {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label(presence.isDenied
                      ? "Location is off for Foco Polo, so this can't work. Tap to turn it on in Settings."
                      : "Set Location to “Always” in Settings so Foco Polo can check you in when the app is closed.",
                      systemImage: "location.slash")
                    .font(.subheadline)
            }
        }
    }
}

/// Who sees when you're at Foco: all friends, or close friends only. Automatic check-in uses it too.
private struct ShareWithSetting: View {
    @Environment(SocialStore.self) private var social
    @State private var share = ShareWith.friends

    var body: some View {
        Picker(selection: $share) {
            ForEach(ShareWith.allCases) { Text($0.title).tag($0) }
        } label: {
            Label("Who sees when I'm at Foco", systemImage: "person.2.badge.gearshape").labelStyle(.tile(.indigo))
        }
        .onAppear { share = social.defaultShare }
        .onChange(of: share) { social.defaultShare = share }
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
                Button("I'm coming") {
                    Task { await social.headOver(at: .now.addingTimeInterval(10 * 60), spot: checkin.spot, joining: checkin.user.id) }
                }
                .glassButton(prominent: true)
                .accessibilityHint("Tells \(checkin.user.firstName) you'll be there in about 10 minutes")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let mins = max(1, Int(Date.now.timeIntervalSince(checkin.startedAt) / 60))
        let here = mins < 60 ? "\(mins) min" : mins % 60 == 0 ? "\(mins / 60) hr" : "\(mins / 60) hr \(mins % 60) min"
        return [checkin.spot ?? "At Foco", "here \(here)"].joined(separator: " · ")
    }
}

private func arrivalText(_ checkin: Checkin) -> String {
    var parts: [String] = []
    if let eta = checkin.eta {
        let mins = Int(eta.timeIntervalSinceNow / 60)
        parts.append(mins <= 1 ? "any minute" : "around \(eta.formatted(date: .omitted, time: .shortened)) · in \(mins) min")
    } else {
        parts.append("soon")
    }
    if let spot = checkin.spot { parts.append(spot) }
    return parts.joined(separator: " · ")
}

private struct MyHeadingRow: View {
    @Environment(SocialStore.self) private var social
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: checkin.user, size: 44, ring: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're heading over").font(.headline)
                Text(arrivalText(checkin) + (checkin.audience == .close ? " · close friends" : ""))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not going") { Task { await social.checkOut() } }
                .glassButton()
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
                Text(arrivalText(checkin)).font(.subheadline).foregroundStyle(.secondary)
                if checkin.joining == social.myId {
                    Text("Joining you").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            Spacer()
            if social.myCheckin == nil && social.myHeading == nil, let eta = checkin.eta {
                Button("I'm coming") {
                    Task { await social.headOver(at: max(eta, .now.addingTimeInterval(60)), spot: checkin.spot, joining: checkin.user.id) }
                }
                .glassButton(prominent: true)
                .accessibilityHint("Tells \(checkin.user.firstName) you're going at the same time")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PlanCard: View {
    @Environment(SocialStore.self) private var social
    let plan: Plan
    let prominent: Bool
    /// Opens the plan's page: who's coming and (for the host) editing.
    let open: () -> Void

    private var isHost: Bool { plan.host.id == social.myId }
    private var myStatus: RSVP? { plan.status(of: social.myId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    if let group = plan.group {
                        Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 44)
                    } else {
                        Avatar(person: plan.host, size: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title(me: social.myId)).font(.headline).foregroundStyle(Color.primary)
                        Text(plan.timeLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows who's coming")

            if let note = plan.note, !note.isEmpty {
                Text("“\(note)”").font(.subheadline)
            }

            Button(action: open) {
                HStack(spacing: 8) {
                    AvatarStack(people: plan.going)
                    Text(countLine).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(countLine)
            .accessibilityHint("Shows who's coming")

            if !isHost {
                RSVPRow(plan: plan, status: myStatus)
            }
        }
        .padding(.vertical, prominent ? 6 : 2)
    }

    private var countLine: String {
        var parts = ["\(plan.going.count) going"]
        if !plan.maybe.isEmpty { parts.append("\(plan.maybe.count) maybe") }
        if !plan.invitedOnly.isEmpty { parts.append("\(plan.invitedOnly.count) invited") }
        return parts.joined(separator: " · ")
    }
}

/// Going / Maybe / Can't. Tapping your answer again takes it back.
struct RSVPRow: View {
    @Environment(SocialStore.self) private var social
    let plan: Plan
    let status: RSVP?

    var body: some View {
        // Three separate glass buttons (not one glass group, which would melt them into each other).
        HStack(spacing: 10) {
            ForEach([RSVP.going, .maybe, .declined], id: \.self) { option in
                RSVPButton(status: option, selected: status == option) {
                    Task { await social.respond(plan, option) }
                }
            }
        }
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
                    if friend.isClose {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("Close friend")
                    }
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
                Section {
                    FriendPicker(friends: social.recentFriends, selection: $selection, excluded: Set(plan.members.map(\.user.id)))
                } footer: {
                    Text("Friends you've eaten with or invited lately are at the top.")
                }
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
            .foregroundStyle(selected ? Color.white : Color.primary)
            .glass(tint: selected ? (status == .declined ? Color.gray : .dartmouthDeep) : nil, interactive: true)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "Tap again to take back your answer" : "")
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
        .glass(in: .rect(cornerRadius: 24, style: .continuous))
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
    /// Shows the store's toast at the bottom of a sheet. (In the tabs, the app shows it just above the bottom bar.)
    func toastHost() -> some View { modifier(ToastHost()) }
}
