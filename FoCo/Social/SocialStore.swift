import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class SocialStore {
    static let shared = SocialStore()

    /// `loading` is signed in but waiting for your profile. It only happens the first time on a phone:
    /// after that your profile is saved, so the app opens straight to it, even offline.
    enum Phase { case signedOut, loading, needsProfile, ready }

    let client = SupabaseClient()
    private(set) var phase: Phase = .signedOut
    /// Loading your profile failed (usually no connection), so the screen offers Try again.
    private(set) var loadFailed = false
    private(set) var me: Person? { didSet { saveMe() } }
    private(set) var together = Together()
    private(set) var people: [Person] = []
    private(set) var groups: [SocialGroup] = []
    private(set) var blocked: [Person] = []
    private(set) var feeds: [PostKind: [Post]] = [:]
    private(set) var bestToday: Post?
    private(set) var loadedTogether = false
    private(set) var loadedPeople = false
    /// The last request couldn't reach the server. Screens say so instead of spinning.
    private(set) var isOffline = false
    /// Other people's plans you swiped away; kept on this phone only.
    private(set) var hiddenPlans: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "hiddenPlans") ?? []).compactMap(UUID.init))
    /// Posts you reported, hidden for you right away (everyone else's feed hides them after three reports).
    private(set) var reportedPosts: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "reportedPosts") ?? []).compactMap(UUID.init))
    private var feedSort = "top"
    var errorMessage: String?

    /// A short note at the bottom of the screen, like "Plan cancelled · Undo", instead of asking "are you sure?" first.
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        var actionTitle: String? = nil
        var action: (() async -> Void)? = nil
    }
    /// Several tabs can show the toast at once, so it times out here rather than in a view, where a hidden tab
    /// tearing down its copy would cut it short for the screen you're looking at.
    var toast: Toast? {
        didSet {
            guard let toast, toast.id != oldValue?.id else { return }
            UIAccessibility.post(notification: .announcement, argument: toast.message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(toast.action == nil ? 4 : 6))
                if self?.toast?.id == toast.id { self?.toast = nil }
            }
        }
    }

    var isLocalDemo: Bool { SocialConfig.isLocalDemo }
    var myId: UUID? { client.session?.userId }
    var email: String? { client.session?.email }

    private static let meKey = "me.v1"
    /// Who's at FoCo and upcoming plans, saved so the Together tab opens with them even without a connection.
    private static var togetherCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("together.v1.json")
    }

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") {
            hiddenPlans = []
            reportedPosts = []
            UserDefaults.standard.removeObject(forKey: Self.meKey)
        }
        #endif
        guard let session = client.session else { return }
        if let data = UserDefaults.standard.data(forKey: Self.meKey),
           let saved = try? JSONDecoder().decode(Person.self, from: data), saved.id == session.userId {
            me = saved
            phase = .ready
            loadSavedTogether()
        } else {
            phase = .loading
        }
    }

    private func loadSavedTogether() {
        guard let data = try? Data(contentsOf: Self.togetherCache),
              var saved = try? JSONDecoder().decode(Together.self, from: data) else { return }
        // Nothing stale: check-ins that have run out and plans that are over are dropped.
        saved.checkins.removeAll { $0.expiresAt <= .now }
        saved.plans.removeAll { $0.startsAt < Date.now.addingTimeInterval(-90 * 60) }
        together = saved
        loadedTogether = true
    }

    private func saveTogether() {
        guard let data = try? JSONEncoder().encode(together) else { return }
        try? data.write(to: Self.togetherCache, options: .atomic)
    }

    private func saveMe() {
        if let me, let data = try? JSONEncoder().encode(me) {
            UserDefaults.standard.set(data, forKey: Self.meKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.meKey)
        }
    }

    // MARK: Derived

    var friends: [Person] { people.filter { $0.relation == "friend" } }
    var incoming: [Person] { people.filter { $0.relation == "incoming" } }
    var outgoing: [Person] { people.filter { $0.relation == "outgoing" } }

    var invites: [Plan] { together.plans.filter { $0.status(of: myId) == .invited && !hiddenPlans.contains($0.id) } }
    var upcoming: [Plan] { together.plans.filter { $0.status(of: myId) != .invited && !hiddenPlans.contains($0.id) } }
    private var myRow: Checkin? { together.checkins.first { $0.user.id == myId } }
    var myCheckin: Checkin? { myRow.flatMap { $0.isHeading ? nil : $0 } }
    var myHeading: Checkin? { myRow.flatMap { $0.isHeading ? $0 : nil } }
    var friendsHere: [Checkin] { together.checkins.filter { $0.user.id != myId && !$0.isHeading } }
    var friendsHeading: [Checkin] {
        together.checkins.filter { $0.user.id != myId && $0.isHeading }.sorted { ($0.eta ?? .now) < ($1.eta ?? .now) }
    }

    // MARK: Session

    private var bootstrapping: Task<Void, Never>?
    private var lastFullRefresh = Date.distantPast

    /// Loads your profile and everything else. Launch and coming back to the app can both ask at once; that's one request.
    func bootstrap() async {
        if let bootstrapping { return await bootstrapping.value }
        let task = Task { await loadProfile() }
        bootstrapping = task
        await task.value
        bootstrapping = nil
    }

    private func loadProfile() async {
        guard let id = myId else { phase = .signedOut; return }
        if me == nil { phase = .loading }
        loadFailed = false
        do {
            let rows: [Person] = try await client.select("profiles", ["id": "eq.\(id.uuidString)", "select": "id,name,emoji,photo_path,class_year"])
            if let mine = rows.first {
                me = mine
                phase = .ready
                await refreshAll()
            } else {
                me = nil
                phase = .needsProfile
            }
        } catch APIError.notSignedIn {
            reset()
        } catch {
            // Usually no connection. With a saved profile the app keeps working from what it has.
            loadFailed = true
            if case APIError.offline = error { isOffline = true }
        }
    }

    /// When the app comes back to the foreground. Who's at FoCo always; friends and groups if it's been a few minutes.
    func resume() async {
        switch phase {
        case .loading: await bootstrap()
        case .ready:
            if Date.now.timeIntervalSince(lastFullRefresh) > 5 * 60 { await refreshAll() } else { await refreshTogether() }
        default: break
        }
    }

    func sendCode(to email: String) async -> Bool {
        await run { try await client.sendCode(to: email) }
    }

    func verify(email: String, code: String) async -> Bool {
        let ok = await run { try await client.verify(email: email, code: code) }
        if ok { await bootstrap() }
        return ok
    }

    /// The App Review account signs in with a password, since it can't get the emailed code.
    func signIn(email: String, password: String) async -> Bool {
        let ok = await run { try await client.signIn(email: email, password: password) }
        if ok { await bootstrap() }
        return ok
    }

    enum PhotoChange { case keep, set(UIImage), remove }

    func createProfile(name: String, classYear: Int?, photo: UIImage? = nil) async -> Bool {
        guard let id = myId, let email else { return false }
        var values: [String: Any] = ["name": name]
        if let classYear { values["class_year"] = classYear }
        let ok = await run {
            do {
                try await client.insert("profiles", values.merging(["id": id.uuidString, "email": email]) { a, _ in a })
            } catch let error as APIError where error.status == 409 {
                // Made on an earlier try (say the photo upload failed), so update it instead.
                try await client.update("profiles", where: ["id": "eq.\(id.uuidString)"], values)
            }
            if let photo { try await savePhoto(.set(photo), for: id) }
        }
        if ok { await bootstrap() }
        return ok
    }

    @discardableResult
    func updateProfile(name: String, classYear: Int?, photo: PhotoChange = .keep) async -> Bool {
        guard let id = myId else { return false }
        let oldPhoto = me?.photoPath
        let ok = await run {
            try await client.update("profiles", where: ["id": "eq.\(id.uuidString)"],
                                    ["name": name, "class_year": classYear.map { $0 as Any } ?? NSNull()])
            try await savePhoto(photo, for: id)
        }
        guard ok else { return false }
        if case .keep = photo {} else if let oldPhoto { try? await client.deletePhotos([oldPhoto]) }
        await bootstrap()
        return true
    }

    /// A profile photo change: keep it, a new one, or back to initials.
    private func savePhoto(_ change: PhotoChange, for id: UUID) async throws {
        switch change {
        case .keep: return
        case .remove:
            try await client.update("profiles", where: ["id": "eq.\(id.uuidString)"], ["photo_path": NSNull()])
        case .set(let image):
            let path = try await uploadSquarePhoto(image, kind: "avatar")
            try await client.update("profiles", where: ["id": "eq.\(id.uuidString)"], ["photo_path": path])
        }
    }

    /// A square photo (profile or group) into your own folder, under a new name each time so nobody sees a cached old one.
    private func uploadSquarePhoto(_ image: UIImage, kind: String) async throws -> String {
        guard let id = myId, let jpeg = image.squareAvatar() else { throw APIError.server("Couldn't use that photo. Try another one.") }
        let path = "\(id.uuidString.lowercased())/\(kind)-\(UUID().uuidString.lowercased()).jpg"
        try await client.upload(jpeg: jpeg, to: path)
        return path
    }

    func photoURL(path: String) -> URL { client.publicURL(path) }

    func signOut() {
        client.signOut()
        reset()
    }

    func deleteAccount() async -> Bool {
        let ok = await run {
            // Photos go first: once the account is gone, nothing can delete them.
            if let paths = try? await client.myPhotoPaths() { try? await client.deletePhotos(paths) }
            try await client.rpcVoid("delete_my_account")
        }
        if ok {
            client.signOut()
            reset()
        }
        return ok
    }

    private func reset() {
        phase = .signedOut
        loadFailed = false
        me = nil
        together = Together()
        people = []
        groups = []
        blocked = []
        feeds = [:]
        bestToday = nil
        loadedTogether = false
        loadedPeople = false
        sentRequests = []
        popularRequests = []
        toast = nil
        isOffline = false
        try? FileManager.default.removeItem(at: Self.togetherCache)
        hiddenPlans = []
        reportedPosts = []
        UserDefaults.standard.removeObject(forKey: "hiddenPlans")
        UserDefaults.standard.removeObject(forKey: "reportedPosts")
    }

    // MARK: Loading

    func refreshAll() async {
        lastFullRefresh = .now
        async let a: Void = refreshTogether()
        async let b: Void = refreshPeople()
        async let c: Void = refreshGroups()
        _ = await (a, b, c)
    }

    func refreshTogether() async {
        guard phase == .ready else { return }
        await run(silent: true) {
            together = try await client.rpc("together", ["window_hours": 24 * 8])
            loadedTogether = true
            saveTogether()
            notifyAboutNewInvites()
        }
    }

    func refreshPeople() async {
        guard phase == .ready else { return }
        await run(silent: true) {
            people = try await client.rpc("my_people")
            loadedPeople = true
        }
    }

    func refreshGroups() async {
        guard phase == .ready else { return }
        await run(silent: true) {
            groups = try await client.select("groups", [
                "select": "id,name,emoji,photo_path,created_by,group_members(user_id,role,profiles(id,name,emoji,photo_path,class_year))",
                "order": "name",
            ])
        }
    }

    func refreshBlocked() async {
        guard phase == .ready else { return }
        struct Row: Decodable { let profiles: Person }
        await run(silent: true) {
            let rows: [Row] = try await client.select("blocks", [
                "select": "blocked,profiles!blocks_blocked_fkey(id,name,emoji,photo_path,class_year)",
                "order": "created_at.desc",
            ])
            blocked = rows.map(\.profiles)
        }
    }

    func refreshFeed(_ kind: PostKind, sort: String) async {
        guard phase == .ready else { return }
        feedSort = sort
        await run(silent: true) {
            let rows: [Post] = try await client.rpc("feed", ["kind_filter": kind.rawValue, "sort": sort, "lim": 80])
            feeds[kind] = rows.filter { !reportedPosts.contains($0.id) }
            if kind == .photo {
                let today = FoCoCalendar.dayString(.now)
                let top: [Post] = try await client.rpc("feed", ["kind_filter": "photo", "day": today, "sort": "top", "lim": 5])
                bestToday = top.first { !reportedPosts.contains($0.id) && $0.votes > 0 }
            }
        }
    }

    // MARK: Eating together

    private func setMyCheckin(_ checkin: Checkin?) {
        together.checkins.removeAll { $0.user.id == myId }
        if let checkin { together.checkins.insert(checkin, at: 0) }
    }

    private func replacePlan(_ id: UUID, with plan: Plan?) {
        guard let i = together.plans.firstIndex(where: { $0.id == id }) else { return }
        if let plan { together.plans[i] = plan } else { together.plans.remove(at: i) }
    }

    @discardableResult
    func checkIn(spot: String?, minutes: Int, auto: Bool = false) async -> Bool {
        guard let id = myId else { return false }
        let before = together.checkins
        let expires = Date.now.addingTimeInterval(Double(minutes) * 60)
        if let me { setMyCheckin(Checkin(user: me, spot: spot, eta: nil, startedAt: .now, expiresAt: expires)) }
        let ok = await run(silent: auto) {
            try await client.insert("checkins", [
                "user_id": id.uuidString,
                "spot": spot.map { $0 as Any } ?? NSNull(),
                "eta": NSNull(),
                "started_at": SupabaseClient.isoString(.now),
                "expires_at": SupabaseClient.isoString(expires),
            ], upsert: true)
        }
        if ok { UserDefaults.standard.set(auto, forKey: "autoCheckin.active") } else { together.checkins = before }
        await refreshTogether()
        return ok
    }

    /// "I'll be at FoCo in 30 min": friends see it until 20 minutes after you said you'd arrive.
    func headOver(in minutes: Int) async {
        guard let id = myId else { return }
        let before = together.checkins
        let eta = Date.now.addingTimeInterval(Double(minutes) * 60)
        if let me { setMyCheckin(Checkin(user: me, spot: nil, eta: eta, startedAt: .now, expiresAt: eta.addingTimeInterval(20 * 60))) }
        let ok = await run {
            try await client.insert("checkins", [
                "user_id": id.uuidString,
                "spot": NSNull(),
                "eta": SupabaseClient.isoString(eta),
                "started_at": SupabaseClient.isoString(.now),
                "expires_at": SupabaseClient.isoString(eta.addingTimeInterval(20 * 60)),
            ], upsert: true)
        }
        if ok { UserDefaults.standard.set(false, forKey: "autoCheckin.active") } else { together.checkins = before }
        await refreshTogether()
    }

    /// Says which room you're in without restarting the check-in.
    func setSpot(_ spot: String) async {
        guard let id = myId, let mine = myCheckin else { return }
        setMyCheckin(Checkin(user: mine.user, spot: spot, eta: mine.eta, startedAt: mine.startedAt, expiresAt: mine.expiresAt))
        await run { try await client.update("checkins", where: ["user_id": "eq.\(id.uuidString)"], ["spot": spot]) }
        await refreshTogether()
    }

    func checkOut(manual: Bool = true) async {
        guard let id = myId else { return }
        if manual { PresenceMonitor.shared.userLeft() }
        let before = together.checkins
        setMyCheckin(nil)
        let ok = await run(silent: !manual) { try await client.delete("checkins", where: ["user_id": "eq.\(id.uuidString)"]) }
        if ok { UserDefaults.standard.set(false, forKey: "autoCheckin.active") } else { together.checkins = before }
        await refreshTogether()
    }

    func createPlan(meal: Meal, startsAt: Date, note: String, audience: Audience, group: UUID?, invitees: [UUID]) async -> Bool {
        var values: [String: Any] = ["meal": meal.rawValue, "starts_at": SupabaseClient.isoString(startsAt), "audience": audience.rawValue]
        if !note.trimmingCharacters(in: .whitespaces).isEmpty { values["note"] = note }
        if let group { values["group_id"] = group.uuidString }
        let ok = await run {
            let data = try await client.insert("plans", values, returning: true)
            struct Row: Decodable { let id: UUID }
            guard let plan = try SupabaseClient.decoder.decode([Row].self, from: data).first else { return }
            for person in invitees {
                try await client.insert("plan_members", ["plan_id": plan.id.uuidString, "user_id": person.uuidString, "status": "invited"])
            }
        }
        await refreshTogether()
        return ok
    }

    func respond(_ plan: Plan, _ status: RSVP) async {
        guard let id = myId else { return }
        let current = together.plans.first { $0.id == plan.id } ?? plan
        if let me { replacePlan(plan.id, with: current.setting(status, for: me)) }
        let ok = await run {
            if current.status(of: id) == nil {
                try await client.insert("plan_members", ["plan_id": plan.id.uuidString, "user_id": id.uuidString, "status": status.rawValue])
            } else {
                try await client.update("plan_members", where: ["plan_id": "eq.\(plan.id.uuidString)", "user_id": "eq.\(id.uuidString)"],
                                        ["status": status.rawValue, "updated_at": SupabaseClient.isoString(.now)])
            }
        }
        if !ok { replacePlan(plan.id, with: current) }
        await refreshTogether()
    }

    func invite(_ people: [UUID], to plan: Plan) async {
        await run {
            for person in people {
                try await client.insert("plan_members", ["plan_id": plan.id.uuidString, "user_id": person.uuidString, "status": "invited"])
            }
        }
        await refreshTogether()
    }

    /// Swiping away someone else's plan tells the host you can't make it, then hides it from your list.
    func hide(_ plan: Plan) async {
        let previous = plan.status(of: myId)
        setHidden(plan.id, true)
        let declining = Task { await respond(plan, .declined) }
        toast = Toast(message: "Removed \(plan.host.firstName)'s plan", actionTitle: "Undo") { [weak self] in
            await declining.value
            guard let self, let id = self.myId else { return }
            self.setHidden(plan.id, false)
            await self.run {
                let row = ["plan_id": "eq.\(plan.id.uuidString)", "user_id": "eq.\(id.uuidString)"]
                if let previous {
                    try await self.client.update("plan_members", where: row, ["status": previous.rawValue, "updated_at": SupabaseClient.isoString(.now)])
                } else {
                    try await self.client.delete("plan_members", where: row)
                }
            }
            await self.refreshTogether()
        }
        await declining.value
    }

    private func setHidden(_ plan: UUID, _ hidden: Bool) {
        if hidden { hiddenPlans.insert(plan) } else { hiddenPlans.remove(plan) }
        UserDefaults.standard.set(hiddenPlans.map(\.uuidString), forKey: "hiddenPlans")
    }

    /// Cancels right away and offers Undo for a few seconds, instead of asking first.
    func cancel(_ plan: Plan) async {
        replacePlan(plan.id, with: nil)
        let cancelling = Task { await run { try await client.update("plans", where: ["id": "eq.\(plan.id.uuidString)"], ["cancelled": true]) } }
        toast = Toast(message: "Plan cancelled", actionTitle: "Undo") { [weak self] in
            guard await cancelling.value, let self else { return }
            await self.run { try await self.client.update("plans", where: ["id": "eq.\(plan.id.uuidString)"], ["cancelled": false]) }
            await self.refreshTogether()
        }
        if !(await cancelling.value) { toast = nil }
        await refreshTogether()
    }

    // MARK: Friends & groups

    func search(_ q: String) async -> [Person] {
        var out: [Person] = []
        await run(silent: true) { out = try await client.rpc("search_people", ["q": q]) }
        return out
    }

    /// Shows the new friend status right away; the server catches up.
    private func setRelation(_ person: Person, _ relation: String?) {
        people.removeAll { $0.id == person.id }
        guard let relation else { return }
        var p = person
        p.relation = relation
        people.append(p)
        people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Food requests

    private(set) var sentRequests: [SentRequest] = []
    private(set) var popularRequests: [PopularRequest] = []

    func refreshRequests() async {
        guard phase == .ready else { return }
        await run(silent: true) {
            sentRequests = try await client.select("food_requests", ["select": "id,food,meal,note,created_at,sent_at", "order": "created_at.desc", "limit": "50"])
            popularRequests = try await client.rpc("popular_requests", ["days": 7])
        }
    }

    func request(food: String, meal: Meal?, note: String) async -> Bool {
        var values: [String: Any] = ["food": food.trimmingCharacters(in: .whitespaces)]
        if let meal { values["meal"] = meal.rawValue }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { values["note"] = trimmed }
        let ok = await run { try await client.insert("food_requests", values) }
        await refreshRequests()
        return ok
    }

    func withdraw(_ request: SentRequest) async {
        sentRequests.removeAll { $0.id == request.id }
        await run { try await client.delete("food_requests", where: ["id": "eq.\(request.id.uuidString)"]) }
        await refreshRequests()
    }

    func addFriend(_ person: Person) async {
        guard let id = myId else { return }
        setRelation(person, "outgoing")
        await run { try await client.insert("friendships", ["requester": id.uuidString, "addressee": person.id.uuidString]) }
        await refreshPeople()
        await refreshTogether()
    }

    func accept(_ person: Person) async {
        guard let id = myId else { return }
        setRelation(person, "friend")
        await run {
            try await client.update("friendships", where: ["requester": "eq.\(person.id.uuidString)", "addressee": "eq.\(id.uuidString)"], ["status": "accepted"])
        }
        await refreshPeople()
        await refreshTogether()
    }

    /// Unfriend, turn down a request, or take back one you sent.
    func removeFriend(_ person: Person) async {
        guard let id = myId else { return }
        setRelation(person, nil)
        await run {
            try await client.delete("friendships", where: ["requester": "eq.\(id.uuidString)", "addressee": "eq.\(person.id.uuidString)"])
            try await client.delete("friendships", where: ["requester": "eq.\(person.id.uuidString)", "addressee": "eq.\(id.uuidString)"])
        }
        await refreshPeople()
        await refreshTogether()
    }

    func block(_ person: Person) async {
        guard let id = myId else { return }
        setRelation(person, nil)
        if !blocked.contains(where: { $0.id == person.id }) { blocked.insert(person, at: 0) }
        for kind in PostKind.allCases { feeds[kind]?.removeAll { $0.authorId == person.id } }
        if bestToday?.authorId == person.id { bestToday = nil }
        await run { try await client.insert("blocks", ["blocker": id.uuidString, "blocked": person.id.uuidString], upsert: true) }
        await refreshPeople()
        await refreshTogether()
    }

    func unblock(_ person: Person) async {
        guard let id = myId else { return }
        blocked.removeAll { $0.id == person.id }
        await run { try await client.delete("blocks", where: ["blocker": "eq.\(id.uuidString)", "blocked": "eq.\(person.id.uuidString)"]) }
        await refreshBlocked()
        await refreshPeople()
        await refreshTogether()
    }

    /// `groupId` is made by the new-group screen, so its preview shows the group's real initials color.
    func createGroup(id groupId: UUID, name: String, photo: UIImage?, members: [UUID]) async -> Bool {
        guard let id = myId else { return false }
        let ok = await run {
            let photoPath = try await photo.asyncMap { try await uploadSquarePhoto($0, kind: "group") }
            var values: [String: Any] = ["id": groupId.uuidString, "name": name, "created_by": id.uuidString]
            if let photoPath { values["photo_path"] = photoPath }
            do {
                try await client.insert("groups", values)
            } catch {
                if let photoPath { try? await client.deletePhotos([photoPath]) }
                throw error
            }
            for member in members {
                try await client.insert("group_members", ["group_id": groupId.uuidString, "user_id": member.uuidString])
            }
        }
        await refreshGroups()
        return ok
    }

    /// Owner only (the database enforces it). A new photo, or nil to go back to initials.
    @discardableResult
    func setPhoto(_ image: UIImage?, for group: SocialGroup) async -> Bool {
        let old = group.photoPath
        let ok = await run {
            let path = try await image.asyncMap { try await uploadSquarePhoto($0, kind: "group") }
            do {
                try await client.update("groups", where: ["id": "eq.\(group.id.uuidString)"], ["photo_path": path.map { $0 as Any } ?? NSNull()])
            } catch {
                if let path { try? await client.deletePhotos([path]) }
                throw error
            }
        }
        if ok, let old, isMine(old) { try? await client.deletePhotos([old]) }
        await refreshGroups()
        await refreshTogether()
        return ok
    }

    /// A photo in your own folder, which only you can delete.
    private func isMine(_ path: String) -> Bool {
        guard let id = myId else { return false }
        return path.hasPrefix(id.uuidString.lowercased() + "/")
    }

    func add(_ members: [UUID], to group: SocialGroup) async {
        await run {
            for member in members {
                try await client.insert("group_members", ["group_id": group.id.uuidString, "user_id": member.uuidString])
            }
        }
        await refreshGroups()
    }

    func leave(_ group: SocialGroup) async {
        guard let id = myId else { return }
        groups.removeAll { $0.id == group.id }
        await run { try await client.delete("group_members", where: ["group_id": "eq.\(group.id.uuidString)", "user_id": "eq.\(id.uuidString)"]) }
        await refreshGroups()
        await refreshTogether()
    }

    // Owner only (the database enforces it too).
    func remove(_ person: UUID, from group: SocialGroup) async {
        await run { try await client.delete("group_members", where: ["group_id": "eq.\(group.id.uuidString)", "user_id": "eq.\(person.uuidString)"]) }
        await refreshGroups()
    }

    func transfer(_ group: SocialGroup, to person: UUID) async {
        await run { try await client.rpcVoid("transfer_group", ["g": group.id.uuidString, "new_owner": person.uuidString]) }
        await refreshGroups()
    }

    func delete(_ group: SocialGroup) async {
        groups.removeAll { $0.id == group.id }
        let ok = await run { try await client.delete("groups", where: ["id": "eq.\(group.id.uuidString)"]) }
        if ok, let photo = group.photoPath, isMine(photo) { try? await client.deletePhotos([photo]) }
        await refreshGroups()
        await refreshTogether()
    }

    // MARK: Posts

    func post(kind: PostKind, body: String, meal: Meal?, dish: String?, image: UIImage?) async -> Bool {
        guard let id = myId else { return false }
        var uploaded: String?
        let ok = await run {
            var values: [String: Any] = ["kind": kind.rawValue, "body": body.trimmingCharacters(in: .whitespacesAndNewlines)]
            if let meal { values["meal"] = meal.rawValue }
            if let dish, !dish.isEmpty { values["dish"] = dish }
            if let image, let jpeg = image.preparedForUpload() {
                let path = "\(id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                try await client.upload(jpeg: jpeg, to: path)
                uploaded = path
                values["photo_path"] = path
            }
            try await client.insert("posts", values)
        }
        if ok {
            await refreshFeed(kind, sort: feedSort)
        } else if let uploaded {
            try? await client.deletePhotos([uploaded])   // the post didn't go through, so don't leave its photo behind
        }
        return ok
    }

    func toggleVote(_ post: Post) async {
        guard let id = myId else { return }
        setVote(post.id, voted: !post.voted)
        let ok = await run {
            if post.voted {
                try await client.delete("post_votes", where: ["post_id": "eq.\(post.id.uuidString)", "user_id": "eq.\(id.uuidString)"])
            } else {
                try await client.insert("post_votes", ["post_id": post.id.uuidString, "user_id": id.uuidString])
            }
        }
        if !ok { setVote(post.id, voted: post.voted) }
    }

    private func setVote(_ postId: UUID, voted: Bool) {
        for kind in PostKind.allCases {
            guard let i = feeds[kind]?.firstIndex(where: { $0.id == postId }) else { continue }
            let was = feeds[kind]![i].voted
            feeds[kind]![i].voted = voted
            feeds[kind]![i].votes += (voted ? 1 : 0) - (was ? 1 : 0)
        }
        if bestToday?.id == postId, let b = bestToday {
            bestToday?.votes = b.votes + (voted ? 1 : 0) - (b.voted ? 1 : 0)
            bestToday?.voted = voted
        }
    }

    private func removeLocally(_ post: Post) {
        for kind in PostKind.allCases { feeds[kind]?.removeAll { $0.id == post.id } }
        if bestToday?.id == post.id { bestToday = nil }
    }

    /// Hides the post for you right away; three reports hide it for everyone until it's reviewed.
    func report(_ post: Post, reason: String) async {
        guard let id = myId else { return }
        reportedPosts.insert(post.id)
        UserDefaults.standard.set(reportedPosts.map(\.uuidString), forKey: "reportedPosts")
        removeLocally(post)
        toast = Toast(message: "Thanks. You won't see that post again.")
        await run(silent: true) {
            try await client.insert("post_reports", ["post_id": post.id.uuidString, "reporter": id.uuidString, "reason": reason], upsert: true)
        }
    }

    func delete(_ post: Post) async {
        removeLocally(post)
        let ok = await run { try await client.delete("posts", where: ["id": "eq.\(post.id.uuidString)"]) }
        if ok, let path = post.photoPath { try? await client.deletePhotos([path]) }
        if !ok { await refreshFeed(post.kind, sort: feedSort) }
    }

    func photoURL(_ post: Post) -> URL? { post.photoPath.map(client.publicURL) }

    // MARK: Helpers

    @discardableResult
    private func run(silent: Bool = false, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            isOffline = false
            return true
        } catch APIError.notSignedIn {
            reset()
            return false
        } catch {
            if case APIError.offline = error { isOffline = true }
            if !silent { errorMessage = error.localizedDescription }
            return false
        }
    }

    /// A notification for each new invite, when the app is in the background (open, you see it on the Together tab).
    private func notifyAboutNewInvites() {
        let key = "seenInvites"
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let open = UIApplication.shared.applicationState == .active
        for plan in invites where !seen.contains(plan.id.uuidString) {
            seen.insert(plan.id.uuidString)
            if open { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(plan.host.firstName) invited you to \(plan.mealKind?.title.lowercased() ?? "a meal")"
            content.body = [plan.timeLabel, plan.note].compactMap { $0 }.joined(separator: " — ")
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "invite|\(plan.id)", content: content, trigger: nil))
        }
        UserDefaults.standard.set(Array(seen), forKey: key)
    }
}

extension Plan {
    /// The same plan with your RSVP changed, for showing it before the server answers.
    func setting(_ status: RSVP, for person: Person) -> Plan {
        var members = self.members.filter { $0.user.id != person.id }
        members.append(PlanMember(user: person, status: status))
        return Plan(id: id, meal: meal, startsAt: startsAt, note: note, audience: audience, cancelled: cancelled,
                    group: group, host: host, members: members)
    }
}

extension UIImage {
    /// Center-cropped to a 600 px square for profile photos.
    func squareAvatar() -> Data? {
        let side = min(size.width, size.height)
        guard side > 0 else { return nil }
        let target: CGFloat = 600
        let scale = target / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            draw(in: CGRect(x: (target - size.width * scale) / 2, y: (target - size.height * scale) / 2,
                            width: size.width * scale, height: size.height * scale))
        }
        return square.jpegData(compressionQuality: 0.8)
    }

    /// Longest side 1600 px, JPEG ~0.75, which keeps uploads well under the 5 MB storage limit.
    func preparedForUpload() -> Data? {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.75)
    }
}

extension Optional {
    /// `map` for an async transform: nil stays nil.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
