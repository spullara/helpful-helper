import Foundation
import SQLite3
import CoreML

class DBHelper {
    var db: OpaquePointer?
    let databaseName = "helper.db"
    let lock = NSLock()

    init() {
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
        var statement: OpaquePointer? = nil
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
        var statement: OpaquePointer? = nil
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
    func storeFaceEmbedding(_ embedding: MLMultiArray) -> Int64? {
        let sql = "INSERT INTO face_embeddings (embedding) VALUES (?)"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("Error preparing statement: \(String(cString: sqlite3_errmsg(db)!))")
            return nil
        }
        
        let data = Data(bytes: embedding.dataPointer, count: embedding.count * MemoryLayout<Float>.size)
        sqlite3_bind_blob(statement, 1, (data as NSData).bytes, Int32(data.count), nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            print("Error inserting face embedding: \(String(cString: sqlite3_errmsg(db)!))")
            sqlite3_finalize(statement)
            return nil
        }
        
        let embeddingId = sqlite3_last_insert_rowid(db)
        sqlite3_finalize(statement)
        return embeddingId
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

    // New function to relate a user to an embedding
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
                if let embedding = try? MLMultiArray(data) {
                    embeddings.append(embedding)
                }
            }
        }
        
        sqlite3_finalize(statement)
        return embeddings
    }
}
