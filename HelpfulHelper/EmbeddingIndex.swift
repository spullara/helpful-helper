//
// Created by Sam Pullara on 4/11/22.
//

import Foundation
import BFES

func withArrayOfCStrings<R>(
    _ args: [String],
    _ body: ([UnsafePointer<CChar>?]) -> R
) -> R {
    let cStrings = args.map { UnsafePointer(strdup($0)) }
    defer {
        cStrings.forEach { free(UnsafeMutableRawPointer(mutating: $0)) }
    }
    return body(cStrings)
}

class EmbeddingIndex {
    var dim: Int
    var name: String
    var index: UInt = 0

    var localIdentifiers:[String] = []
    let indexLock = NSLock()
    
    init(name: String, dim: Int) {
        self.name = name
        self.dim = dim
        bfes_new_index(indexName(name), dim)
    }

    func clear() {
        bfes_new_index(indexName(name), dim)
        indexLock.lock()
        localIdentifiers = []
        indexLock.unlock()
    }
    
    private func indexName(_ name: String) -> UnsafeMutablePointer<CChar>? {
        UnsafeMutablePointer<CChar>(mutating: (name as NSString).utf8String)
    }

    func add(vector: [Float], localIdentifier: String) {
        bfes_add(indexName(name), vector, dim)
        indexLock.lock()
        localIdentifiers.append(localIdentifier)
        indexLock.unlock()
    }

    func search(vector: [Float], k: Int) -> [(Int, Float)] {
        print("Searching index")
        let result: Vec_SearchResult_t = bfes_search(indexName(name), k, vector, dim);
        var resultArray = [(Int, Float)]()
        for i in 0..<result.len {
            resultArray.append((result.ptr[i].index, result.ptr[i].score))
        }
        return resultArray
    }
    
    func getLocalIdentifier(_ index: Int) -> String {
        indexLock.lock();
        let id = localIdentifiers[index]
        indexLock.unlock()
        return id
    }
    
    func getCount() -> Int {
        indexLock.lock();
        let count = localIdentifiers.count
        indexLock.unlock()
        return count
    }
}
