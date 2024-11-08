import Foundation
import SQLite3
import CoreML
import UIKit

class DBHelper {
    static let shared = DBHelper()
    
    var db: OpaquePointer?
    let databaseName = "helper.db"
    let lock = NSLock()
    
    private init() {
        db = createDB()
        migrate()
    }
    
    func createDB() -> OpaquePointer? {
        lock.withLock {
            let filePath = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent(databaseName).path
            var db: OpaquePointer? = nil
            if sqlite3_open_v2(filePath, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                print("Successfully opened connection to database at \(filePath)")
                return db
            } else {
                print("Unable to open database.")
                return nil
            }
        }
    }
    
    func migrate() {
        // Create the version table if it doesn't exist
        execSQL(sql: """
            CREATE TABLE IF NOT EXISTS version (
                version INTEGER
            )
        """)
        
        // Get the version from the version table, defaulting to 0
        var version: Int32 = 0
        let query = "SELECT version FROM version"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                version = sqlite3_column_int(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        
        print("Database version: \(version)")
        
        // If the version is 0, insert the initial version
        if version == 0 {
            execSQL(sql: "INSERT INTO version (version) VALUES (1)")
            print("Initialized database version to 1")
        }
        
        // Add new migrations for the new tables
        if version < 2 {
            execSQL(sql: """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL
                )
            """)
            
            execSQL(sql: """
                CREATE TABLE IF NOT EXISTS face_embeddings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    embedding BLOB NOT NULL,
                    date_created DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            execSQL(sql: """
                CREATE TABLE IF NOT EXISTS user_interactions (
                    user_id INTEGER,
                    embedding_id INTEGER,
                    FOREIGN KEY (user_id) REFERENCES users(id),
                    FOREIGN KEY (embedding_id) REFERENCES face_embeddings(id),
                    PRIMARY KEY (user_id, embedding_id)
                )
            """)
            
            updateVersion(newVersion: 2)
        }
        
        if version < 3 {
            execSQL(sql: """
                ALTER TABLE face_embeddings
                ADD COLUMN filename TEXT
            """)
            
            updateVersion(newVersion: 3)
        }
    }
    
    private func execSQL(sql: String) {
        lock.withLock {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                print("SQL Error: \(errmsg) \(sql)")
            } else {
                print("SQL Success: \(sql)")
            }
        }
    }
    
    private func updateVersion(newVersion: Int32) {
        let updateVersion = "UPDATE version SET version = \(newVersion)"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, updateVersion, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                print("Successfully updated version to \(newVersion)")
            } else {
                print("Unable to update version to \(newVersion)")
            }
        }
        sqlite3_finalize(statement)
        print("Migrated to version: \(newVersion)")
    }
    
    // New function to store a face embedding
    func storeFaceEmbedding(_ embedding: MLMultiArray, filename: String) -> Int64? {
        let sql = "INSERT INTO face_embeddings (embedding, filename) VALUES (?, ?)"
        var statement: OpaquePointer?
        
        print("Original embedding data type: \(embedding.dataType), rawValue: \(embedding.dataType.rawValue)")

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return nil
        }
        
        let data = Data(bytes: embedding.dataPointer, count: embedding.count * MemoryLayout<Double>.size)
        sqlite3_bind_blob(statement, 1, (data as NSData).bytes, Int32(data.count), nil)
        sqlite3_bind_text(statement, 2, (filename as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("Error inserting face embedding: \(String(cString: sqlite3_errmsg(db)!))")
            sqlite3_finalize(statement)
            return nil
        }
        
        let embeddingId = sqlite3_last_insert_rowid(db)
        sqlite3_finalize(statement)
        
        return embeddingId
    }
    
    private func blobToMLMultiArray(_ blob: Data) -> MLMultiArray? {
        let elementSize = MemoryLayout<Double>.size
        let count = blob.count / elementSize
        let shape = [NSNumber(value: count)]
        
        do {
            let mlArray = try MLMultiArray(shape: shape, dataType: .double)
            
            blob.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) in
                guard let baseAddress = bufferPointer.baseAddress else {
                    print("Error: couldn't get base address")
                    return
                }
                mlArray.dataPointer.copyMemory(from: baseAddress, byteCount: blob.count)
            }
            
            return mlArray
        } catch {
            print("Error creating MLMultiArray: \(error)")
            return nil
        }
    }

    // New function to add a user
    func addUser(name: String) -> Int64? {
        let sql = "INSERT INTO users (name) VALUES (?)"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return nil
        }
        
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("Error inserting user: \(String(cString: sqlite3_errmsg(db)!))")
            sqlite3_finalize(statement)
            return nil
        }
        
        let userId = sqlite3_last_insert_rowid(db)
        sqlite3_finalize(statement)
        return userId
    }
    
    func relateUserToEmbedding(userId: Int64, embeddingId: Int64) -> Bool {
        let sql = "INSERT INTO user_interactions (user_id, embedding_id) VALUES (?, ?)"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return false
        }
        
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, embeddingId)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("Error relating user to embedding: \(String(cString: sqlite3_errmsg(db)!))")
            sqlite3_finalize(statement)
            return false
        }
        
        sqlite3_finalize(statement)
        return true
    }
    // New function to retrieve embeddings for a user
    func getEmbeddingsForUser(userId: Int64) -> [MLMultiArray] {
        let sql = """
            SELECT fe.embedding
            FROM face_embeddings fe
            JOIN user_interactions ui ON fe.id = ui.embedding_id
            WHERE ui.user_id = ?
            ORDER BY fe.date_created DESC
        """
        var statement: OpaquePointer?
        var embeddings: [MLMultiArray] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return embeddings
        }
        
        sqlite3_bind_int64(statement, 1, userId)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let blobPointer = sqlite3_column_blob(statement, 0)
            let blobSize = sqlite3_column_bytes(statement, 0)
            
            if let blobPointer = blobPointer {
                let data = Data(bytes: blobPointer, count: Int(blobSize))
                if let embedding = blobToMLMultiArray(data) {
                    embeddings.append(embedding)
                }
            }
        }
        
        sqlite3_finalize(statement)
        return embeddings
    }
    func saveFrameAsImage(_ image: UIImage) -> String? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileName = "frame_\(Date().timeIntervalSince1970).jpg"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            print("Error converting image to JPEG data")
            return nil
        }
        
        do {
            try data.write(to: fileURL)
            return fileName
        } catch {
            print("Error saving image: \(error)")
            return nil
        }
    }
    
    func getAllFaceEmbeddings() -> [(MLMultiArray, String)] {
        let sql = "SELECT embedding, filename FROM face_embeddings"
        var statement: OpaquePointer?
        var embeddings: [(MLMultiArray, String)] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return embeddings
        }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let blobPointer = sqlite3_column_blob(statement, 0)
            let blobSize = sqlite3_column_bytes(statement, 0)
            let filename = String(cString: sqlite3_column_text(statement, 1))
            
            if let blobPointer = blobPointer {
                let data = Data(bytes: blobPointer, count: Int(blobSize))
                if let embedding = blobToMLMultiArray(data) {
                    embeddings.append((embedding, filename))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return embeddings
    }
    
    func clearDatabase() {
        let tables = ["face_embeddings", "user_interactions", "users"]
        
        for table in tables {
            let deleteSQL = "DELETE FROM \(table)"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_DONE {
                    print("Successfully cleared table: \(table)")
                } else {
                    print("Error clearing table \(table): \(String(cString: sqlite3_errmsg(db)!))")
                }
            } else {
                print("Error preparing clear statement for table \(table): \(String(cString: sqlite3_errmsg(db)!))")
            }
            
            sqlite3_finalize(statement)
        }
        
        print("Database cleared")
    }

    func getAllUsers() -> [User] {
        var users: [User] = []
        let query = "SELECT id, name FROM users"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let name = String(cString: sqlite3_column_text(statement, 1))
                users.append(User(id: id, name: name))
            }
        }
        sqlite3_finalize(statement)
        return users
    }
    
    func updateUserName(userId: Int64, newName: String) {
        let query = "UPDATE users SET name = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (newName as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, userId)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error updating user name: \(String(cString: sqlite3_errmsg(db)!))")
            }
        }
        sqlite3_finalize(statement)
    }
    
    func unassociateUserFromEmbeddings(userId: Int64) {
        print("Unassociating user from embeddings")
        let query = "DELETE FROM user_interactions WHERE user_id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, userId)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error unassociating user from embeddings: \(String(cString: sqlite3_errmsg(db)!))")
            }
        }
        sqlite3_finalize(statement)
    }

    func associateLastEmbeddingWithUser(userName: String) -> Bool {
        // Get the last face embedding
        let getLastEmbeddingSql = "SELECT id FROM face_embeddings ORDER BY date_created DESC LIMIT 1"
        var statement: OpaquePointer?
        var lastEmbeddingId: Int64?
        
        if sqlite3_prepare_v2(db, getLastEmbeddingSql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                lastEmbeddingId = sqlite3_column_int64(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        
        guard let embeddingId = lastEmbeddingId else {
            print("No face embeddings found")
            return false
        }
        
        // Add or get the user
        let userId = addUser(name: userName) ?? 0
        
        if userId == 0 {
            print("Failed to add or get user")
            return false
        }
        
        // Associate the user with the embedding
        return relateUserToEmbedding(userId: userId, embeddingId: embeddingId)
    }

    func getUnassociatedEmbeddings() -> [(Int64, MLMultiArray, String)] {
        let sql = """
            SELECT id, embedding, filename
            FROM face_embeddings
            WHERE id NOT IN (SELECT embedding_id FROM user_interactions)
        """
        var statement: OpaquePointer?
        var embeddings: [(Int64, MLMultiArray, String)] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return embeddings
        }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let blobPointer = sqlite3_column_blob(statement, 1)
            let blobSize = sqlite3_column_bytes(statement, 1)
            let filename = String(cString: sqlite3_column_text(statement, 2))
            
            if let blobPointer = blobPointer {
                let data = Data(bytes: blobPointer, count: Int(blobSize))
                if let embedding = blobToMLMultiArray(data) {
                    embeddings.append((id, embedding, filename))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return embeddings
    }
    
    func getAssociatedEmbeddings(for userId: Int64) -> [(Int64, MLMultiArray, String)] {
        let sql = """
            SELECT fe.id, fe.embedding, fe.filename
            FROM face_embeddings fe
            JOIN user_interactions ui ON fe.id = ui.embedding_id
            WHERE ui.user_id = ?
        """
        var statement: OpaquePointer?
        var embeddings: [(Int64, MLMultiArray, String)] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return embeddings
        }
        
        sqlite3_bind_int64(statement, 1, userId)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let blobPointer = sqlite3_column_blob(statement, 1)
            let blobSize = sqlite3_column_bytes(statement, 1)
            let filename = String(cString: sqlite3_column_text(statement, 2))
            
            if let blobPointer = blobPointer {
                let data = Data(bytes: blobPointer, count: Int(blobSize))
                if let embedding = blobToMLMultiArray(data) {
                    embeddings.append((id, embedding, filename))
                }
            }
        }
        
        sqlite3_finalize(statement)
        return embeddings
    }
    
    func unassociateEmbeddingFromUser(embeddingId: Int64, userId: Int64) -> Bool {
        let sql = "DELETE FROM user_interactions WHERE user_id = ? AND embedding_id = ?"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return false
        }
        
        sqlite3_bind_int64(statement, 1, userId)
        sqlite3_bind_int64(statement, 2, embeddingId)
        
        let result = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        return result
    }
    
    func getUsersWithEmbeddingInfo() -> [(User, Int, String?)] {
        var usersInfo: [(User, Int, String?)] = []
        let query = """
            SELECT u.id, u.name, COUNT(ui.embedding_id) as embedding_count
            FROM users u
            LEFT JOIN user_interactions ui ON u.id = ui.user_id
            GROUP BY u.id
        """
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let name = String(cString: sqlite3_column_text(statement, 1))
                let embeddingCount = Int(sqlite3_column_int(statement, 2))
                
                // Get the average embedding and closest filename for this user
                let closestFilename = getClosestEmbeddingFilename(userId: id)
                
                usersInfo.append((User(id: id, name: name), embeddingCount, closestFilename))
            }
        }
        sqlite3_finalize(statement)
        return usersInfo
    }
    
    private func getClosestEmbeddingFilename(userId: Int64) -> String? {
        let query = """
            SELECT fe.embedding, fe.filename
            FROM face_embeddings fe
            JOIN user_interactions ui ON fe.id = ui.embedding_id
            WHERE ui.user_id = ?
        """
        var statement: OpaquePointer?
        var embeddings: [(MLMultiArray, String)] = []
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, userId)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let blobPointer = sqlite3_column_blob(statement, 0)
                let blobSize = sqlite3_column_bytes(statement, 0)
                let filename = String(cString: sqlite3_column_text(statement, 1))
                
                if let blobPointer = blobPointer {
                    let data = Data(bytes: blobPointer, count: Int(blobSize))
                    if let embedding = blobToMLMultiArray(data) {
                        embeddings.append((embedding, filename))
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        
        guard !embeddings.isEmpty else { return nil }
        guard let averageEmbedding = averageEmbeddings(embeddings.map { $0.0 }) else { return nil }
        
        return findClosestEmbedding(target: averageEmbedding, embeddings: embeddings)
    }
    
    func findBestMatchingUser(for targetEmbedding: MLMultiArray) -> (User, Double)? {
        let query = """
            SELECT u.id, u.name, fe.embedding
            FROM users u
            JOIN user_interactions ui ON u.id = ui.user_id
            JOIN face_embeddings fe ON ui.embedding_id = fe.id
        """
        var statement: OpaquePointer?
        var bestMatch: (User, Double)? = nil
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let userId = sqlite3_column_int64(statement, 0)
                let name = String(cString: sqlite3_column_text(statement, 1))
                let blobPointer = sqlite3_column_blob(statement, 2)
                let blobSize = sqlite3_column_bytes(statement, 2)
                
                if let blobPointer = blobPointer {
                    let data = Data(bytes: blobPointer, count: Int(blobSize))
                    if let embedding = blobToMLMultiArray(data) {
                        let similarity = calculateCosineSimilarity(embedding1: targetEmbedding, embedding2: embedding)
                        if bestMatch == nil || similarity > bestMatch!.1 {
                            bestMatch = (User(id: userId, name: name), similarity)
                        }
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        
        return bestMatch
    }
    
    func getUsersWithAverageEmbeddings() -> [(User, MLMultiArray)] {
        var usersEmbeddings: [Int64: [MLMultiArray]] = [:]
        var userNames: [Int64: String] = [:]
        var usersWithAverageEmbeddings: [(User, MLMultiArray)] = []
        
        let query = """
            SELECT u.id, u.name, fe.embedding
            FROM users u
            JOIN user_interactions ui ON u.id = ui.user_id
            JOIN face_embeddings fe ON ui.embedding_id = fe.id
        """
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let userId = sqlite3_column_int64(statement, 0)
                let name = String(cString: sqlite3_column_text(statement, 1))
                let blobPointer = sqlite3_column_blob(statement, 2)
                let blobSize = sqlite3_column_bytes(statement, 2)
                
                if let blobPointer = blobPointer {
                    let data = Data(bytes: blobPointer, count: Int(blobSize))
                    if let embedding = blobToMLMultiArray(data) {
                        if usersEmbeddings[userId] == nil {
                            usersEmbeddings[userId] = []
                        }
                        usersEmbeddings[userId]?.append(embedding)
                        userNames[userId] = name
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        
        for (userId, embeddings) in usersEmbeddings {
            if let averageEmbedding = averageEmbeddings(embeddings) {
                let user = User(id: userId, name: userNames[userId] ?? "Unknown")
                usersWithAverageEmbeddings.append((user, averageEmbedding))
            }
        }
        
        return usersWithAverageEmbeddings
    }
}
