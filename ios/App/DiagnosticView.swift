import SwiftUI
import UIKit

/// Affiche le journal interne et, en cas de crash, la derniere etape
/// executee. Sert a localiser un plantage sans console.
struct DiagnosticView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Journal vide" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Diagnostic")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Copier") {
                            UIPasteboard.general.string = text
                        }
                        Button("Effacer le journal", role: .destructive) {
                            CrashLog.clear()
                            text = CrashLog.dump()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear { text = CrashLog.dump() }
        }
    }
}
