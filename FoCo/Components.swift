import SwiftUI

struct FoodRoute: Hashable {
    let item: FoodItem
    let date: Date
    let meal: Meal
}

extension FoodItem {
    var accessibilitySummary: String {
        var parts = [name, "\(station) station"]
        if let calories { parts.append("\(Int(calories)) calories") }
        if let protein { parts.append("\(Int(protein)) grams of protein") }
        if !diets.isEmpty { parts.append(diets.map(\.title).joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

struct FoodRow: View {
    @Environment(Preferences.self) private var prefs
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: FoodItem
    var prominent = false
    var showStation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let title = HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name)
                    .font(prominent ? .headline : .body)
                    .fixedSize(horizontal: false, vertical: true)
                if prefs.isWatching(item.name) {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(.tint)
                }
            }
            if typeSize.isAccessibilitySize {
                title
                DietBadges(item: item)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    DietBadges(item: item)
                }
            }
            detailLine
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, prominent ? 4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilityValue(prefs.isWatching(item.name) ? "Alert on" : "")
        .accessibilityHint("Shows nutrition and allergens")
    }

    private var detailLine: Text {
        var parts: [String] = []
        if showStation { parts.append(item.station) }
        if let macros = item.macroLine { parts.append(macros) }
        var line = Text(parts.joined(separator: " · "))
        if prefs.filtering && !item.hasAllergenInfo {
            line = line + Text(" · not labeled").foregroundStyle(.orange)
        }
        return line
    }
}

struct DietBadges: View {
    let item: FoodItem
    var body: some View {
        HStack(spacing: 3) {
            ForEach(item.diets.filter { !($0 == .vegetarian && item.tags.contains("vegan")) }) { diet in
                Text(diet.short)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.dartmouthGreen.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityHidden(true)
    }
}

struct WatchSwipe: ViewModifier {
    @Environment(Preferences.self) private var prefs
    let name: String

    func body(content: Content) -> some View {
        let on = prefs.isWatching(name)
        content
            .swipeActions(edge: .leading) {
                Button { toggle() } label: {
                    Label(on ? "Stop alerts" : "Alert me", systemImage: on ? "bell.slash" : "bell")
                }
                .tint(on ? .gray : .dartmouthGreen)
            }
            .contextMenu {
                Button { toggle() } label: {
                    Label(on ? "Stop alerts for \(name)" : "Alert me when \(name) is served", systemImage: on ? "bell.slash" : "bell")
                }
            }
            .accessibilityAction(named: on ? "Stop alerts" : "Alert me when served") { toggle() }
    }

    private func toggle() {
        prefs.toggleWatch(name)
        Task {
            await AlertScheduler.requestPermission()
            await AlertScheduler.reschedule()
        }
    }
}

extension View {
    func watchSwipe(_ name: String) -> some View { modifier(WatchSwipe(name: name)) }
}

/// Wraps chips onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                y += rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + min(size.width, width)
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    var systemImage: String? = nil
    /// For "hide food that contains": selected means excluded, so it shows a red ✕ and a strikethrough.
    var excludes = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: excludes ? "xmark" : systemImage ?? "checkmark").font(.caption.weight(.bold)) }
                else if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title).strikethrough(excludes && selected)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(background, in: .capsule)
            .overlay { if excludes && selected { Capsule().strokeBorder(Color.red.opacity(0.6)) } }
            .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(excludes && selected ? "Hidden" : "")
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var background: Color {
        guard selected else { return Color.secondary.opacity(0.12) }
        return excludes ? Color.red.opacity(0.12) : Color.dartmouthGreen
    }

    private var foreground: Color {
        guard selected else { return .primary }
        return excludes ? .red : Color(uiColor: .systemBackground)   // snow white in light mode; dark text on the lighter dark-mode green
    }
}

enum Suggestions {
    static let foods = ["Steak", "Sushi", "Chicken Tenders", "Pad Thai", "Salmon", "Mac & Cheese", "Pancakes", "Burrito", "Stir Fry", "Quesadilla", "Meatballs", "Waffles"]
}
