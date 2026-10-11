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

    var classLabel: String? { classYear.map { "’" + String(String($0).suffix(2)) } }
    var displayName: String { [name, classLabel].compactMap { $0 }.joined(separator: " ") }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

struct Checkin: Codable, Identifiable, Hashable {
    let user: Person
    let spot: String?
    let eta: Date?
    let startedAt: Date
    let expiresAt: Date
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
    func status(of user: UUID?) -> RSVP? { members.first { $0.user.id == user }?.status }

    var timeLabel: String {
        let day = FoCoCalendar.relativeName(startsAt)
        let time = startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz))
        return "\(day) · \(time)"
    }
}

struct Together: Codable {
    var checkins: [Checkin] = []
    var plans: [Plan] = []
}

enum PostKind: String, Codable, CaseIterable, Identifiable {
    case photo, idea, complaint
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: "Plates"
        case .idea: "Ideas"
        case .complaint: "Complaints"
        }
    }
    var singular: String {
        switch self {
        case .photo: "Meal photo"
        case .idea: "Meal idea"
        case .complaint: "Complaint"
        }
    }
    var symbol: String {
        switch self {
        case .photo: "camera"
        case .idea: "lightbulb"
        case .complaint: "exclamationmark.bubble"
        }
    }
    var prompt: String {
        switch self {
        case .photo: "What's on your plate?"
        case .idea: "Share a combo or hack, e.g. “Grill chicken on a Farmstand salad”"
        case .complaint: "What went wrong? Be specific so Dining can fix it."
        }
    }
}

struct Post: Codable, Identifiable, Hashable {
    let id: UUID
    let authorId: UUID
    let authorName: String
    let authorEmoji: String
    let authorPhoto: String?
    let kind: PostKind
    let body: String
    let photoPath: String?
    let meal: String?
    let dish: String?
    let servedOn: String
    let createdAt: Date
    var votes: Int
    var voted: Bool

    var mealKind: Meal? { meal.flatMap(Meal.init) }
    var author: Person { Person(id: authorId, name: authorName, emoji: authorEmoji, photoPath: authorPhoto) }
}

struct SocialGroup: Codable, Identifiable, Hashable {
    struct Member: Codable, Hashable {
        let userId: UUID
        let role: String
        let profiles: Person
    }
    let id: UUID
    let name: String
    /// Left over from before group photos; the app no longer shows it.
    let emoji: String
    /// Group photo in storage (in the folder of whoever set it); when nil the app shows initials.
    var photoPath: String? = nil
    let createdBy: UUID?
    let groupMembers: [Member]

    var people: [Person] { groupMembers.map(\.profiles).sorted { $0.name < $1.name } }
    func isOwner(_ user: UUID?) -> Bool { user != nil && createdBy == user }
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
