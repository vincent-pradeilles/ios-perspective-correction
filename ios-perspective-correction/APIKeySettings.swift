import Security
import SwiftUI

// No bundled credentials. The key belongs to the user and is kept on this device.
enum APIKeyStore {
    private static let service = "CardStraight.Photoroom"
    private static let account = "api-key"
    static func read() throws -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageError.failed }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.failed }
            return
        }
        let values: [CFString: Any] = [kSecValueData: Data(key.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageError.failed }
        } else if status != errSecSuccess { throw StorageError.failed }
    }
    private enum StorageError: LocalizedError {
        case failed
        var errorDescription: String? { "The API key couldn’t be accessed securely. Unlock your device and try again." }
    }
}

struct APIKeySettings: View {
    @Environment(\.dismiss) private var dismiss
    let currentKey: String
    let onSave: (String) -> Void
    @State private var key = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Photoroom API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("photoroomAPIKey")
                } header: { Text("Photoroom") } footer: {
                    Text("Use the same API key as the web demo. Your key is stored in this iPhone’s Keychain and sent only to Photoroom.")
                }
                Section {
                    Label("Photos are sent to Photoroom", systemImage: "cloud")
                    Text("Photoroom creates the foreground mask. The app uses it to remove the background and straighten your card. Each scan uses your Photoroom API account.")
                        .foregroundStyle(.secondary)
                    Link("Open Photoroom API dashboard", destination: URL(string: "https://app.photoroom.com/api-dashboard")!)
                }
                if !currentKey.isEmpty {
                    Section { Button("Remove saved key", role: .destructive) { persist("") } }
                }
            }
            .navigationTitle("API settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { persist(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { key = currentKey }
            .alert("Couldn’t save key", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
    private func persist(_ value: String) {
        do {
            try APIKeyStore.save(value)
            onSave(value)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
