import SwiftUI

/// A meal plan's page: when and where, your answer, the plan's chat, and everyone invited, by answer.
/// Plans often mix friend groups, so people you don't know yet get an Add friend button.
struct PlanDetailView: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let planId: UUID
    @State private var editing = false
    @State private var inviting = false

    private var plan: Plan? { social.together.plans.first { $0.id == planId } }

    var body: some View {
        Group {
            if let plan {
                content(plan)
            } else if !social.loadedTogether {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("This plan is over", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("It was cancelled, or it already happened."))
            }
        }
        .navigationTitle(plan?.mealKind?.title ?? "Plan")
        .navigationBarTitleDisplayMode(.inline)
        .task { if plan == nil { await social.refreshTogether() } }
    }

    private func content(_ plan: Plan) -> some View {
        let me = social.myId
        let isHost = plan.host.id == me
        let status = plan.status(of: me)
        let inChat = isHost || [.going, .maybe, .invited].contains(status)
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    if let group = plan.group {
                        Avatar(groupId: group.id, name: group.name, photoPath: group.photoPath, size: 56)
                    } else {
                        Avatar(person: plan.host, size: 56)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.title(me: me)).font(.title3.bold())
                        Label(plan.timeLabel, systemImage: plan.mealKind?.symbol ?? "clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(isHost ? "You're hosting" : "Hosted by \(plan.host.firstName)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                if let note = plan.note, !note.isEmpty {
                    Text("“\(note)”")
                }
            }

            if !isHost {
                Section {
                    RSVPRow(plan: plan, status: status)
                } footer: {
                    Text(status == nil || status == .invited ? "Let \(plan.host.firstName) know if you're coming." : "Tap your answer again to take it back.")
                }
            }

            Section {
                if inChat {
                    NavigationLink { ChatView(target: .plan(plan.id)) } label: {
                        Label("Plan chat", systemImage: "bubble.left.and.bubble.right")
                            .badge(social.chats.first { $0.target == .plan(plan.id) }?.unread ?? 0)
                    }
                } else {
                    Label("Answer Going or Maybe to join the chat", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if inChat { Text("For “running 5 minutes late” and “we're on dark side.”") }
            }

            peopleSection("Going", [plan.host] + plan.going.filter { $0.id != plan.host.id })
            peopleSection("Maybe", plan.maybe)
            peopleSection("Invited, no answer yet", plan.invitedOnly)
            peopleSection("Can't make it", plan.declined)

            if isHost {
                Section {
                    Button { editing = true } label: { Label("Change time or note", systemImage: "pencil") }
                    Button { inviting = true } label: { Label("Invite more friends", systemImage: "person.badge.plus") }
                    Button(role: .destructive) {
                        Task { await social.cancel(plan) }
                        dismiss()
                    } label: {
                        Label("Cancel plan", systemImage: "xmark.circle")
                    }
                } footer: {
                    Text("Everyone in the plan gets a notification if you change the time or cancel.")
                }
            }
        }
        .refreshable { await social.refreshTogether() }
        .sheet(isPresented: $editing) { PlanComposer(editing: plan) }
        .sheet(isPresented: $inviting) { InviteFriendsSheet(plan: plan) }
    }

    @ViewBuilder private func peopleSection(_ title: String, _ people: [Person]) -> some View {
        if !people.isEmpty {
            Section("\(title) (\(people.count))") {
                ForEach(people) { person in
                    PersonRow(person: person) { FriendButton(person: person) }
                }
            }
        }
    }
}
