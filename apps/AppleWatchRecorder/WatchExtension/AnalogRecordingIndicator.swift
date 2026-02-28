import SwiftUI

struct AnalogRecordingIndicator: View {
  let isRecording: Bool
  let date: Date

  var body: some View {
    GeometryReader { geometry in
      let size = min(geometry.size.width, geometry.size.height)
      let radius = size / 2
      let seconds = Calendar.current.component(.second, from: date)
      let angle = Angle.degrees(Double(seconds) * 6 - 90)

      ZStack {
        Circle()
          .strokeBorder(.white.opacity(0.18), lineWidth: 3)

        ForEach(0 ..< 12, id: \.self) { tick in
          Capsule()
            .fill(.white.opacity(0.45))
            .frame(width: 2, height: tick.isMultiple(of: 3) ? 12 : 8)
            .offset(y: -radius + 12)
            .rotationEffect(.degrees(Double(tick) * 30))
        }

        if isRecording {
          Capsule()
            .fill(.red)
            .frame(width: 2, height: radius - 14)
            .offset(y: -(radius - 14) / 2)
            .rotationEffect(angle)
        }

        Circle()
          .fill(isRecording ? .red : .white.opacity(0.4))
          .frame(width: 10, height: 10)
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }
}
