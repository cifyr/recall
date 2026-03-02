import SwiftUI

#if os(iOS)
struct AskQuestionComposer: View {
  @Binding var question: String
  let isSubmitting: Bool
  let onSubmit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Ask about this session", text: $question, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2 ... 5)
      Button(isSubmitting ? "Answering..." : "Ask") {
        onSubmit()
      }
      .disabled(isSubmitting || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}
#endif
