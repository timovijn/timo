import UIKit
import ObjectiveC

/// SwiftUI can't give a submenu the destructive role, so a repeating item's Delete submenu
/// would draw its title and chevron in black. This draws it fully red, like a single item's
/// Delete: UIMenu's `options` answers with `.destructive` added for these titles, which reddens
/// the title, and the menu row's chevron, which iOS draws in the label colour even then, is
/// tinted red when the row lays out. The row is a private UIKit view; if a later iOS renames
/// it, the chevron simply stays black.
enum DestructiveSubmenu {
    /// Titles of submenus to draw as destructive.
    static let titles: Set<String> = ["Delete"]

    static func install() {
        if let original = class_getInstanceMethod(UIMenu.self, #selector(getter: UIMenu.options)),
           let replacement = class_getInstanceMethod(UIMenu.self, #selector(UIMenu.timo_options)) {
            method_exchangeImplementations(original, replacement)
        }
        // Adds an override to the row's content view, calling through to the inherited layout.
        guard let row = NSClassFromString("_UIContextMenuCellContentView"),
              let layout = class_getInstanceMethod(row, #selector(UIView.layoutSubviews)) else { return }
        let selector = #selector(UIView.layoutSubviews)
        let inherited = method_getImplementation(layout)
        let block: @convention(block) (UIView) -> Void = { view in
            typealias Layout = @convention(c) (UIView, Selector) -> Void
            unsafeBitCast(inherited, to: Layout.self)(view, selector)
            tintChevron(in: view)
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(row, selector, implementation, method_getTypeEncoding(layout)) {
            method_setImplementation(layout, implementation)
        }
    }

    private static func tintChevron(in row: UIView) {
        guard row.subviews.contains(where: { view in
            view.allSubviews.contains { ($0 as? UILabel).map { titles.contains($0.text ?? "") } ?? false }
        }) else { return }
        for case let image as UIImageView in row.subviews where image.image?.description.contains("chevron") == true {
            image.tintColor = .systemRed
        }
    }
}

extension UIMenu {
    @objc fileprivate func timo_options() -> UIMenu.Options {
        // After the exchange this calls the original getter.
        let options = timo_options()
        guard DestructiveSubmenu.titles.contains(title), !children.isEmpty else { return options }
        return options.union(.destructive)
    }
}

private extension UIView {
    var allSubviews: [UIView] { [self] + subviews.flatMap(\.allSubviews) }
}
