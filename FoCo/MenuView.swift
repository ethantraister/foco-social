import SwiftUI

struct MenuView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = 0
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
    private var mains: [FoodItem] { visible.filter(\.isMain) }
    private var saladBar: [FoodItem] { meal.includesSaladBar ? store.saladBar(on: date).filter(prefs.allows) : [] }

    private var stations: [(name: String, items: [FoodItem])] {
        var order: [String] = []
        var groups: [String: [FoodItem]] = [:]
        for item in visible where !item.isMain {
            if groups[item.station] == nil { order.append(item.station) }
            groups[item.station, default: []].append(item)
        }
        return order.map { ($0, groups[$0]!) }
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
            .searchable(text: $query, prompt: "Search this week — steak, sushi…")
            .navigationDestination(for: FoodRoute.self) { FoodDetailView(route: $0) }
        }
    }

    private var menuList: some View {
        List {
            Section {
                DayStrip(selection: $date)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                mealPicker
            }
            .listRowSeparator(.hidden)

            if let social = friendsLine {
                Section {
                    Button { tab = 1 } label: {
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
                .buttonStyle(.bordered)
                .controlSize(typeSize.isAccessibilitySize ? .regular : .small)
                .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if let all = allItems, !all.isEmpty {
            Section {
                if mains.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No main dishes fit your diet this meal.")
                        Button("Show everything") { prefs.filtersPaused = true }
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(mains) { item in
                        NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                            FoodRow(item: item, prominent: true)
                        }
                        .watchSwipe(item.name)
                    }
                }
            } header: {
                Text("Main dishes")
            } footer: {
                if !mains.isEmpty { Text("Swipe right on any dish to get an alert next time it's served.") }
            }

            if !stations.isEmpty {
                Section("Everything else, by station") {
                    ForEach(stations, id: \.name) { station in
                        stationGroup(station.name, subtitle: preview(station.items), items: station.items)
                    }
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
                        .buttonStyle(.borderedProminent)
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
    private let days = (0..<7).map { FoCoCalendar.adding(days: $0, to: FoCoCalendar.startOfDay(.now)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let selected = FoCoCalendar.cal.isDate(day, inSameDayAs: selection)
                    Button { selection = day } label: {
                        VStack(spacing: 2) {
                            Text(label(day)).font(.caption.weight(.semibold))
                            Text(day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).day())).font(.title3.weight(.bold))
                        }
                        .frame(minWidth: size, minHeight: size)
                        .padding(.horizontal, 4)
                        .background(selected ? Color.dartmouthGreen : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
                        .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(FoCoCalendar.relativeName(day) + ", " + day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).month(.wide).day()))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func label(_ d: Date) -> String {
        FoCoCalendar.cal.isDateInToday(d) ? "Today" : d.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).weekday(.abbreviated))
    }
}
