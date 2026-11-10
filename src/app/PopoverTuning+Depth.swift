//
// PopoverTuning+Depth.swift
// Tuning for the Depth region of the popover shell.
//
// Kept in its own file so the region can be worked on without touching the
// shared PopoverTuning block in GlassPopover.swift.
//

import SwiftUI

extension PopoverTuning {
    /// The card's warm wash, now a fill of the card's own shape.
    ///
    /// It used to be a second rounded rectangle drawn over the card, inset 6 pt
    /// from its top and with a radius of 10. The inset was the tonal step at
    /// 6 pt and the radius put its arc inside the card's radius 15 arc at the
    /// top corners. As a fill of the card's shape it has no edge of its own.
    /// It sits under the inner shadow rather than over it, so the shadow keeps
    /// the strength it had above the old inset.
    static let cardWash = Color(red: 0.30, green: 0.10, blue: 0.00).opacity(0.14)

    /// The card's hairline, faded out toward the top.
    ///
    /// It used to be a flat white 0.10 stroke on a radius 10 rectangle inset
    /// 6 pt from the card's top. That put a lighter line across the recess at
    /// 6 pt and a second arc inside the card's arc at the top corners. Fading
    /// it to nothing at the top removes both. It reaches full strength at
    /// cardHairlineFullAt, so the bottom tenth, where it pairs with the rim
    /// light, is exactly the flat stroke it was.
    static let cardHairlineOpacity: Double = 0.10
    static let cardHairlineFullAt: CGFloat = 0.9

    static var cardHairline: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(cardHairlineOpacity), location: cardHairlineFullAt)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Blur of the inner shadow, as a multiple of its band width.
    ///
    /// At 0.5 the band's inner boundary at 6 pt was only half softened and kept
    /// a discernible lower edge. At 1 the boundary is fully soft and the shadow
    /// reaches the card colour about 12 pt in, which is the falloff the top
    /// edge wants.
    static let innerShadowBlurScale: CGFloat = 1
}
