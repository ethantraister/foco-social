import Foundation

struct Person: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Left over from before profile photos; the app no longer shows it.
    var emoji: String
    /// Profile photo in storage; when nil the app shows initials.
    var photoPath: String? = nil
    var classYear: Int?
    var relation: String?
    /// You marked them as a close friend (only in your own friends list).
    var close: Bool? = nil

    var classLabel: String? { classYear.map { "’" + String(String($0).suffix(2)) } }
    var displayName: String { [name, classLabel].compactMap { $0 }.joined(separator: " ") }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var isClose: Bool { close == true }
}

/// Who sees your going soon or check-in.
enum ShareWith: String, Codable, CaseIterable, Identifiable {
    case friends, close
    var id: String { rawValue }
    var title: String { self == .friends ? "All friends" : "Close friends" }
}

struct Checkin: Codable, Identifiable, Hashable {
    let user: Person
    let spot: String?
    let eta: Date?
    let startedAt: Date
    let expiresAt: Date
    var audience: ShareWith? = nil
    /// The friend they said "Me too" / "On my way" to.
    var joining: UUID? = nil
    var id: UUID { user.id }

    /// Not there yet: said "I'll be at FoCo in 30 min".
    var isHeading: Bool { eta != nil }
}

struct GroupRef: Codable, Hashable {
    let id: UUID
    let name: String
    let emoji: String
    var photoPath: String? = nil
}

enum RSVP: String, Codable, CaseIterable {
    case invited, going, maybe, declined

    var title: String {
        switch self {
        case .invited: "Invited"
        case .going: "Going"
        case .maybe: "Maybe"
        case .declined: "Can't make it"
        }
    }
}

struct PlanMember: Codable, Hashable {
    let user: Person
    let status: RSVP
    /// The host invited them, so taking back their answer goes back to "invited".
    var wasInvited: Bool? = nil
}

enum Audience: String, Codable, CaseIterable, Identifiable {
    case friends, invited, group
    var id: String { rawValue }
    var title: String {
        switch self {
        case .friends: "All my friends"
        case .invited: "Just people I pick"
        case .group: "A group or team"
        }
    }
    var symbol: String {
        switch self {
        case .friends: "person.2"
        case .invited: "person.crop.circle.badge.checkmark"
        case .group: "person.3"
        }
    }
}

struct Plan: Codable, Identifiable, Hashable {
    let id: UUID
    let meal: String
    let startsAt: Date
    let note: String?
    let audience: Audience
    let cancelled: Bool
    let group: GroupRef?
    let host: Person
    let members: [PlanMember]

    var mealKind: Meal? { Meal(rawValue: meal) }
    var going: [Person] { members.filter { $0.status == .going }.map(\.user) }
    var maybe: [Person] { members.filter { $0.status == .maybe }.map(\.user) }
    var invitedOnly: [Person] { members.filter { $0.status == .invited }.map(\.user) }
    var declined: [Person] { members.filter { $0.status == .declined }.map(\.user) }
    func status(of user: UUID?) -> RSVP? { members.first { $0.user.id == user }?.status }
    func wasInvited(_ user: UUID?) -> Bool { members.first { $0.user.id == user }?.wasInvited == true }

    var timeLabel: String {
        let day = FoCoCalendar.relativeName(startsAt)
        let time = startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz))
        return "\(day) · \(time)"
    }

    /// "Dinner with Maya", "Water Polo · dinner", "Your dinner".
    func title(me: UUID?) -> String {
        let meal = mealKind?.title ?? "Meal"
        if let group { return "\(group.name) · \(meal.lowercased())" }
        if host.id == me { return "Your \(meal.lowercased())" }
        return "\(meal) with \(host.firstName)"
    }
}

struct Together: Codable {
    var checkins: [Checkin] = []
    var plans: [Plan] = []
}

struct SocialGroup: Codable, Identifiable, Hashable {
    struct Member: Codable, Hashable {
        let userId: UUID
        let role: String
        var status: String? = nil
        var invitedBy: UUID? = nil
        let profiles: Person

        var hasJoined: Bool { status != "invited" }
    }
    let id: UUID
    let name: String
    /// Left over from before group photos; the app no longer shows it.
    let emoji: String
    /// Group photo in storage (in the folder of whoever set it); when nil the app shows initials.
    var photoPath: String? = nil
    let createdBy: UUID?
    let groupMembers: [Member]

    /// Everyone who joined.
    var people: [Person] { groupMembers.filter(\.hasJoined).map(\.profiles).sorted { $0.name < $1.name } }
    /// Invited, hasn't answered yet.
    var invited: [Person] { groupMembers.filter { !$0.hasJoined }.map(\.profiles).sorted { $0.name < $1.name } }
    func isOwner(_ user: UUID?) -> Bool { user != nil && createdBy == user }
    func hasJoined(_ user: UUID?) -> Bool { groupMembers.contains { $0.userId == user && $0.hasJoined } }
    func inviter(of user: UUID?) -> Person? {
        guard let by = groupMembers.first(where: { $0.userId == user })?.invitedBy else { return nil }
        return groupMembers.first { $0.userId == by }?.profiles
    }
}

/// A food request you sent through the app; Dining gets them in one email each morning.
struct SentRequest: Codable, Identifiable, Hashable {
    let id: UUID
    let food: String
    let meal: String?
    let note: String?
    let createdAt: Date
    let sentAt: Date?

    var mealKind: Meal? { meal.flatMap(Meal.init(rawValue:)) }
}

struct PopularRequest: Codable, Identifiable, Hashable {
    let food: String
    let students: Int
    let mine: Bool
    var id: String { food.lowercased() }
}

// MARK: Chat

/// A chat: a group's, a meal plan's, or messages with one friend.
enum ChatTarget: Hashable, Codable {
    case group(UUID)
    case plan(UUID)
    case dm(UUID)

    var kind: String {
        switch self {
        case .group: "group"
        case .plan: "plan"
        case .dm: "dm"
        }
    }

    var id: UUID {
        switch self {
        case .group(let id), .plan(let id), .dm(let id): id
        }
    }

    /// "group:<id>": the server's name for it (read receipts, notifications).
    var key: String { "\(kind):\(id.uuidString.lowercased())" }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "group": self = .group(id)
        case "plan": self = .plan(id)
        case "dm": self = .dm(id)
        default: return nil
        }
    }
}

struct ChatThread: Codable, Identifiable, Hashable {
    struct PlanInfo: Codable, Hashable {
        let id: UUID
        let meal: String
        let startsAt: Date
        let host: Person
        let group: GroupRef?
    }
    struct Sender: Codable, Hashable {
        let id: UUID
        let name: String
    }

    let kind: String
    let id: UUID
    let person: Person?
    let group: GroupRef?
    let plan: PlanInfo?
    let lastBody: String?
    let lastAt: Date?
    let lastSender: Sender?
    var unread: Int

    var target: ChatTarget {
        switch kind {
        case "group": .group(id)
        case "plan": .plan(id)
        default: .dm(id)
        }
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let body: String
    let createdAt: Date
    let sender: Person
}

// MARK: Notifications

/// Who you hear about: everyone, close friends only, or nobody.
enum NotifyScope: String, Codable, CaseIterable, Identifiable {
    case all, close, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All friends"
        case .close: "Close friends"
        case .off: "Off"
        }
    }
}

struct NotifySettings: Codable, Hashable {
    var going: NotifyScope = .all
    var arrivals: NotifyScope = .close
    var joins = true
    var plans = true
    var groups = true
    var messages = true
}
