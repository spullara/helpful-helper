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

    func findFaces(image: UIImage) -> MLMultiArray? {
        var faces: [(UIImage, MLMultiArray)] = []
        let faceReq = VNDetectFaceRectanglesRequest()

        let photoImage = image.cgImage!
        let handler = VNImageRequestHandler(cgImage: photoImage,
                orientation: CGImagePropertyOrientation(image.imageOrientation),
                options: [:])

        try? handler.perform([faceReq])
        guard let faceObservations = faceReq.results else {
            return nil
        }
        for faceObservation: VNFaceObservation in faceObservations {
            var box: CGRect = VNImageRectForNormalizedRect(faceObservation.boundingBox, photoImage.width, photoImage.height)
            box.origin = .init(x: box.minX, y: CGFloat(photoImage.height) - box.maxY)
            guard let faceCroppedImage = photoImage.cropping(to: box) else {
                fatalError("No rect!")
            }
            let face = UIImage(cgImage: faceCroppedImage)
            if let faceVector = getFaceEmbedding(for: face) {
                faces.append((face, faceVector))
            }
        }

        // Only return the biggest face
        faces.sort { $0.0.size.width * $0.0.size.height > $1.0.size.width * $1.0.size.height }

        return faces.first?.1
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
            // Normalize the embedding to unit length
            return normalizeEmbedding(embedding)
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
