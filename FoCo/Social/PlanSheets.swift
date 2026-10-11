import SwiftUI

struct PlanComposer: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var day = FoCoCalendar.startOfDay(.now)
    @State private var meal = Meal.current
    @State private var time = PlanComposer.defaultTime(for: Meal.current, on: FoCoCalendar.startOfDay(.now))
    @State private var audience = Audience.friends
    @State private var invitees: Set<UUID> = []
    @State private var group: UUID?
    @State private var note = ""
    @State private var working = false

    static func defaultTime(for meal: Meal, on base: Date) -> Date {
        let isToday = FoCoCalendar.cal.isDateInToday(base)
        let (h, m) = switch meal {
        case .breakfast: (8, 30)
        case .lunch: (12, 30)
        case .dinner: (18, 0)
        case .lateNight: (22, 0)
        }
        let suggested = FoCoCalendar.cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        if isToday && suggested < .now {
            let next = Date.now.addingTimeInterval(15 * 60)
            let minute = FoCoCalendar.cal.component(.minute, from: next)
            return FoCoCalendar.cal.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: next) ?? next
        }
        return suggested
    }

    private var startsAt: Date {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: time)
        var date = FoCoCalendar.cal.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: day) ?? time
        if meal == .lateNight && (c.hour ?? 0) < 3 { date = FoCoCalendar.adding(days: 1, to: date) }
        return date
    }

    private var valid: Bool {
        startsAt > Date.now.addingTimeInterval(-30 * 60)
            && (audience != .invited || !invitees.isEmpty)
            && (audience != .group || group != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DayStrip(selection: $day)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, FoCoCalendar.tz)
                    if startsAt < Date.now.addingTimeInterval(-30 * 60) {
                        Text("That time has already passed.").font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Who can join") {
                    Picker("Audience", selection: $audience) {
                        ForEach(Audience.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if audience == .invited {
                    Section("Pick friends") {
                        FriendPicker(friends: social.friends, selection: $invitees)
                    }
                } else if audience == .group {
                    Section("Pick a group") {
                        if social.groups.isEmpty {
                            Text("You're not in any groups yet. Make one from Friends → New group.").foregroundStyle(.secondary)
                        }
                        ForEach(social.groups) { g in
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

                Section {
                    TextField("Note, e.g. “window tables” or “after practice”", text: $note, axis: .vertical)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Plan a meal")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: meal) { time = Self.defaultTime(for: meal, on: day) }
            .onChange(of: day) { time = Self.defaultTime(for: meal, on: day) }
            .task {
                if social.friends.isEmpty { await social.refreshPeople() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            working = true
                            let ok = await social.createPlan(meal: meal, startsAt: startsAt, note: note, audience: audience,
                                                             group: audience == .group ? group : nil,
                                                             invitees: audience == .invited ? Array(invitees) : [])
                            working = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Post").bold() }
                    }
                    .disabled(!valid || working)
                }
            }
        }
    }

    private var footer: String {
        switch audience {
        case .friends: "All your friends will see this and can tap Going."
        case .invited: "Only the people you pick will see it. They'll get a notification."
        case .group: "Everyone in the group will see it."
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
    @Bindable private var presence = PresenceMonitor.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Which room?") {
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
                    Text("Only your friends can see this, and it disappears on its own after \(minutes) minutes.")
                }
                Section {
                    Toggle("Check me in automatically", isOn: $presence.enabled)
                } footer: {
                    Text("When you walk into FoCo during a meal, your friends see you're there, and you're checked out when you leave. Uses your location only near FoCo.")
                }
                if social.myCheckin != nil {
                    Section {
                        Button("I left FoCo", role: .destructive) {
                            Task { await social.checkOut() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("I'm at FoCo")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let mine = social.myCheckin {
                    spot = mine.spot.flatMap { FoCoRoom.all.contains($0) ? $0 : nil }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check in") {
                        Task { await social.checkIn(spot: spot, minutes: minutes) }
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HeadingSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("In about", selection: $minutes) {
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("I'll be at FoCo in about")
                } footer: {
                    Text("Friends see you're going around \(Date.now.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)) and can tap Me too. No plan, no group chat.")
                }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tell friends") {
                        Task { await social.headOver(in: minutes) }
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct FriendsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    var embedded = false
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
                if !social.incoming.isEmpty {
                    Section("Friend requests") {
                        ForEach(social.incoming) { person in
                            PersonRow(person: person) {
                                HStack {
                                    Button("Accept") { Task { await social.accept(person) } }
                                        .buttonStyle(.borderedProminent)
                                    Button("Ignore") { Task { await social.removeFriend(person) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                // Below friend requests, which are more urgent.
                Section {
                    InviteByTextButton { Label("Invite friends by text", systemImage: "message") }
                } footer: {
                    Text("Opens Messages with an invite to FoCo Social. Pick who to send it to.")
                }

                Section {
                    ForEach(social.groups) { group in
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
                    Text("Plans posted to a group reach everyone in it.")
                }

                Section("Friends (\(social.friends.count))") {
                    if social.friends.isEmpty {
                        Text("Search for people by name above to add them.").foregroundStyle(.secondary)
                    }
                    ForEach(social.friends) { person in
                        PersonRow(person: person) { EmptyView() }
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await social.removeFriend(person) } }
                                Button("Block") { blocking = person }.tint(.gray)
                            }
                    }
                }

                if !social.outgoing.isEmpty {
                    Section("Requests you sent") {
                        ForEach(social.outgoing) { person in
                            PersonRow(person: person) {
                                Button("Cancel") { Task { await social.removeFriend(person) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Friends")
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
        .sheet(isPresented: $showNewGroup) { NewGroupSheet() }
        .confirmationDialog("Block \(blocking?.firstName ?? "")?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                            titleVisibility: .visible, presenting: blocking) { person in
            Button("Block", role: .destructive) { Task { await social.block(person) } }
        } message: { _ in
            Text("You won't see each other's posts, plans, or check-ins, and they'll be removed from your friends. You can unblock them from the Me tab.")
        }
        .toastHost()
    }

    @ViewBuilder private func relationButton(_ person: Person) -> some View {
        let relation = social.people.first { $0.id == person.id }?.relation ?? person.relation ?? "none"
        switch relation {
        case "friend": Label("Friends", systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
        case "outgoing": Text("Requested").font(.subheadline).foregroundStyle(.secondary)
        case "incoming": Button("Accept") { Task { await social.accept(person) } }.buttonStyle(.borderedProminent)
        default: Button("Add") { Task { await social.addFriend(person) } }.buttonStyle(.borderedProminent)
        }
    }
}

struct PersonRow<Trailing: View>: View {
    let person: Person
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: person, size: 40)
            Text(person.displayName).font(.body)
            Spacer()
            trailing()
        }
    }
}

/// Search every signed-up student by name. Groups (teams, clubs, floors) don't require being friends.
struct MemberSearchPicker: View {
    @Environment(SocialStore.self) private var social
    @Binding var selection: [Person]
    var excluded: Set<UUID> = []
    @State private var query = ""
    @State private var results: [Person] = []
    @State private var searching = false

    var body: some View {
        Section {
            TextField("Search by name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(results.filter { !excluded.contains($0.id) }) { person in
                row(person)
            }
            if query.trimmingCharacters(in: .whitespaces).count >= 2 && results.isEmpty {
                if searching {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("No one by that name has joined yet.").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Add people")
        } footer: {
            Text("Anyone on FoCo Social, not just friends. Group members see the group's meal plans, but only your friends see when you're at FoCo.")
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
                Section {
                    Button { adding = true } label: { Label("Add people", systemImage: "person.badge.plus") }
                } footer: {
                    Text("Anyone in the group can add people.")
                }
                Section {
                    if iOwn {
                        Button("Delete group", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Leave group", role: .destructive) { confirmLeave = true }
                    }
                } footer: {
                    if iOwn {
                        Text("You own this group, so you can remove people, delete it, or make someone else the owner. To leave, make someone else the owner first.")
                    }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.firstName ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { person in
            Button("Remove", role: .destructive) { if let group { Task { await social.remove(person.id, from: group) } } }
        } message: { _ in
            Text("They'll stop seeing the group's plans. Anyone in the group can add them back.")
        }
        .confirmationDialog("Make \(newOwner?.firstName ?? "") the owner?", isPresented: Binding(get: { newOwner != nil }, set: { if !$0 { newOwner = nil } }), titleVisibility: .visible, presenting: newOwner) { person in
            Button("Make owner") { if let group { Task { await social.transfer(group, to: person.id) } } }
        } message: { _ in
            Text("You'll become a regular member and won't be able to remove people or delete the group.")
        }
        .confirmationDialog("Leave \(group?.name ?? "this group")?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) {
                if let group { Task { await social.leave(group) }; dismiss() }
            }
        } message: {
            Text("You'll stop seeing its meal plans. Someone in the group can add you back.")
        }
        .confirmationDialog("Delete \(group?.name ?? "this group")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                if let group { Task { await social.delete(group) }; dismiss() }
            }
        } message: {
            Text("This removes the group and its meal plans for everyone.")
        }
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
                    MemberSearchPicker(selection: $selection, excluded: Set(group?.people.map(\.id) ?? []))
                }
                .navigationTitle("Add to group")
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
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
                    .buttonStyle(.borderedProminent).controlSize(.small)
            default:
                Button("Add friend") { Task { await social.addFriend(person) } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Add \(person.firstName) as a friend")
            }
        }
    }
}
