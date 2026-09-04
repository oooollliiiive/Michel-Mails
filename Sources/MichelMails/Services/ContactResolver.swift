import Contacts
import Foundation

actor ContactResolver {
    func resolve(_ requested: String) async -> String? {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            guard granted else { return nil }
        } else if status != .authorized {
            return nil
        }

        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
            CNContactEmailAddressesKey
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var candidates: [String] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let fullName = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let names = [fullName, contact.nickname].filter { !$0.isEmpty }
                for name in names {
                    if let email = contact.emailAddresses.first?.value as String? {
                        candidates.append("\(name) <\(email)>")
                    } else {
                        candidates.append(name)
                    }
                }
            }
        } catch {
            return nil
        }

        let resolved = SenderResolver().resolve(requested, among: candidates)
        return resolved == requested ? nil : resolved
    }
}
