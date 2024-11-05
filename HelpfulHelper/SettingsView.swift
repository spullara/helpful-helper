import SwiftUI
import CoreML

struct SettingsView: View {
    @State private var users: [(User, Int, String?)] = []
    @State private var newUserName: String = ""
    @State private var selectedUser: User?
    @State private var isEditingUser: Bool = false
    @Environment(\.presentationMode) var presentationMode
    @FocusState private var isNewUserNameFocused: Bool
    
    let dbHelper = DBHelper()
    
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
                                    dbHelper.addUser(name: newUserName)
                                    loadUsers()
                                    newUserName = ""
                                    isNewUserNameFocused = false
                                }
                            }
                        }
                    }
                    
                    Section(header: Text("Existing Users")) {
                        ForEach(users, id: \.0.id) { user, embeddingCount, closestFilename in
                            HStack {
                                if let filename = closestFilename, let image = loadImage(filename: filename) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(25)
                                } else {
                                    Image(systemName: "person.circle")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 50, height: 50)
                                        .foregroundColor(.gray)
                                }
                                
                                VStack(alignment: .leading) {
                                    Text(user.name)
                                    Text("\(embeddingCount) embeddings")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("Edit") {
                                    selectedUser = user
                                    isEditingUser = true
                                }
                                
                                Button("Unassociate") {
                                    dbHelper.unassociateUserFromEmbeddings(userId: user.id)
                                    loadUsers()
                                }
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear(perform: loadUsers)
            .sheet(isPresented: $isEditingUser) {
                if let user = selectedUser {
                    EditUserView(user: user, onSave: { updatedName in
                        dbHelper.updateUserName(userId: user.id, newName: updatedName)
                        loadUsers()
                        isEditingUser = false
                    })
                }
            }
        }
    }
    
    private func loadUsers() {
        users = dbHelper.getUsersWithEmbeddingInfo()
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
    @State private var associatedEmbeddings: [(Int64, MLMultiArray, String)] = []
    @State private var unassociatedEmbeddings: [(Int64, MLMultiArray, String)] = []
    @State private var averageEmbedding: MLMultiArray?
    @Environment(\.presentationMode) var presentationMode
    let dbHelper = DBHelper()
    
    init(user: User, onSave: @escaping (String) -> Void) {
        self.user = user
        self.onSave = onSave
        _editedName = State(initialValue: user.name)
    }
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("User Name")) {
                    TextField("User Name", text: $editedName)
                }
                
                Section(header: Text("Associated Embeddings")) {
                    ForEach(associatedEmbeddings, id: \.0) { embeddingId, _, filename in
                        HStack {
                            Image(uiImage: loadImage(filename: filename) ?? UIImage())
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                            Text(filename)
                            Spacer()
                            Button("Unassociate") {
                                unassociateEmbedding(embeddingId: embeddingId)
                            }
                        }
                    }
                }
                
                Section(header: Text("Unassociated Embeddings")) {
                    ForEach(unassociatedEmbeddings, id: \.0) { embeddingId, embedding, filename in
                        HStack {
                            Image(uiImage: loadImage(filename: filename) ?? UIImage())
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                            Text(filename)
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
                leading: Button("Cancel") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("Save") {
                    onSave(editedName)
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .onAppear(perform: loadEmbeddings)
        }
    }
    
    private func loadEmbeddings() {
        associatedEmbeddings = dbHelper.getAssociatedEmbeddings(for: user.id)
        unassociatedEmbeddings = dbHelper.getUnassociatedEmbeddings()
        calculateAverageEmbedding()
    }
    
    private func calculateAverageEmbedding() {
        guard !associatedEmbeddings.isEmpty else {
            averageEmbedding = nil
            return
        }
        
        let embeddingSize = associatedEmbeddings[0].1.count
        var averageValues = [Double](repeating: 0, count: embeddingSize)
        
        for (_, embedding, _) in associatedEmbeddings {
            for i in 0..<embeddingSize {
                averageValues[i] += embedding[i].doubleValue
            }
        }
        
        for i in 0..<embeddingSize {
            averageValues[i] /= Double(associatedEmbeddings.count)
        }
        
        averageEmbedding = try? MLMultiArray(shape: [embeddingSize as NSNumber], dataType: .double)
        for i in 0..<embeddingSize {
            averageEmbedding?[i] = NSNumber(value: averageValues[i])
        }
        
        sortUnassociatedEmbeddings()
    }
    
    private func sortUnassociatedEmbeddings() {
        guard let averageEmbedding = averageEmbedding else { return }
        
        unassociatedEmbeddings.sort { (embedding1, embedding2) in
            let distance1 = calculateDistance(embedding1.1, averageEmbedding)
            let distance2 = calculateDistance(embedding2.1, averageEmbedding)
            return distance1 < distance2
        }
    }
    
    private func calculateDistance(_ embedding1: MLMultiArray, _ embedding2: MLMultiArray) -> Double {
        var distance: Double = 0
        for i in 0..<embedding1.count {
            let diff = embedding1[i].doubleValue - embedding2[i].doubleValue
            distance += diff * diff
        }
        return sqrt(distance)
    }
    
    private func associateEmbedding(embeddingId: Int64, embedding: MLMultiArray) {
        if dbHelper.associateEmbeddingWithUser(embeddingId: embeddingId, userId: user.id) {
            if let index = unassociatedEmbeddings.firstIndex(where: { $0.0 == embeddingId }) {
                let associatedEmbedding = unassociatedEmbeddings.remove(at: index)
                associatedEmbeddings.append(associatedEmbedding)
                calculateAverageEmbedding()
            }
        }
    }
    
    private func unassociateEmbedding(embeddingId: Int64) {
        if dbHelper.unassociateEmbeddingFromUser(embeddingId: embeddingId, userId: user.id) {
            if let index = associatedEmbeddings.firstIndex(where: { $0.0 == embeddingId }) {
                let unassociatedEmbedding = associatedEmbeddings.remove(at: index)
                unassociatedEmbeddings.append(unassociatedEmbedding)
                calculateAverageEmbedding()
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