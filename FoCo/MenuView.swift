import SwiftUI

struct MenuView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = AppTab.together.rawValue
    @State private var leftAt: Date?
    @State private var date = FoCoCalendar.startOfDay(.now)
    @State private var meal = UserDefaults.standard.string(forKey: "meal").flatMap(Meal.init) ?? .current
    @State private var expanded: Set<String> = []
    @State private var query = ""

    @Environment(SocialStore.self) private var socialStore

    private var allItems: [FoodItem]? { store.items(on: date, meal: meal) }

    /// "Maya and 2 friends are planning dinner": who you could eat this meal with.
    private var friendsLine: (people: [Person], text: String)? {
        guard socialStore.phase == .ready else { return nil }
        let me = socialStore.myId
        var people: [Person] = []
        for plan in socialStore.together.plans where plan.mealKind == meal && FoCoCalendar.cal.isDate(plan.startsAt, inSameDayAs: date) {
            for p in plan.going where p.id != me && !people.contains(p) { people.append(p) }
        }
        let here = FoCoCalendar.cal.isDateInToday(date) && meal == .current
            ? socialStore.friendsHere.map(\.user).filter { p in !people.contains(p) } : []
        let all = people + here
        guard let first = all.first else { return nil }
        let who = all.count == 1 ? first.firstName : "\(first.firstName) and \(all.count - 1) other\(all.count == 2 ? "" : "s")"
        let verb = people.isEmpty ? "\(all.count == 1 ? "is" : "are") at FoCo now" : "\(all.count == 1 ? "is" : "are") eating \(meal.title.lowercased())"
        return (all, "\(who) \(verb)")
    }
    private var visible: [FoodItem] { (allItems ?? []).filter(prefs.allows) }
    private var saladBar: [FoodItem] { meal.includesSaladBar ? store.saladBar(on: date).filter(prefs.allows) : [] }

    /// Today's desserts, once each (the same cookie can be at two stations).
    private var desserts: [FoodItem] {
        var seen = Set<String>()
        return visible.filter { $0.isDessert && seen.insert($0.name.lowercased()).inserted }
    }

    /// Each station's main dishes up front and everything else under "More". Desserts are in their own section.
    private struct Station: Identifiable {
        let name: String
        var mains: [FoodItem] = []
        var more: [FoodItem] = []
        var id: String { name }
    }

    private var stations: [Station] {
        var order: [String] = []
        var byName: [String: Station] = [:]
        for item in visible where !item.isDessert {
            if byName[item.station] == nil { order.append(item.station); byName[item.station] = Station(name: item.station) }
            if item.isMain { byName[item.station]!.mains.append(item) } else { byName[item.station]!.more.append(item) }
        }
        return order.compactMap { byName[$0] }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    SearchResultsView(query: query)
                } else {
                    menuList
                }
            }
            .navigationTitle("FoCo")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search this week — steak, sushi…")
            .navigationDestination(for: FoodRoute.self) { FoodDetailView(route: $0) }
            .tabRoot()
        }
    }

    private var menuList: some View {
        List {
            // Day and meal float on the backdrop, not in a card: they're controls, so they're glass.
            Section {
                DayStrip(selection: $date)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                mealPicker
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if let social = friendsLine {
                Section {
                    Button { tab = AppTab.together.rawValue } label: {
                        HStack(spacing: 10) {
                            AvatarStack(people: social.people, max: 3, size: 26)
                            Text(social.text).font(.subheadline).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityHint("Opens Together")
                }
            }

            if prefs.hasFilters {
                Section { filterBanner }
            }

            content
        }
        .listStyle(.insetGrouped)
        .onBackdrop()
        .refreshable { await store.load(date: date, meal: meal, force: true) }
        .task(id: "\(date)\(meal)") { await store.load(date: date, meal: meal) }
        .sensoryFeedback(.selection, trigger: meal)
        .sensoryFeedback(.selection, trigger: date)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { leftAt = .now }
            // Back after a while: show what's on now, not the meal you were looking at this morning.
            if phase == .active, let leftAt, Date.now.timeIntervalSince(leftAt) > 30 * 60 {
                date = FoCoCalendar.startOfDay(.now)
                meal = .current
            }
        }
    }

    @ViewBuilder private var mealPicker: some View {
        if typeSize.isAccessibilitySize {
            Picker("Meal", selection: $meal) {
                ForEach(Meal.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
        } else {
            Picker("Meal", selection: $meal) {
                ForEach(Meal.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var filterBanner: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: prefs.filtersPaused ? "eye" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prefs.filtersPaused ? "Showing everything" : "Filtered for your diet")
                        .font(.subheadline.weight(.semibold))
                    Text(prefs.filterSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            Button(prefs.filtersPaused ? "Use my diet" : "Show all") { prefs.filtersPaused.toggle() }
                .glassButton()
                .controlSize(typeSize.isAccessibilitySize ? .regular : .small)
                .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if let all = allItems, !all.isEmpty {
            if !desserts.isEmpty {
                Section {
                    DessertStrip(items: desserts, date: date, meal: meal)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                } header: {
                    Label("Desserts \(FoCoCalendar.phrase(date))", systemImage: "birthday.cake.fill")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(Color.dessert)
                        .textCase(nil)
                }
            }

            let withMains = stations.filter { !$0.mains.isEmpty }
            if withMains.isEmpty && !visible.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No main dishes fit your diet this meal.")
                        if prefs.filtering { Button("Show everything") { prefs.filtersPaused = true } }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(withMains) { station in
                Section {
                    ForEach(station.mains) { item in
                        NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                            FoodRow(item: item, prominent: true, showStation: false)
                        }
                        .watchSwipe(item.name)
                    }
                    if !station.more.isEmpty {
                        moreGroup("More from \(station.name)", items: station.more, key: station.name)
                    }
                } header: {
                    SectionTitle(station.name)
                } footer: {
                    if station.id == withMains.first?.id { Text("Swipe right on any dish to get an alert next time it's served.") }
                }
            }

            let sidesOnly = stations.filter { $0.mains.isEmpty && !$0.more.isEmpty }
            if !sidesOnly.isEmpty {
                Section {
                    ForEach(sidesOnly) { station in
                        stationGroup(station.name, subtitle: preview(station.more), items: station.more)
                    }
                } header: {
                    SectionTitle("Sides, salads, and more")
                }
            }

            if !saladBar.isEmpty {
                Section {
                    stationGroup("Salad Bar", subtitle: "Open all day · \(saladBar.count) items", items: saladBar, showStation: false)
                }
            }
        } else if store.isLoading(date, meal) {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(meal.title.lowercased())…").foregroundStyle(.secondary)
                }
            }
        } else if let error = store.error(date, meal) {
            Section {
                ContentUnavailableView {
                    Label("Can't load the menu", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await store.load(date: date, meal: meal, force: true) } }
                        .glassButton(prominent: true)
                }
            }
        } else {
            Section {
                ContentUnavailableView(
                    "No \(meal.title.lowercased()) posted",
                    systemImage: meal.symbol,
                    description: Text("Dining hasn't posted a \(meal.title.lowercased()) menu \(FoCoCalendar.phrase(date)). Try another meal or day.")
                )
            }
        }
    }

    private func stationGroup(_ name: String, subtitle: String, items: [FoodItem], showStation: Bool = false) -> some View {
        DisclosureGroup(isExpanded: binding(for: name)) {
            ForEach(items) { item in
                NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                    FoodRow(item: item, showStation: showStation)
                }
                .watchSwipe(item.name)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name).font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(items.count) items")
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            .padding(.vertical, 2)
        }
    }

    /// "More from Hearth (6)": a station's sides, sauces, and everyday items, folded away.
    private func moreGroup(_ title: String, items: [FoodItem], key: String) -> some View {
        DisclosureGroup(isExpanded: binding(for: "more|" + key)) {
            ForEach(items) { item in
                NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                    FoodRow(item: item, showStation: false)
                }
                .watchSwipe(item.name)
            }
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(items.count) items")
            }
        }
    }

    private func preview(_ items: [FoodItem]) -> String {
        let names = items.prefix(3).map(\.name)
        let extra = items.count - names.count
        return names.joined(separator: ", ") + (extra > 0 ? " +\(extra) more" : "")
    }

    private func binding(for station: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(station) },
            set: { if $0 { expanded.insert(station) } else { expanded.remove(station) } }
        )
    }
}

struct SearchResultsView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    let query: String

    private var groups: [(title: String, hits: [SearchHit])] {
        var order: [String] = []
        var map: [String: [SearchHit]] = [:]
        for hit in store.search(query) where prefs.allows(hit.item) {
            let title = "\(FoCoCalendar.relativeName(hit.date)) · \(hit.meal.title)"
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(hit)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.hits) { hit in
                        NavigationLink(value: FoodRoute(item: hit.item, date: hit.date, meal: hit.meal)) {
                            FoodRow(item: hit.item)
                        }
                        .watchSwipe(hit.item.name)
                    }
                }
            }
            Section {
                let q = query.trimmingCharacters(in: .whitespaces)
                Button {
                    prefs.toggleWatch(q)
                    Task {
                        await AlertScheduler.requestPermission()
                        await AlertScheduler.reschedule()
                    }
                } label: {
                    Label(prefs.isWatching(q) ? "You'll be alerted for “\(q)”" : "Alert me whenever “\(q)” is served",
                          systemImage: prefs.isWatching(q) ? "bell.fill" : "bell.badge")
                }
            } footer: {
                Text("Searches the posted menus for the next 7 days.")
            }
        }
        .task { await store.loadUpcoming() }
    }
}

struct DayStrip: View {
    @Binding var selection: Date
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 54
    @Namespace private var glassSpace
    private let days = (0..<7).map { FoCoCalendar.adding(days: $0, to: FoCoCalendar.startOfDay(.now)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        let selected = FoCoCalendar.cal.isDate(day, inSameDayAs: selection)
                        Button { withAnimation(.snappy) { selection = day } } label: {
                            VStack(spacing: 1) {
                                Text(label(day)).font(.caption.weight(.semibold))
                                Text(day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).day()))
                                    .font(.title3.weight(.bold).monospacedDigit())
                            }
                            .frame(minWidth: size, minHeight: size)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .glass(in: .rect(cornerRadius: 18), tint: selected ? .dartmouthDeep : nil, interactive: true)
                            .glassID(day, in: glassSpace)
                            .contentShape(.rect(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(FoCoCalendar.relativeName(day) + ", " + day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).month(.wide).day()))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .noTabBarMargin()
    }

    private func label(_ d: Date) -> String {
        FoCoCalendar.cal.isDateInToday(d) ? "Today" : d.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).weekday(.abbreviated))
    }
}

extension Color {
    /// The dessert highlight: a warm raspberry, so desserts stand out from the green.
    static let dessert = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.95, green: 0.42, blue: 0.58, alpha: 1)
        : UIColor(red: 0.70, green: 0.13, blue: 0.34, alpha: 1) })
}

/// Desserts as big cards you scroll sideways through, at the top of the menu.
private struct DessertStrip: View {
    let items: [FoodItem]
    let date: Date
    let meal: Meal

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Spacer(minLength: 0)
                            Text(item.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let cal = item.calories {
                                Text("\(Int(cal)) cal").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(14)
                        // Every card as tall as the tallest, so long names wrap instead of being cut off.
                        .frame(width: 156, alignment: .bottomLeading)
                        .frame(minHeight: 128, maxHeight: .infinity, alignment: .bottomLeading)
                        .background(DessertCardFill(seed: item.name), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.accessibilitySummary)
                    .watchSwipe(item.name)
                }
            }
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .noTabBarMargin()
    }
}

/// Each dessert card gets its own warm color (raspberry, berry, caramel, plum…), always the same for the same dessert.
private struct DessertCardFill: ShapeStyle {
    let seed: String
    // Dark enough at both ends for white text.
    private static let pairs: [(Color, Color)] = [
        (Color(red: 0.62, green: 0.12, blue: 0.30), Color(red: 0.80, green: 0.27, blue: 0.33)),
        (Color(red: 0.45, green: 0.13, blue: 0.38), Color(red: 0.66, green: 0.22, blue: 0.45)),
        (Color(red: 0.52, green: 0.25, blue: 0.08), Color(red: 0.70, green: 0.38, blue: 0.13)),
        (Color(red: 0.33, green: 0.16, blue: 0.46), Color(red: 0.55, green: 0.27, blue: 0.56)),
        (Color(red: 0.58, green: 0.16, blue: 0.16), Color(red: 0.76, green: 0.33, blue: 0.24)),
    ]

    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.pairs.count
        let (a, b) = Self.pairs[index]
        return LinearGradient(colors: [b, a], startPoint: .topTrailing, endPoint: .bottomLeading)
    }
}
