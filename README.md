# a11y-runner-probe

A small public probe: can an automated job start VoiceOver on GitHub-hosted macOS runners (macos-15 and macos-26), move it through a native app (TextEdit), and read back what it says as text?

Two arms: Guidepup's VoiceOver driver, and raw osascript to VoiceOver. Results are in each run's log ("VERDICT" line) and uploaded artifacts.

Contains no application code. Part of agent-driven accessibility testing for native Mac apps.
