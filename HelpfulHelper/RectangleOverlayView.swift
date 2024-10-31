import SwiftUI

struct RectangleOverlayView: View {
    var rects: [UUID: CGRect]
    
    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(rects.keys), id: \.self) { id in
                if let rect = rects[id] {
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
                }
            }
        }
    }
}