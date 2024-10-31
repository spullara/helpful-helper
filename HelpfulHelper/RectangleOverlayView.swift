import SwiftUI
import DockKit

struct RectangleOverlayView: View {
    var trackedSubjects: [DockAccessory.TrackedSubjectType]
    
    var body: some View {
        GeometryReader { geometry in
            ForEach(trackedSubjects.indices, id: \.self) { index in
                if case .person(let person) = trackedSubjects[index],
                   person.saliencyRank == 1 { // Only show the most salient subject
                    let rect = person.rect
                    let scaledRect = CGRect(
                        x: rect.origin.x * geometry.size.width,
                        y: rect.origin.y * geometry.size.height,
                        width: rect.size.width * geometry.size.width,
                        height: rect.size.height * geometry.size.height
                    )
                    
                    Rectangle()
                        .stroke(Color.red, lineWidth: 2)
                        .frame(width: scaledRect.width, height: scaledRect.height)
                        .position(x: scaledRect.midX, y: scaledRect.midY)
                    
                    // Speaking emoji
                    Text("🗣")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                        .opacity(person.speakingConfidence ?? 0)
                        .position(x: scaledRect.minX, y: scaledRect.minY)
                    
                    // Looking at camera emoji
                    Text("👀")
                        .font(.system(size: 36))
                        .foregroundColor(.blue)
                        .opacity(person.lookingAtCameraConfidence ?? 0)
                        .position(x: scaledRect.maxX, y: scaledRect.minY)
                }
            }
        }
    }
}
