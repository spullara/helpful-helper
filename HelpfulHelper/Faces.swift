import Vision
import UIKit
import CoreML

class Faces {
    let facesModel: VNCoreMLModel
    
    init() {
        guard let model = try? VNCoreMLModel(for: FaceId_resnet50_quantized(configuration: MLModelConfiguration()).model) else {
            fatalError("Failed to load Face Embedding model")
        }
        self.facesModel = model
    }

    func getFaceEmbedding(for image: UIImage) -> MLMultiArray? {
        guard let cgImage = image.cgImage else { return nil }
        
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
        let request = VNCoreMLRequest(model: facesModel)
        
        do {
            try handler.perform([request])
            guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                  let embedding = results.first?.featureValue.multiArrayValue else {
                return nil
            }
            return embedding
        } catch {
            print("Failed to get face embedding: \(error)")
            return nil
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}