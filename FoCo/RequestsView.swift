import SwiftUI

struct RequestsView: View {
    var body: some View { NavigationStack { RequestsForm() } }
}

struct RequestsForm: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(SocialStore.self) private var social
    @State private var food = ""
    @State private var meal: Meal? = nil
    @State private var note = ""
    @State private var working = false
    @State private var justSent: String?
    @State private var signingIn = false

    var body: some View {
        Form {
            if social.phase != .ready {
                Section {
                    Button { signingIn = true } label: {
                        Label("Sign in to send requests", systemImage: "person.crop.circle.badge.plus")
                    }
                } footer: {
                    Text("Requests come from signed-in students only, so Dining knows they're real.")
                }
            } else {
                Section {
                    TextField("Food you want at FoCo", text: $food)
                    Picker("Meal", selection: $meal) {
                        Text("Any meal").tag(Meal?.none)
                        ForEach(Meal.allCases) { Text($0.title).tag(Meal?.some($0)) }
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                    Button {
                        Task { await send(food, meal: meal, note: note) }
                    } label: {
                        HStack {
                            Text("Send to Dining").bold()
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(food.trimmingCharacters(in: .whitespaces).count < 2 || working)
                    if let justSent {
                        Label("Requested “\(justSent)”", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                } header: {
                    Text("Request a food")
                } footer: {
                    Text("Requests are sent to Dartmouth Dining daily. Your name isn't included. You'll get an alert if it shows up on the menu.")
                }

                if !social.popularRequests.isEmpty {
                    Section("Students asked for this week") {
                        ForEach(social.popularRequests) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.food).font(.headline)
                                    Text("\(r.students) student\(r.students == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if r.mine {
                                    Label("You asked", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                } else {
                                    Button("Me too") { Task { await send(r.food, meal: nil, note: "") } }
                                        .buttonStyle(.bordered)
                                        .accessibilityHint("Adds your request for \(r.food)")
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if !social.sentRequests.isEmpty {
                    Section {
                        ForEach(social.sentRequests) { request in
                            SentRequestRow(request: request, spotted: store.matches(for: [request.food]).first)
                                .swipeActions {
                                    if request.sentAt == nil {
                                        Button("Withdraw", role: .destructive) { Task { await social.withdraw(request) } }
                                    }
                                }
                        }
                    } header: {
                        Text("Your requests")
                    } footer: {
                        Text("Swipe left to take back a request before it's sent.")
                    }
                }
            }
        }
        .navigationTitle("Requests")
        .sheet(isPresented: $signingIn) { SignInSheet(reason: "Sign in with your NetID to send food requests to Dining.") }
        .task {
            await store.loadUpcoming()
            await social.refreshRequests()
        }
        .refreshable { await social.refreshRequests() }
    }

    private func send(_ text: String, meal chosenMeal: Meal?, note noteText: String) async {
        let name = text.trimmingCharacters(in: .whitespaces)
        working = true
        if await social.request(food: name, meal: chosenMeal, note: noteText) {
            prefs.follow(name)
            justSent = name
            food = ""; note = ""; meal = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        working = false
    }
}

private struct SentRequestRow: View {
    let request: SentRequest
    let spotted: MenuMatch?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.food).font(.headline)
            Text([request.mealKind?.title ?? "Any meal", request.note ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let sent = request.sentAt {
                Text("Sent to Dining \(sent.formatted(.dateTime.month(.abbreviated).day()))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Sending soon").font(.caption).foregroundStyle(.secondary)
            }
            if let spotted, let date = spotted.date {
                Label("On the menu: \(spotted.meal.title.lowercased()) \(FoCoCalendar.phrase(date))", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
