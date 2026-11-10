//
// PopoverTuning+Outline.swift
// Tuning for the Outline region of the popover shell.
//
// Kept in its own file so the region can be worked on without touching the
// shared PopoverTuning block in GlassPopover.swift.
//

import SwiftUI

extension PopoverTuning {
    // Notch. The tab is a caret, not a hump: a flat base, two straight flanks
    // meeting at roughly a right angle, and a tip radius small enough to read
    // as a point. notchBaseWidth is where the flank lines meet the top edge;
    // the shoulder fillets start a little further out, so the flat part of the
    // top edge is a touch wider than the base.
    //
    // The shell pads its content by notchCaretHeight, so the body's top edge
    // and the caret's base are the same line.
    static let notchBaseWidth: CGFloat = 23
    static let notchCaretHeight: CGFloat = 10.5
    static let notchShoulderFillet: CGFloat = 4
    static let notchTipRadius: CGFloat = 2

    // Top-right corner. Almost square, so the shell does not read as a rounded
    // rectangle on that side. The curve starts 1.5 radii before the corner and
    // eases in, the way a continuous corner does, instead of turning as a
    // quarter circle.
    static let topRightCornerRadius: CGFloat = 5
}
