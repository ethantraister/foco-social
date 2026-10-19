import SwiftUI

struct OnboardingView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarded") private var onboarded = false
    @State private var step = 0
    private let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                if step < steps - 1 {
                    Button("Skip") { finish() }
                }
            }
            .padding(.horizontal)
            .frame(height: 44)

            ScrollView {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: restrictions
                    default: favorites
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Color.dartmouthDeep : Color.secondary.opacity(0.3))
                            .frame(width: i == step ? 22 : 8, height: 8)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(steps)")

                Button {
                    if step < steps - 1 { withAnimation { step += 1 } } else { finish() }
                } label: {
                    Text(step == steps - 1 ? "Start eating" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .glassButton(prominent: true)
            }
            .padding(24)
        }
        .background { Backdrop() }
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandHeader(title: "FOCO Social", subtitle: "What's on at '53 Commons, and who you're eating with.")
            Text("Tell us what you eat and the dishes you like. We'll filter the menu and let you know when your favorites are on.")
                .foregroundStyle(.secondary)
        }
    }

    private var restrictions: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Anything you avoid?", "We'll hide dishes that don't fit. You can change this anytime in Me → My diet.")
            Text("I eat").font(.headline)
            FlowLayout {
                ForEach(Diet.allCases) { diet in
                    Chip(title: diet.title, selected: prefs.require.contains(diet.rawValue)) {
                        prefs.require.formSymmetricDifference([diet.rawValue])
                    }
                }
            }
            Text("Hide food with").font(.headline)
            FlowLayout {
                ForEach(Allergen.allCases) { allergen in
                    Chip(title: allergen.title, selected: prefs.avoid.contains(allergen.rawValue), excludes: true) {
                        prefs.avoid.formSymmetricDifference([allergen.rawValue])
                    }
                }
            }
            Text("Dining doesn't label peanuts or tree nuts. With a serious allergy, always confirm at the station.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("What do you love?", "Pick a few and we'll notify you when they're on the menu.")
            FlowLayout {
                ForEach(Suggestions.foods, id: \.self) { food in
                    Chip(title: food, selected: prefs.isWatching(food)) { prefs.toggleWatch(food) }
                }
            }
            Text("You can follow any food later: tap the bell on the menu, or swipe right on a dish.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func title(_ t: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.system(.largeTitle, design: .serif).weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        onboarded = true
        if !prefs.watches.isEmpty {
            Task {
                await AlertScheduler.requestPermission()
                await AlertScheduler.reschedule()
            }
        }
        dismiss()
    }
}
