import SwiftUI

/// Direction A — Steam π / Espresso
enum CPTheme {
    static let bg = Color(red: 0.10, green: 0.08, blue: 0.07)          // #1A1412
    static let panel = Color(red: 0.14, green: 0.11, blue: 0.10)       // #241C19
    static let composer = Color(red: 0.18, green: 0.14, blue: 0.12)    // #2E241F
    static let bubbleUser = Color(red: 0.24, green: 0.17, blue: 0.13)  // #3C2B21
    static let border = Color(red: 0.90, green: 0.82, blue: 0.70).opacity(0.12)
    static let text = Color(red: 0.96, green: 0.91, blue: 0.84)        // #F5E8D6 cream
    static let muted = Color(red: 0.90, green: 0.82, blue: 0.70).opacity(0.55)
    static let accent = Color(red: 0.85, green: 0.68, blue: 0.45)      // warm latte
    static let espresso = Color(red: 0.24, green: 0.14, blue: 0.08)    // #3C2415
}
