import SwiftUI

struct AlertsView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var status: NotificationStatus = .unknown

    private var matches: [MenuMatch] { store.matches(for: prefs.alertKeywords) }
    private var suggestions: [String] { Suggestions.foods.filter { !prefs.isWatching($0) } }

    var body: some View {
        NavigationStack {
            List {
                if status == .denied {
                    Section {
                        Button {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } label: {
                            Label("Notifications are off. Tap to turn them on in Settings.", systemImage: "bell.slash")
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("Type a food, like “steak”", text: $draft)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit { add(draft) }
                        Button("Add") { add(draft) }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !prefs.watches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Following · tap to remove").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            FlowLayout {
                                ForEach(prefs.watches, id: \.self) { food in
                                    Chip(title: food, selected: true, systemImage: "xmark") { remove(food) }
                                        .accessibilityLabel("\(food), following")
                                        .accessibilityHint("Removes it from your alerts")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Popular").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            FlowLayout {
                                ForEach(suggestions.prefix(8), id: \.self) { food in
                                    Chip(title: food, selected: false, systemImage: "plus") { add(food) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Get alerted when a food is served")
                } footer: {
                    Text("Foods you request are followed too. Alerts come at 8 PM the night before breakfast, 9 AM for lunch, 3 PM for dinner, and 7 PM for late night.")
                }

                Section("Coming up in the next 7 days") {
                    if prefs.alertKeywords.isEmpty {
                        Text("Add a food above and you'll see every time it's on the menu.").foregroundStyle(.secondary)
                    } else if matches.isEmpty {
                        Text("None of your foods are on the posted menus yet. Dining posts about a week ahead.").foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { m in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(m.date.map(FoCoCalendar.relativeName) ?? m.day) · \(m.meal.title)")
                                    .font(.headline)
                                Text(m.items.map { "\($0.name) at \($0.station)" }.joined(separator: "\n"))
                                    .font(.subheadline)
                                Text("You follow “\(m.keyword)”").font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions {
                                Button("Unfollow", role: .destructive) { withAnimation { prefs.unfollow(m.keyword) } }
                                    .tint(.red)
                            }
                        }
                    }
                }

            }
            .navigationTitle("Alerts")
            .task {
                await store.loadUpcoming()
                status = await .current()
            }
            .refreshable { await store.loadUpcoming(force: true) }
            .onChange(of: prefs.alertKeywords) {
                Task { await AlertScheduler.reschedule() }
            }
        }
    }

    private func remove(_ food: String) {
        withAnimation { prefs.unfollow(food) }
    }

    private func add(_ text: String) {
        let food = text.trimmingCharacters(in: .whitespaces)
        guard !food.isEmpty else { return }
        prefs.follow(food)
        draft = ""
        Task {
            await AlertScheduler.requestPermission()
            status = await .current()
            await AlertScheduler.reschedule()
        }
    }
}

enum NotificationStatus {
    case unknown, allowed, denied

    static func current() async -> Self {
        switch await AlertScheduler.authorizationStatus() {
        case .denied: .denied
        case .notDetermined: .unknown
        default: .allowed
        }
    }
}
