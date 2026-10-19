import SwiftUI
import UserNotifications

/// Plan a meal, or (with `editing`) change one you're hosting. The meal follows from the time you pick,
/// and times when FOCO is closed are turned away with a popup.
struct PlanComposer: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    var editing: Plan? = nil
    @State private var day = FoCoCalendar.startOfDay(.now)
    @State private var time = PlanComposer.defaultTime(on: FoCoCalendar.startOfDay(.now))
    @State private var audience = Audience.friends
    @State private var invitees: Set<UUID> = []
    @State private var group: UUID?
    @State private var note = ""
    @State private var working = false
    @State private var closedAlert: Date?

    /// The next sensible time: the current meal's usual time if it's still ahead, else soon, on a quarter hour.
    static func defaultTime(on base: Date) -> Date {
        let meal = FoCoCalendar.cal.isDateInToday(base) ? Meal.current : .dinner
        let (h, m) = switch meal {
        case .breakfast: (8, 30)
        case .lunch: (12, 30)
        case .dinner: (18, 0)
        case .lateNight: (22, 0)
        }
        let suggested = FoCoCalendar.cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        if FoCoCalendar.cal.isDateInToday(base) && suggested < .now {
            let next = Date.now.addingTimeInterval(15 * 60)
            let minute = FoCoCalendar.cal.component(.minute, from: next)
            return FoCoCalendar.cal.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: next) ?? next
        }
        return suggested
    }

    /// The day you picked at the time you picked. Times after midnight belong to that night's Late Night.
    private var startsAt: Date {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: time)
        var date = FoCoCalendar.cal.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: day) ?? time
        if (c.hour ?? 0) < 3 { date = FoCoCalendar.adding(days: 1, to: date) }
        return date
    }

    private var meal: Meal? { Meal.at(startsAt) }
    private var isPast: Bool { startsAt < Date.now.addingTimeInterval(-30 * 60) }

    private var valid: Bool {
        !isPast
            && (editing != nil || audience != .invited || !invitees.isEmpty)
            && (editing != nil || audience != .group || group != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DayStrip(selection: $day)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, FoCoCalendar.tz)
                    if isPast {
                        Text("That time has already passed.").font(.footnote).foregroundStyle(.red)
                    } else if let meal {
                        Label(meal.title, systemImage: meal.symbol)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Meal: \(meal.title)")
                    } else {
                        Label("FOCO is closed then", systemImage: "moon.zzz")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                if editing == nil {
                    Section("Who can join") {
                        Picker("Audience", selection: $audience) {
                            ForEach(Audience.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    if audience == .invited {
                        Section {
                            FriendPicker(friends: social.recentFriends, selection: $invitees)
                        } header: {
                            Text("Pick friends")
                        } footer: {
                            Text("Friends you've eaten with lately are at the top.")
                        }
                    } else if audience == .group {
                        Section("Pick a group") {
                            if social.joinedGroups.isEmpty {
                                Text("You're not in any groups yet. Make one from Friends → New group.").foregroundStyle(.secondary)
                            }
                            ForEach(social.joinedGroups) { g in
                                Button {
                                    group = g.id
                                } label: {
                                    HStack(spacing: 12) {
                                        Avatar(groupId: g.id, name: g.name, photoPath: g.photoPath, size: 32)
                                        Text(g.name).foregroundStyle(Color.primary)
                                        Spacer()
                                        Text("\(g.people.count)").foregroundStyle(.secondary)
                                        if group == g.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                }
                                .accessibilityAddTraits(group == g.id ? .isSelected : [])
                            }
                        }
                    }
                }

                Section {
                    TextField("Note, e.g. “window tables” or “after practice”", text: $note, axis: .vertical)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(editing == nil ? "Plan a meal" : "Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: day) { if editing == nil { time = Self.defaultTime(on: day) } }
            .onAppear {
                guard let plan = editing else { return }
                time = plan.startsAt
                // A 12:30 AM late-night plan belongs to the evening before.
                let hour = FoCoCalendar.cal.component(.hour, from: plan.startsAt)
                day = FoCoCalendar.startOfDay(hour < 3 ? FoCoCalendar.adding(days: -1, to: plan.startsAt) : plan.startsAt)
                note = plan.note ?? ""
            }
            .task {
                if social.friends.isEmpty { await social.refreshPeople() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let meal else { closedAlert = startsAt; return }
                        Task {
                            working = true
                            let ok: Bool
                            if let plan = editing {
                                ok = await social.updatePlan(plan, meal: meal, startsAt: startsAt, note: note)
                            } else {
                                ok = await social.createPlan(meal: meal, startsAt: startsAt, note: note, audience: audience,
                                                             group: audience == .group ? group : nil,
                                                             invitees: audience == .invited ? Array(invitees) : [])
                            }
                            working = false
                            if ok { dismiss() }
                            // Now's when hearing back matters: ask for notifications (once; iOS remembers the answer).
                            if ok && editing == nil { await Push.registerIfAllowed(ask: true) }
                        }
                    } label: {
                        if working { ProgressView() } else { Text(editing == nil ? "Post" : "Save").bold() }
                    }
                    .disabled(!valid || working)
                }
            }
            .closedAlert($closedAlert)
        }
    }

    private var footer: String {
        if editing != nil { return "Everyone in the plan keeps their answer and gets a notification about the change." }
        switch audience {
        case .friends: return "All your friends will see this and can tap Going."
        case .invited: return "Only the people you pick will see it. They'll get a notification."
        case .group: return "Everyone in the group will see it."
        }
    }
}

enum FoCoRoom {
    static let all = ["Dark side", "Light side", "Upstairs"]
}

struct CheckInSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var spot: String?
    @State private var minutes = 45
    @State private var share = ShareWith.friends
    @State private var closedAlert: Date?
    @Bindable private var presence = PresenceMonitor.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Which side?") {
                    FlowLayout {
                        ForEach(FoCoRoom.all, id: \.self) { room in
                            Chip(title: room, selected: spot == room) { spot = spot == room ? nil : room }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Picker("Duration", selection: $minutes) {
                        ForEach([30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("For about")
                } footer: {
                    Text("It disappears on its own after \(minutes) minutes.")
                }
                ShareWithPicker(share: $share)
                Section {
                    Toggle("Check me in automatically", isOn: $presence.enabled)
                } footer: {
                    Text("When you walk into FOCO during a meal, your friends see you're there, and you're checked out when you leave. Uses your location only near FOCO.")
                }
                if social.myCheckin != nil {
                    Section {
                        Button("I left FOCO", role: .destructive) {
                            Task { await social.checkOut() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("I'm at FOCO")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                share = social.defaultShare
                if let mine = social.myCheckin {
                    spot = mine.spot.flatMap { FoCoRoom.all.contains($0) ? $0 : nil }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check in") {
                        guard FoCoHours.isOpen(at: .now) else { closedAlert = .now; return }
                        Task { await social.checkIn(spot: spot, minutes: minutes, share: share) }
                        dismiss()
                    }
                    .bold()
                }
            }
            .closedAlert($closedAlert)
        }
        .presentationDetents([.medium, .large])
    }
}

/// All friends or close friends, for one going soon or check-in.
private struct ShareWithPicker: View {
    @Environment(SocialStore.self) private var social
    @Binding var share: ShareWith

    var body: some View {
        Section {
            Picker("Who sees it", selection: $share) {
                ForEach(ShareWith.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Who sees it")
        } footer: {
            if share == .close && social.closeFriends.isEmpty {
                Text("You haven't picked any close friends yet. Tap the star next to a friend in Friends.")
            } else if share == .close {
                Text("Only your close friends: \(ListFormatter.localizedString(byJoining: social.closeFriends.map(\.firstName))).")
            }
        }
    }
}

/// "I'll be at FOCO in…": 15 min, 30 min, 1 hour, or a time you pick, which side, who sees it,
/// and whether friends get a notification (out loud) or just see it on Together (quiet).
struct HeadingSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int? = 30
    @State private var customTime = Date.now.addingTimeInterval(45 * 60)
    @State private var spot: String?
    @State private var share = ShareWith.friends
    @AppStorage("goingLoud") private var loud = false
    @State private var closedAlert: Date?
    @State private var tooLate = false

    private static let options: [(Int, String)] = [(15, "15 min"), (30, "30 min"), (60, "1 hour")]

    /// The time you picked, today (or just after midnight for Late Night).
    private var eta: Date {
        if let minutes { return Date.now.addingTimeInterval(Double(minutes) * 60) }
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: customTime)
        var date = FoCoCalendar.cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: .now) ?? customTime
        if date < Date.now.addingTimeInterval(-5 * 60) { date = FoCoCalendar.adding(days: 1, to: date) }
        return date
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FlowLayout {
                        ForEach(Self.options, id: \.0) { option in
                            Chip(title: option.1, selected: minutes == option.0) { minutes = option.0 }
                        }
                        Chip(title: "Custom", selected: minutes == nil, systemImage: "clock") { minutes = nil }
                    }
                    .padding(.vertical, 4)
                    if minutes == nil {
                        DatePicker("Time", selection: $customTime, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, FoCoCalendar.tz)
                    }
                } header: {
                    Text("I'll be at FOCO in")
                } footer: {
                    Text(FoCoHours.isOpen(at: eta)
                         ? "Around \(eta.formatted(date: .omitted, time: .shortened)). Friends can tap I'm coming."
                         : "FOCO is closed at \(eta.formatted(date: .omitted, time: .shortened)).")
                }

                Section("Which side?") {
                    FlowLayout {
                        ForEach(FoCoRoom.all, id: \.self) { room in
                            Chip(title: room, selected: spot == room) { spot = spot == room ? nil : room }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle(isOn: $loud) {
                        Label("Notify friends", systemImage: loud ? "bell.and.waves.left.and.right" : "bell.slash")
                    }
                } footer: {
                    Text(loud
                         ? "Out loud: friends who want to know get a notification."
                         : "Quiet: friends see it on Together, but nobody gets a notification.")
                }

                ShareWithPicker(share: $share)

                if social.myHeading != nil {
                    Section {
                        Button("Not going anymore", role: .destructive) {
                            Task { await social.checkOut() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Going soon")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                share = social.defaultShare
                if let mine = social.myHeading { spot = mine.spot; share = mine.audience ?? share }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loud ? "Tell friends" : "Post") {
                        let when = eta
                        guard FoCoHours.isOpen(at: when) else { closedAlert = when; return }
                        guard when < Date.now.addingTimeInterval(150 * 60) else { tooLate = true; return }
                        Task {
                            await social.headOver(at: when, spot: spot, share: share, notify: loud)
                            // So you hear when someone's coming too (asks once; iOS remembers the answer).
                            await Push.registerIfAllowed(ask: true)
                        }
                        dismiss()
                    }
                    .bold()
                }
            }
            .closedAlert($closedAlert)
            .alert("That's a while from now", isPresented: $tooLate) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Going soon is for the next couple of hours. For later, use Plan a meal.")
            }
        }
        .presentationDetents([.large])
    }
}

struct FriendsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    /// Right after joining (the last step of signing up): the same screen, with groups left for later.
    var welcome = false
    @State private var notifications: UNAuthorizationStatus = .authorized
    @State private var query = ""
    @State private var results: [Person] = []
    @State private var searching = false
    @State private var showNewGroup = false
    @State private var blocking: Person?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .toastHost()
        }
    }

    private var content: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                Section("People at Dartmouth") {
                    if results.isEmpty {
                        if searching {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("No one by that name has joined yet.").foregroundStyle(.secondary)
                            InviteByTextButton { Label("Invite them by text", systemImage: "message") }
                        }
                    }
                    ForEach(results) { person in
                        PersonRow(person: person) { relationButton(person) }
                    }
                }
            } else {
                if welcome {
                    Section {
                        Text("Add the people you eat with. You'll see when they're at FOCO, and they'll see you.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    // The two switches that make Together work without effort: hearing from friends, and showing up
                    // when you walk in. Both stay off unless you choose them.
                    Section {
                        if notifications == .notDetermined {
                            Button {
                                Task {
                                    await Push.registerIfAllowed(ask: true)
                                    notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                                }
                            } label: {
                                Label("Know when friends head to FOCO", systemImage: "bell.badge").labelStyle(.tile(.red))
                            }
                        }
                        AutoCheckinSetting()
                    } footer: {
                        Text(notifications == .notDetermined
                             ? "Notifications are only what friends do: going soon, joining you, invites. Automatic check-in shows friends you're at FOCO when you walk in during a meal, nothing else. Change either in Me."
                             : "Shows friends you're at FOCO when you walk in during a meal, nothing else. Change it anytime in Me.")
                    }
                }

                if !social.incoming.isEmpty {
                    Section("Friend requests") {
                        ForEach(social.incoming) { FriendRequestRow(person: $0) }
                    }
                }

                if !social.groupInvites.isEmpty {
                    Section("Group invites") {
                        ForEach(social.groupInvites) { GroupInviteRow(group: $0) }
                    }
                }

                // Below friend requests, which are more urgent.
                Section {
                    InviteByTextButton { Label("Invite friends by text", systemImage: "message") }
                } footer: {
                    Text("Opens Messages with an invite to FOCO Social. Pick who to send it to.")
                }

                if !welcome {
                    Section {
                        ForEach(social.joinedGroups) { group in
                            NavigationLink {
                                GroupDetailView(groupId: group.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 40)
                                    VStack(alignment: .leading) {
                                        Text(group.name).font(.headline)
                                        Text("\(group.people.count) members").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Button { showNewGroup = true } label: { Label("New group", systemImage: "plus.circle") }
                    } header: {
                        Text("Groups and teams")
                    } footer: {
                        Text("Plans posted to a group reach everyone in it, like a team dinner after practice.")
                    }
                }

                Section {
                    if social.friends.isEmpty {
                        Text("Search for people by name above to add them.").foregroundStyle(.secondary)
                    }
                    ForEach(social.friends) { person in
                        PersonRow(person: person) { CloseFriendStar(person: person) }
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await social.removeFriend(person) } }
                                Button("Block") { blocking = person }.tint(.gray)
                            }
                    }
                } header: {
                    Text("Friends (\(social.friends.count))")
                } footer: {
                    if !social.friends.isEmpty {
                        Text("★ Close friends: you can share going soon with just them, and choose to only hear about them (Me → Notifications).")
                    }
                }

                if !social.outgoing.isEmpty {
                    Section("Requests you sent") {
                        ForEach(social.outgoing) { person in
                            PersonRow(person: person) {
                                Button("Cancel") { Task { await social.removeFriend(person) } }.glassButton()
                            }
                        }
                    }
                }
            }
        }
        .onBackdrop()
        .navigationTitle(welcome ? "Add your friends" : "Friends")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find people by name")
        .textInputAutocapitalization(.never)
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; searching = false; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = await social.search(q)
            searching = false
        }
        .refreshable { await social.refreshAll() }
        .task {
            if welcome { notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
        }
        .sheet(isPresented: $showNewGroup) { NewGroupSheet() }
        .blockAlert(blocking, isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }))
    }

    @ViewBuilder private func relationButton(_ person: Person) -> some View {
        let relation = social.people.first { $0.id == person.id }?.relation ?? person.relation ?? "none"
        switch relation {
        case "friend": Label("Friends", systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
        case "outgoing": Text("Requested").font(.subheadline).foregroundStyle(.secondary)
        case "incoming": Button("Accept") { Task { await social.accept(person) } }.glassButton(prominent: true)
        default: Button("Add") { Task { await social.addFriend(person) } }.glassButton(prominent: true)
        }
    }
}

/// A friend request: who it's from on one line, then Accept and Decline side by side underneath.
private struct FriendRequestRow: View {
    @Environment(SocialStore.self) private var social
    let person: Person

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(person: person, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName).font(.headline).lineLimit(1)
                    Text("Wants to be friends").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                Button { Task { await social.accept(person) } } label: {
                    Text("Accept").frame(maxWidth: .infinity, minHeight: 34)
                }
                .glassButton(prominent: true)
                .accessibilityLabel("Accept \(person.firstName)")
                Button { Task { await social.removeFriend(person) } } label: {
                    Text("Decline").frame(maxWidth: .infinity, minHeight: 34)
                }
                .glassButton()
                .accessibilityLabel("Decline \(person.firstName)")
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}

/// The star next to a friend: close friend or not.
private struct CloseFriendStar: View {
    @Environment(SocialStore.self) private var social
    let person: Person

    var body: some View {
        let close = social.people.first { $0.id == person.id }?.isClose ?? person.isClose
        Button { Task { await social.setClose(person, !close) } } label: {
            Image(systemName: close ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(close ? Color.orange : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(close ? "\(person.firstName) is a close friend" : "Make \(person.firstName) a close friend")
        .sensoryFeedback(.selection, trigger: close)
    }
}

struct PersonRow<Trailing: View>: View {
    let person: Person
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: person, size: 40)
            Text(person.displayName).font(.body).lineLimit(2)
            Spacer(minLength: 8)
            trailing().fixedSize()
        }
        .modifier(ReportOrBlock(person: person))
    }
}

/// Press and hold anyone else to report or block them. (The App Store asks apps with profiles for both.)
private struct ReportOrBlock: ViewModifier {
    @Environment(SocialStore.self) private var social
    @Environment(\.openURL) private var openURL
    let person: Person
    @State private var blocking = false

    func body(content: Content) -> some View {
        if person.id == social.myId || social.blocked.contains(where: { $0.id == person.id }) {
            content
        } else {
            content
                .contextMenu {
                    if let report = AppInfo.reportEmail(about: person) {
                        Button { openURL(report) } label: { Label("Report \(person.firstName)", systemImage: "flag") }
                    }
                    Button(role: .destructive) { blocking = true } label: { Label("Block \(person.firstName)", systemImage: "hand.raised") }
                }
                .blockAlert(person, isPresented: $blocking)
        }
    }
}

extension View {
    /// "Block Maya?" in the middle of the screen, like the other confirmations.
    func blockAlert(_ person: Person?, isPresented: Binding<Bool>) -> some View {
        modifier(BlockAlert(person: person, isPresented: isPresented))
    }
}

private struct BlockAlert: ViewModifier {
    @Environment(SocialStore.self) private var social
    let person: Person?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("Block \(person?.firstName ?? "")?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) { if let person { Task { await social.block(person) } } }
        } message: {
            Text("You won't see each other's plans or check-ins, and they'll be removed from your friends. You can unblock them from Me → About.")
        }
    }
}

/// Search every signed-up student by name, with your friends (most recent first) ready to add without searching.
/// Groups (teams, clubs, floors) don't require being friends.
struct MemberSearchPicker: View {
    @Environment(SocialStore.self) private var social
    @Binding var selection: [Person]
    var excluded: Set<UUID> = []
    @State private var query = ""
    @State private var results: [Person] = []
    @State private var searching = false

    private var searchingNow: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        Section {
            TextField("Search by name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(results.filter { !excluded.contains($0.id) }) { person in
                row(person)
            }
            if searchingNow && results.isEmpty {
                if searching {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("No one by that name has joined yet.").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Add people")
        } footer: {
            Text("Anyone on FOCO Social, not just friends. They join once they accept. Group members see the group's plans, but only your friends see when you're at FOCO.")
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; searching = false; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = await social.search(q)
            searching = false
        }

        if !selection.isEmpty {
            Section("Adding") {
                ForEach(selection) { row($0) }
            }
        }

        let quick = social.recentFriends.filter { !excluded.contains($0.id) && !selection.contains($0) }
        if !searchingNow && !quick.isEmpty {
            Section("Your friends, most recent first") {
                ForEach(quick) { row($0) }
            }
        }
    }

    private func row(_ person: Person) -> some View {
        let picked = selection.contains { $0.id == person.id }
        return Button {
            if picked { selection.removeAll { $0.id == person.id } } else { selection.append(person) }
        } label: {
            HStack(spacing: 12) {
                Avatar(person: person, size: 34)
                Text(person.displayName).foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.dartmouthGreen : .secondary)
            }
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

struct NewGroupSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photo: UIImage?
    @State private var removePhoto = false
    @State private var members: [Person] = []
    @State private var working = false
    /// Made here so the preview's initials color is the group's real one.
    @State private var groupId = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfilePictureEditor(name: name, newPhoto: $photo, removeSaved: $removePhoto, savedPath: nil,
                                         ownerId: groupId, noun: "group photo")
                }
                .listRowBackground(Color.clear)
                Section("Name") { TextField("e.g. Water Polo, Floor 3, Rocket Team", text: $name) }
                MemberSearchPicker(selection: $members)
            }
            .disabled(working)
            .interactiveDismissDisabled(working)
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            working = true
                            let ok = await social.createGroup(id: groupId, name: name.trimmingCharacters(in: .whitespaces),
                                                              photo: photo, members: members.map(\.id))
                            working = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Create").bold() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
        }
    }
}

struct GroupDetailView: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let groupId: UUID
    @State private var adding = false
    @State private var selection: [Person] = []
    @State private var removing: Person?
    @State private var newOwner: Person?
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var newPhoto: UIImage?
    @State private var removePhoto = false

    private var group: SocialGroup? { social.groups.first { $0.id == groupId } }

    var body: some View {
        List {
            if let group {
                let iOwn = group.isOwner(social.myId)
                Section {
                    if iOwn {
                        ProfilePictureEditor(name: group.name, newPhoto: $newPhoto, removeSaved: $removePhoto, savedPath: group.photoPath,
                                             ownerId: group.id, noun: "group photo")
                    } else {
                        Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 140)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .listRowBackground(Color.clear)
                if !group.hasJoined(social.myId) {
                    Section {
                        GroupInviteRow(group: group)
                    } footer: {
                        Text("Join to see the group's meal plans.")
                    }
                }
                Section("\(group.people.count) members") {
                    ForEach(group.people) { person in
                        PersonRow(person: person) {
                            HStack(spacing: 8) {
                                if group.isOwner(person.id) {
                                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                                }
                                FriendButton(person: person)
                                if iOwn && person.id != social.myId {
                                    Menu {
                                        Button { newOwner = person } label: { Label("Make owner", systemImage: "crown") }
                                        Button(role: .destructive) { removing = person } label: { Label("Remove from group", systemImage: "person.badge.minus") }
                                    } label: {
                                        Image(systemName: "ellipsis.circle").font(.title3)
                                    }
                                    .accessibilityLabel("Options for \(person.firstName)")
                                }
                            }
                        }
                        .swipeActions {
                            if iOwn && person.id != social.myId {
                                Button("Remove", role: .destructive) { removing = person }
                            }
                        }
                    }
                }
                if !group.invited.isEmpty {
                    Section {
                        ForEach(group.invited) { person in
                            PersonRow(person: person) {
                                if iOwn {
                                    Button("Cancel") { Task { await social.remove(person.id, from: group) } }
                                        .glassButton().controlSize(.small)
                                        .accessibilityLabel("Cancel \(person.firstName)'s invite")
                                } else {
                                    Text("Invited").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Invited (\(group.invited.count))")
                    } footer: {
                        Text("They're in once they accept.")
                    }
                }
                if group.hasJoined(social.myId) {
                    Section {
                        Button { adding = true } label: { Label("Invite people", systemImage: "person.badge.plus") }
                    } footer: {
                        Text("Anyone in the group can invite people. They join once they accept.")
                    }
                }
                Section {
                    if iOwn {
                        Button("Delete group", role: .destructive) { confirmDelete = true }
                    } else {
                        if group.hasJoined(social.myId) { Button("Leave group", role: .destructive) { confirmLeave = true } }
                    }
                } footer: {
                    if iOwn {
                        Text("You own this group, so you can remove people, delete it, or make someone else the owner. To leave, make someone else the owner first.")
                    }
                }
            }
        }
        // In the middle of the screen, like the app's other confirmations: a title, a line, and two short buttons.
        .alert("Remove \(removing?.firstName ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { person in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if let group { Task { await social.remove(person.id, from: group) } } }
        } message: { _ in
            Text("They'll stop seeing the group's plans. Anyone in the group can invite them back.")
        }
        .alert("Make \(newOwner?.firstName ?? "") the owner?", isPresented: Binding(get: { newOwner != nil }, set: { if !$0 { newOwner = nil } }), presenting: newOwner) { person in
            Button("Cancel", role: .cancel) {}
            Button("Make owner") { if let group { Task { await social.transfer(group, to: person.id) } } }
        } message: { _ in
            Text("You'll become a regular member and won't be able to remove people or delete the group.")
        }
        .alert("Leave \(group?.name ?? "this group")?", isPresented: $confirmLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                if let group { Task { await social.leave(group) }; dismiss() }
            }
        } message: {
            Text("You'll stop seeing its meal plans. Someone in the group can invite you back.")
        }
        .alert("Delete \(group?.name ?? "this group")?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let group { Task { await social.delete(group) }; dismiss() }
            }
        } message: {
            Text("This removes the group and its meal plans for everyone.")
        }
        .onBackdrop()
        .navigationTitle(group?.name ?? "Group")
        .task { await social.refreshPeople() }
        // The owner's photo changes save right away (there's no Save button on this page).
        .onChange(of: newPhoto) {
            guard let newPhoto, let group else { return }
            Task { if !(await social.setPhoto(newPhoto, for: group)) { self.newPhoto = nil } }
        }
        .onChange(of: removePhoto) {
            guard removePhoto, let group else { return }
            Task {
                await social.setPhoto(nil, for: group)
                removePhoto = false
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    MemberSearchPicker(selection: $selection, excluded: Set(group?.groupMembers.map(\.userId) ?? []))
                }
                .navigationTitle("Invite to group")
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Invite") {
                            Task {
                                if let group { await social.add(selection.map(\.id), to: group) }
                                selection = []
                                adding = false
                            }
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
        }
    }
}

/// Friend status for someone you know from a group: Add friend, Requested, Accept, or nothing if already friends.
struct FriendButton: View {
    @Environment(SocialStore.self) private var social
    let person: Person

    var body: some View {
        if person.id == social.myId {
            Text("You").font(.caption).foregroundStyle(.secondary)
        } else {
            switch social.people.first(where: { $0.id == person.id })?.relation {
            case "friend":
                EmptyView()
            case "outgoing":
                Text("Requested").font(.caption).foregroundStyle(.secondary)
            case "incoming":
                Button("Accept") { Task { await social.accept(person) } }
                    .glassButton(prominent: true).controlSize(.small)
            default:
                Button("Add friend") { Task { await social.addFriend(person) } }
                    .glassButton().controlSize(.small)
                    .accessibilityLabel("Add \(person.firstName) as a friend")
            }
        }
    }
}
