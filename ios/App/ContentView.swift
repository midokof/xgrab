import SwiftUI

@main
struct XGrabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @AppStorage("host", store: Shared.store) private var host = ""
    @AppStorage("port", store: Shared.store) private var port = 38471
    @AppStorage("token", store: Shared.store) private var token = ""

    @State private var status: Status = .idle

    enum Status {
        case idle, testing, ok(String), failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .testing: return "Test en cours..."
            case .ok(let s): return "PC joignable - \(s)"
            case .failed(let s): return s
            }
        }

        var color: Color {
            switch self {
            case .idle, .testing: return .secondary
            case .ok: return .green
            case .failed: return .red
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("XGrab sur iPhone envoie les liens a XGrab tourne sur ton PC. Les deux appareils doivent etre sur le meme reseau Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("PC") {
                    TextField("Adresse IP (ex. 192.168.1.24)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    Stepper("Port : \(port)", value: $port, in: 1024...65535)
                }

                Section("Jeton") {
                    SecureField("Jeton partage", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Dans XGrab sur le PC : Reglages > Activer l'acces iPhone. Le jeton affiche doit etre recopie ici.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            Text("Tester la connexion")
                            Spacer()
                            if status == .testing { ProgressView() }
                        }
                    }
                    .disabled(host.isEmpty || token.isEmpty || status == .testing)

                    if status.text.isEmpty == false {
                        Text(status.text)
                            .font(.footnote)
                            .foregroundStyle(status.color)
                    }
                }

                Section("Extension") {
                    Text("Active l'extension : Reglages > Apps > Safari > Extensions > XGrab. Autorise ensuite l'acces aux sites que tu visites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("XGrab")
        }
    }

    private func test() {
        status = .testing
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/ping")!)
        request.timeoutInterval = 5
        request.setValue(token, forHTTPHeaderField: "X-XGrab-Token")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    status = .failed("Injoignable : \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    status = .failed("Reponse invalide du PC")
                    return
                }
                if http.statusCode == 200 {
                    status = .ok("\(host):\(port)")
                } else {
                    status = .failed("Jeton refuse (HTTP \(http.statusCode))")
                }
            }
        }.resume()
    }
}

enum Shared {
    static let suite = "group.app.xgrab"
    static let store = UserDefaults(suiteName: suite)
}