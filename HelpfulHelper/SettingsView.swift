import SwiftUI
import CoreML

struct SettingsView: View {
    @State private var users: [(User, Int, String?)] = []
    @State private var newUserName: String = ""
    @State private var selectedUser: User?
    @State private var isEditingUser: Bool = false
    @FocusState private var isNewUserNameFocused: Bool
    @State private var showUnassociateConfirmation = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isNewUserNameFocused = false
                    }
                
                List {
                    Section(header: Text("Create New User")) {
                        HStack {
                            TextField("New User Name", text: $newUserName)
                                .focused($isNewUserNameFocused)
                            Button("Add") {
                                if !newUserName.isEmpty {
                                    if let _ = DBHelper.shared.addUser(name: newUserName) {
                                        loadUsers()
                                        newUserName = ""
                                    }
                                }
                            }
                        }
                    }
                    
                    Section(header: Text("Users")) {
                        ForEach(users, id: \.0.id) { user, embeddingCount, closestFilename in
                            HStack {
                                if let closestFilename = closestFilename {
                                    Image(uiImage: loadImage(filename: closestFilename) ?? UIImage())
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 50, height: 50)
                                }

                                VStack(alignment: .leading) {
                                    Text(user.name)
                                    Text("Embeddings: \(embeddingCount)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                Button("Edit") {
                                    print("Edit user: \(user.name)")
                                    selectedUser = user
                                }
                                
                                Button("Unassociate") {
                                    DBHelper.shared.unassociateUserFromEmbeddings(userId: user.id)
                                    loadUsers()
                                }.buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadUsers)
            .sheet(item: $selectedUser) { user in
                EditUserView(user: user, onSave: { updatedName in
                    print("Saving")
                    DBHelper.shared.updateUserName(userId: user.id, newName: updatedName)
                    loadUsers()
                })
            }
        }
    }
    
    private func loadUsers() {
        users = DBHelper.shared.getUsersWithEmbeddingInfo()
    }
    
    
    private func loadImage(filename: String) -> UIImage? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent(filename)
        return UIImage(contentsOfFile: fileURL.path)
    }
}

struct EditUserView: View {
    let user: User
    let onSave: (String) -> Void
    @State private var editedName: String
    @State private var associatedEmbeddings: [(Int64, MLMultiArray, String, Double)] = []
    @State private var unassociatedEmbeddings: [(Int64, MLMultiArray, String, Double)] = []
    @State private var averageEmbedding: MLMultiArray?
    @Environment(\.dismiss) private var dismiss
    
    init(user: User, onSave: @escaping (String) -> Void) {
        self.user = user
        self.onSave = onSave
        _editedName = State(initialValue: user.name)
        print("EditUserView initialized for user: \(user.name)")
    }
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("User Name")) {
                    TextField("User Name", text: $editedName)
                }
                
                Section(header: Text("Associated Embeddings")) {
                    ForEach(associatedEmbeddings, id: \.0) { embeddingId, _, filename, similarity in
                        HStack {
                            Image(uiImage: loadImage(filename: filename) ?? UIImage())
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading) {
                                Text(filename)
                                Text("Similarity: \(similarity, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button("Unassociate") {
                                unassociateEmbedding(embeddingId: embeddingId)
                            }
                        }
                    }
                }
                
                Section(header: Text("Unassociated Embeddings")) {
                    ForEach(unassociatedEmbeddings, id: \.0) { embeddingId, embedding, filename, similarity in
                        HStack {
                            Image(uiImage: loadImage(filename: filename) ?? UIImage())
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading) {
                                Text(filename)
                                Text("Similarity: \(similarity, specifier: "%.2f")")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button("Associate") {
                                associateEmbedding(embeddingId: embeddingId, embedding: embedding)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit User")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save") {
                    onSave(editedName)
                    dismiss()
                }
            )
            .onAppear(perform: loadEmbeddings)
        }
    }
    
    private func loadEmbeddings() {
        let associatedEmbeddingsRaw = DBHelper.shared.getAssociatedEmbeddings(for: user.id)
        let unassociatedEmbeddingsRaw = DBHelper.shared.getUnassociatedEmbeddings()
        averageEmbedding = averageEmbeddings(associatedEmbeddingsRaw.map(\.1))
        
        associatedEmbeddings = associatedEmbeddingsRaw.map { (id, embedding, filename) in
            let similarity = calculateCosineSimilarity(embedding1: embedding, embedding2: averageEmbedding!)
            return (id, embedding, filename, similarity)
        }
        
        unassociatedEmbeddings = unassociatedEmbeddingsRaw.map { (id, embedding, filename) in
            if let avg = averageEmbedding {
                let similarity = calculateCosineSimilarity(embedding1: embedding, embedding2: avg)
                return (id, embedding, filename, similarity)
            }
            return (id, embedding, filename, 0.0)
        }
        
        sortUnassociatedEmbeddings()
    }
    
    private func sortUnassociatedEmbeddings() {
        unassociatedEmbeddings.sort { $0.3 > $1.3 }
    }
    
    private func associateEmbedding(embeddingId: Int64, embedding: MLMultiArray) {
        if DBHelper.shared.relateUserToEmbedding(userId: user.id, embeddingId: embeddingId) {
            if let index = unassociatedEmbeddings.firstIndex(where: { $0.0 == embeddingId }) {
                let associatedEmbedding = unassociatedEmbeddings.remove(at: index)
                associatedEmbeddings.append(associatedEmbedding)
                averageEmbedding = averageEmbeddings(associatedEmbeddings.map { $0.1 })
                loadEmbeddings()
            }
        }
    }
    
    private func unassociateEmbedding(embeddingId: Int64) {
        if DBHelper.shared.unassociateEmbeddingFromUser(embeddingId: embeddingId, userId: user.id) {
            if let index = associatedEmbeddings.firstIndex(where: { $0.0 == embeddingId }) {
                let unassociatedEmbedding = associatedEmbeddings.remove(at: index)
                unassociatedEmbeddings.append(unassociatedEmbedding)
                averageEmbedding = averageEmbeddings(associatedEmbeddings.map { $0.1 })
                loadEmbeddings()
            }
        }
    }
    
    private func loadImage(filename: String) -> UIImage? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent(filename)
        return UIImage(contentsOfFile: fileURL.path)
    }
}

struct User: Identifiable {
    let id: Int64
    var name: String
}
