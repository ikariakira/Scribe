import SwiftUI

struct PlayerBar: View {
    let player: LecturePlayer

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 6) {
            if player.isReady {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            scrubTime = player.currentTime
                            isScrubbing = true
                        } else {
                            player.seek(to: scrubTime)
                            isScrubbing = false
                        }
                    }
                )

                HStack {
                    Text(Formatters.timestamp(shownTime))
                    Spacer()
                    Text("-" + Formatters.timestamp(max(0, player.duration - shownTime)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack {
                    rateMenu
                    Spacer()
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }
                    .accessibilityLabel("Back 15 seconds")

                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 50))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.horizontal, 22)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                    }
                    .accessibilityLabel("Forward 15 seconds")
                    Spacer()
                    // Balances the speed menu so the play button stays centred.
                    Color.clear.frame(width: 56, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                Label("Audio not available for this lecture", systemImage: "speaker.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var shownTime: TimeInterval {
        isScrubbing ? scrubTime : player.currentTime
    }

    private var rateMenu: some View {
        Menu {
            ForEach(Self.rates, id: \.self) { rate in
                Button {
                    player.setRate(rate)
                } label: {
                    if rate == player.rate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(Self.rateLabel(player.rate))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 56, height: 30)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .accessibilityLabel("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }
}
