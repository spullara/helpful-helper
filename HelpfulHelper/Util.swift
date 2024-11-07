//
//  Util.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 11/5/24.
//
import CoreML
import Foundation

func calculateCosineSimilarity(embedding1: MLMultiArray, embedding2: MLMultiArray) -> Double {
    var dotProduct: Double = 0
    var magnitude1: Double = 0
    var magnitude2: Double = 0
    
    for i in 0..<embedding1.count {
        let value1 = embedding1[i].doubleValue
        let value2 = embedding2[i].doubleValue
        dotProduct += value1 * value2
        magnitude1 += value1 * value1
        magnitude2 += value2 * value2
    }
    
    magnitude1 = sqrt(magnitude1)
    magnitude2 = sqrt(magnitude2)
    
    print("Magnitude 1: \(magnitude1) Magnitude 2: \(magnitude2) Dot Product: \(dotProduct)")

    return dotProduct / (magnitude1 * magnitude2)
}

func averageEmbeddings(_ embeddings: [MLMultiArray]) -> MLMultiArray? {
    guard !embeddings.isEmpty else { return nil }
    
    let embeddingSize = embeddings[0].count
    var averageValues = [Double](repeating: 0, count: embeddingSize)
    
    for embedding in embeddings {
        for i in 0..<embeddingSize {
            averageValues[i] += embedding[i].doubleValue
        }
    }
    
    for i in 0..<embeddingSize {
        averageValues[i] /= Double(embeddings.count)
    }
    
    let mlMultiArray = try? MLMultiArray(shape: [NSNumber(value: embeddingSize)], dataType: .double)
    for i in 0..<embeddingSize {
        mlMultiArray?[i] = NSNumber(value: averageValues[i])
    }
    
    // Normalize the average embedding
    if let normalizedEmbedding = mlMultiArray {
        return normalizeEmbedding(normalizedEmbedding)
    }
    
    return mlMultiArray
}

func findClosestEmbedding(target: MLMultiArray, embeddings: [(MLMultiArray, String)]) -> String? {
    guard !embeddings.isEmpty else { return nil }
    
    var closestDistance = Double.infinity
    var closestFilename: String?
    
    for (embedding, filename) in embeddings {
        let distance = calculateCosineSimilarity(embedding1: target, embedding2: embedding)
        if distance < closestDistance {
            closestDistance = distance
            closestFilename = filename
        }
    }
    
    return closestFilename
}

func normalizeEmbedding(_ embedding: MLMultiArray) -> MLMultiArray {
    var norm: Double = 0.0
    for i in 0..<embedding.count {
        let value = embedding[i].doubleValue
        norm += value * value
    }
    let norm_sqrt = sqrt(norm)
    
    let normalizedEmbedding = try! MLMultiArray(shape: embedding.shape, dataType: .double)
    for i in 0..<embedding.count {
        normalizedEmbedding[i] = NSNumber(value: embedding[i].doubleValue / norm_sqrt)
    }
    return normalizedEmbedding
}
