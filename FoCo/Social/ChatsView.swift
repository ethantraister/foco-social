import SwiftUI

/// The Chats tab: messages with friends, group chats, and a chat for each meal plan you're in, newest first.
struct ChatsView: View {
    @Environment(SocialStore.self) private var social
    @State private var router = AppRouter.shared
    @State private var path: [ChatTarget] = []
    @State private var newMessage = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if social.isOffline {
                    Section { OfflineNote() }
                }
                if social.chats.isEmpty {
                    if social.loadedChats {
                        ContentUnavailableView {
                            Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("Message a friend, or chat with a group or the people in a meal plan.")
                        } actions: {
                            Button("New message") { newMessage = true }.glassButton(prominent: true)
                        }
                        .listRowBackground(Color.clear)
                    } else if social.chatsFailed && !social.isOffline {
                        ContentUnavailableView {
                            Label("Couldn't load chats", systemImage: "exclamationmark.bubble")
                        } description: {
                            Text("Something went wrong on our end. Try again in a minute.")
                        } actions: {
                            Button("Try again") { Task { await social.refreshChats() } }.glassButton()
                        }
                        .listRowBackground(Color.clear)
                    } else if !social.isOffline {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                }
                ForEach(social.chats) { thread in
                    NavigationLink(value: thread.target) { ChatRow(thread: thread) }
                }
            }
            .onBackdrop()
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newMessage = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New message")
                }
            }
            .navigationDestination(for: ChatTarget.self) { ChatView(target: $0) }
            .refreshable { await social.refreshChats() }
            .task {
                while !Task.isCancelled {
                    await social.refreshChats()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .onChange(of: router.pendingChat, initial: true) {
                guard let chat = router.pendingChat else { return }
                router.pendingChat = nil
                path = [chat]
            }
            .sheet(isPresented: $newMessage) {
                NewMessageSheet { person in
                    newMessage = false
                    path = [.dm(person.id)]
                }
            }
        }
    }
}

private struct ChatRow: View {
    @Environment(SocialStore.self) private var social
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ChatTitle.title(for: thread, me: social.myId)).font(.headline.weight(thread.unread > 0 ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let at = thread.lastAt {
                        Text(ChatTitle.shortTime(at)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(thread.unread > 0 ? Color.primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    if thread.unread > 0 {
                        Text("\(thread.unread)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 20)
                            .background(Color.dartmouthDeep, in: .capsule)
                            .accessibilityLabel("\(thread.unread) unread")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var avatar: some View {
        if let person = thread.person {
            Avatar(person: person, size: 48)
        } else if let group = thread.group ?? thread.plan?.group {
            Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 48)
        } else if let host = thread.plan?.host {
            Avatar(person: host, size: 48)
        }
    }

    private var preview: String {
        guard let body = thread.lastBody else {
            switch thread.kind {
            case "plan": return "\(thread.plan.map { ChatTitle.when($0.startsAt) } ?? "Plan chat") · no messages yet"
            case "group": return "Group chat · no messages yet"
            default: return "No messages yet"
            }
        }
        guard let sender = thread.lastSender else { return body }
        if sender.id == social.myId { return "You: \(body)" }
        return thread.kind == "dm" ? body : "\(sender.name.split(separator: " ").first.map(String.init) ?? sender.name): \(body)"
    }
}

/// Names for chats, shared by the list and the chat screen.
enum ChatTitle {
    static func title(for thread: ChatThread, me: UUID?) -> String {
        if let person = thread.person { return person.name }
        if let group = thread.group { return group.name }
        if let plan = thread.plan { return planTitle(meal: plan.meal, host: plan.host, group: plan.group, me: me) }
        return "Chat"
    }

    /// Named like the plan's card on Together: "Dinner with Priya", "Your dinner", "Water Polo · dinner".
    static func planTitle(meal: String, host: Person, group: GroupRef?, me: UUID?) -> String {
        let name = Meal(rawValue: meal)?.title ?? "Meal"
        if let group { return "\(group.name) · \(name.lowercased())" }
        if host.id == me { return "Your \(name.lowercased())" }
        return "\(name) with \(host.firstName)"
    }

    /// "Tomorrow 6:30 PM"
    static func when(_ date: Date) -> String {
        "\(FoCoCalendar.relativeName(date)) \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz)))"
    }

    /// "6:02 PM" today, "Tue" this week, "Oct 3" before that.
    static func shortTime(_ date: Date) -> String {
        let style = Date.FormatStyle(timeZone: FoCoCalendar.tz)
        if FoCoCalendar.cal.isDateInToday(date) { return date.formatted(style.hour().minute()) }
        if date > Date.now.addingTimeInterval(-6 * 86400) { return date.formatted(style.weekday(.abbreviated)) }
        return date.formatted(style.month(.abbreviated).day())
    }
}

/// Pick a friend to message.
private struct NewMessageSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let pick: (Person) -> Void
    @State private var query = ""

    private var friends: [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return social.recentFriends.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if social.friends.isEmpty {
                    Text("Add friends first, from the Friends button on the Together tab. You can message anyone you're friends with.")
                        .foregroundStyle(.secondary)
                }
                ForEach(friends) { friend in
                    Button { pick(friend) } label: {
                        HStack(spacing: 12) {
                            Avatar(person: friend, size: 36)
                            Text(friend.displayName).foregroundStyle(Color.primary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search friends")
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// One chat. New messages show up within a few seconds while it's open.
struct ChatView: View {
    @Environment(SocialStore.self) private var social
    let target: ChatTarget
    @State private var messages: [ChatMessage] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var draft = ""
    @State private var sending = false
    @State private var blocking: Person?
    @FocusState private var typing: Bool

    private var thread: ChatThread? { social.chats.first { $0.target == target } }

    private var title: String {
        if let thread { return ChatTitle.title(for: thread, me: social.myId) }
        switch target {
        case .dm(let id): return social.people.first { $0.id == id }?.name ?? "Message"
        case .group(let id): return social.groups.first { $0.id == id }?.name ?? "Group chat"
        case .plan(let id):
            if let plan = social.together.plans.first(where: { $0.id == id }) { return plan.title(me: social.myId) }
            return "Plan chat"
        }
    }

    private var isGroupish: Bool { if case .dm = target { false } else { true } }

    /// For a plan's chat, when the meal is (shown under the name).
    private var planTime: Date? {
        guard case .plan(let id) = target else { return nil }
        return thread?.plan?.startsAt ?? social.together.plans.first { $0.id == id }?.startsAt
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if loaded && messages.isEmpty {
                        Text(emptyLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                            .padding(.horizontal, 32)
                    } else if failed && messages.isEmpty {
                        VStack(spacing: 10) {
                            Text("Couldn't load messages.").foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                        }
                        .padding(.top, 60)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                        let previous = i > 0 ? messages[i - 1] : nil
                        if previous == nil || message.createdAt.timeIntervalSince(previous!.createdAt) > 15 * 60 {
                            Text(stamp(message.createdAt))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                        }
                        MessageBubble(message: message,
                                      mine: message.sender.id == social.myId,
                                      showName: isGroupish && message.sender.id != social.myId && previous?.sender.id != message.sender.id,
                                      unsend: { Task { await unsend(message) } },
                                      report: { Task { await report(message) } },
                                      block: { blocking = message.sender })
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) {
                guard let last = messages.last?.id else { return }
                withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let when = planTime {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(ChatTitle.when(when)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            switch target {
            case .plan(let id):
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { PlanDetailView(planId: id) } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Plan details")
                }
            case .group(let id):
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { GroupDetailView(groupId: id) } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Group details")
                }
            case .dm: ToolbarItem(placement: .topBarTrailing) { EmptyView() }
            }
        }
        .hidesTabBar()
        .onAppear { social.openChat = target }
        .onDisappear { if social.openChat == target { social.openChat = nil } }
        .task {
            await load()
            // New messages every few seconds while the chat is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await fetchNew()
            }
        }
        .confirmationDialog("Block \(blocking?.firstName ?? "")?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                            titleVisibility: .visible, presenting: blocking) { person in
            Button("Block", role: .destructive) {
                Task {
                    await social.block(person)
                    messages.removeAll { $0.sender.id == person.id }
                }
            }
        } message: { _ in
            Text("You won't see each other's plans, check-ins, or messages, and they'll be removed from your friends.")
        }
    }

    /// The message box and send button float on glass at the bottom; messages scroll underneath.
    private var composer: some View {
        GlassGroup(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glass(in: .rect(cornerRadius: 22))
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 44, height: 44)
                        .glass(in: Circle(), tint: canSend ? .dartmouthDeep : nil, interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendMessage")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.2), value: canSend)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    private var emptyLine: String {
        switch target {
        case .dm: "No messages yet. Say hi, or ask if they want to grab a meal."
        case .group: "No messages yet. Everyone in the group sees what you send here."
        case .plan: "No messages yet. Use this for “running 5 minutes late” or “we're on dark side.”"
        }
    }

    private func stamp(_ date: Date) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz))
        return "\(FoCoCalendar.relativeName(date)) \(time)"
    }

    private func load() async {
        failed = false
        if let rows = await social.messages(in: target) {
            messages = rows
            loaded = true
            await social.markRead(target)
        } else {
            failed = true
        }
    }

    private func fetchNew() async {
        guard loaded, let rows = await social.messages(in: target, newerThan: messages.last?.createdAt) else { return }
        let known = Set(messages.map(\.id))
        let fresh = rows.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        await social.markRead(target)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        if let sent = await social.send(text, to: target) {
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
            await social.markRead(target)
            await social.refreshChats()
        } else {
            draft = text   // didn't go through: keep what they typed
        }
        sending = false
    }

    private func unsend(_ message: ChatMessage) async {
        let before = messages
        messages.removeAll { $0.id == message.id }
        if !(await social.unsend(message)) { messages = before }
    }

    private func report(_ message: ChatMessage) async {
        messages.removeAll { $0.id == message.id }
        await social.report(message)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let showName: Bool
    let unsend: () -> Void
    let report: () -> Void
    let block: () -> Void

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if showName {
                Text(message.sender.firstName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if mine { Spacer(minLength: 48) }
                if !mine {
                    Avatar(person: message.sender, size: 30).opacity(showName ? 1 : 0)
                }
                Text(message.body)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .foregroundStyle(mine ? .white : Color.primary)
                    .background(mine ? Color.dartmouthDeep : Color(uiColor: .secondarySystemBackground),
                                in: .rect(cornerRadius: 18))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.body } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if mine {
                            Button(role: .destructive, action: unsend) { Label("Unsend", systemImage: "arrow.uturn.backward") }
                        } else {
                            Button(action: report) { Label("Report", systemImage: "exclamationmark.bubble") }
                            Button(role: .destructive, action: block) { Label("Block \(message.sender.firstName)", systemImage: "hand.raised") }
                        }
                    }
                if !mine { Spacer(minLength: 48) }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : message.sender.firstName): \(message.body)")
        .accessibilityHint("Press and hold for options")
    }
}
