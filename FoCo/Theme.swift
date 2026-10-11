import SwiftUI
import UIKit

/// Dartmouth colors: Dartmouth Green (PMS 349, #00693e) is the app's accent color in Assets,
/// Forest Green (PMS 627, #12312b) is for headers, and white is Snow White (#ffffff).
extension Color {
    /// Read straight from the asset: on a real iPhone the global accent color wasn't being applied, and the app showed iOS blue.
    static let dartmouthGreen = Color("AccentColor")
    static let snow = Color.white
}

enum Theme {
    /// Page titles in Forest Green (white in dark mode, where Forest Green would disappear).
    static func apply() {
        let forest = UIColor(named: "ForestGreen") ?? .label
        let title = UIColor { $0.userInterfaceStyle == .dark ? .white : forest }
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: title]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: title]
        // UIKit pieces (alerts, menus) take the window's tint.
        UIWindow.appearance().tintColor = UIColor(named: "AccentColor")
    }
}

/// Forest Green banner for the welcome and sign-in screens, with the Dartmouth D-Pine (reversed).
/// Brand rules: clear space of a quarter of its height, at least 30 px wide, never altered.
struct BrandHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if UIImage(named: "DPine") != nil {
                    Image("DPine").resizable().scaledToFit()   // official white (reversed) mark, shown unaltered
                } else {
                    Image(systemName: "fork.knife").resizable().scaledToFit().padding(6)
                }
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text(title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).opacity(0.85)
        }
        .foregroundStyle(Color.snow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.forestGreen, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}
