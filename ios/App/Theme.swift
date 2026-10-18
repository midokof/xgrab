import SwiftUI

/// Palette et composants partages. Le bleu reste celui du PC pour que les
/// deux applications se ressemblent.
enum Theme {

    static let accent = Color(red: 0.30, green: 0.56, blue: 0.99)
    static let accentDeep = Color(red: 0.18, green: 0.36, blue: 0.72)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let success = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let danger = Color(red: 0.94, green: 0.33, blue: 0.33)
    static let warning = Color(red: 0.98, green: 0.70, blue: 0.20)

    static let cardRadius: CGFloat = 18
    static let gutter: CGFloat = 16
}

extension View {
    /// Carte blanche/Claire avec ombre douce.
    func cardSurface() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }

    /// Titre de section.
    func sectionLabel() -> some View {
        self
            .font(.system(size: 11, weight: .heavy))
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Bouton principal, plein, avec le degrade de la marque.
struct PrimaryButton: View {
    let title: String
    let systemImage: String
    var fill: LinearGradient = Theme.accentGradient
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
            )
            .foregroundStyle(.white)
            .shadow(color: Theme.accent.opacity(0.35), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// Pastille d'etat.
struct StatusPill: View {
    let title: String
    let colour: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(colour.opacity(0.15)))
            .foregroundStyle(colour)
    }
}

/// Barre de progression fine, avec degrade.
struct ProgressTrack: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// En-tete degrade commun aux ecrans.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            trailing()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(
            Theme.accentGradient
                .ignoresSafeArea(edges: .top)
        )
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}