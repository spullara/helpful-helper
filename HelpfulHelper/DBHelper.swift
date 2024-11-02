import Foundation
import SQLite3

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
}