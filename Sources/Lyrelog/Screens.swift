#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Tell Lyrelog this view is a screen: `screen_viewed` when it appears, and its name on
    /// every event while it's the latest one shown.
    public func lyrelogScreen(_ name: String, attrs: [String: Lyrelog.LogValue] = [:]) -> some View {
        onAppear { Lyrelog.screen(name, attrs: attrs) }
    }
}
#endif
