import Foundation
import DragonKit

/// ClipMenu's release notes for DragonKit's shared What's New pane. Update per
/// release alongside the CFBundleShortVersionString bump in Info.plist.
enum WhatsNewConfig {
    @MainActor
    static var content: WhatsNewContent {
        WhatsNewContent(
            // Version omitted on purpose: it defaults to CFBundleShortVersionString
            // and the kit adds the "v". The pane tracks the current build's notes.
            date: "2026-11-07",
            // Maintenance only: DragonKit 4.3.0 → 4.4.0. The one thing a user can see is About's
            // "Built with · DragonKit v4.4.0" row, so the pane says that and claims nothing more.
            summary: L("app.whatsNew.summary"),
            sections: [
                ChangeSection(kind: .changed, entries: [
                    L("app.whatsNew.changed1"),
                ]),
            ]
        )
    }
}
