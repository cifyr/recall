import SwiftUI

enum ClockHandVisibility {
  case all
  case hourMinute
  case none
}

/// Lightweight clock face using SwiftUI primitives (no Canvas/Metal) to avoid
/// RenderBox stalls on watchOS. 12 tick marks + hands.
struct AnalogRecordingIndicator: View {
  let date: Date
  let handVisibility: ClockHandVisibility

  private var calendar: Calendar {
    var cal = Calendar.autoupdatingCurrent
    cal.timeZone = TimeZone.autoupdatingCurrent
    return cal
  }

  var body: some View {
    GeometryReader { geo in
      let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
      let radius = min(geo.size.width, geo.size.height) / 2

      ZStack {
        ForEach(0..<12, id: \.self) { i in
          TickMark(radius: radius, index: i)
        }

        if handVisibility != .none {
          ClockHand(radius: radius * 0.45, angle: hourAngle, width: 4.5)
          ClockHand(radius: radius * 0.65, angle: minuteAngle, width: 3)
        }
        if handVisibility == .all {
          SecondHand(radius: radius, angle: secondAngle)
        }

        Circle()
          .fill(handVisibility == .all ? Color.red : Color.white)
          .frame(width: 8, height: 8)
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }

  private var hourAngle: Angle {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    let h = Double(c.hour ?? 0).truncatingRemainder(dividingBy: 12)
    let m = Double(c.minute ?? 0)
    return .degrees(h * 30 + m * 0.5)
  }

  private var minuteAngle: Angle {
    let c = calendar.dateComponents([.minute, .second], from: date)
    let m = Double(c.minute ?? 0)
    let s = Double(c.second ?? 0)
    return .degrees(m * 6 + s * 0.1)
  }

  private var secondAngle: Angle {
    let c = calendar.dateComponents([.second], from: date)
    let s = Double(c.second ?? 0)
    return .degrees(s * 6)
  }
}

private struct TickMark: View {
  let radius: CGFloat
  let index: Int

  var body: some View {
    Rectangle()
      .fill(Color.white)
      .frame(width: 2, height: 10)
      .offset(y: -radius + 9)
      .rotationEffect(.degrees(Double(index) * 30))
  }
}

private struct ClockHand: View {
  let radius: CGFloat
  let angle: Angle
  let width: CGFloat

  var body: some View {
    Rectangle()
      .fill(Color.white)
      .frame(width: width, height: radius)
      .offset(y: -radius / 2)
      .rotationEffect(angle)
  }
}

private struct SecondHand: View {
  let radius: CGFloat
  let angle: Angle

  var body: some View {
    Rectangle()
      .fill(Color.red)
      .frame(width: 1.2, height: radius * 0.93)
      .offset(y: -radius * 0.465)
      .rotationEffect(angle)
  }
}
