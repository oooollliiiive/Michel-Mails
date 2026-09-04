# Michel Mails — project rules

- Keep the user-facing application name exactly `Michel Mails`.
- Keep the bundle identifier stable: `com.michelos.michelmails`.
- The only user-facing installed copy is `/Applications/Michel Mails.app`.
- `.build/app/Michel Mails.app` is an internal build artifact. Never open it or present it as the app to launch.
- Building or installing must never launch Michel Mails automatically. Do not use `open`, `open -a`, or otherwise start the app after a build or installation.
- The user launches Michel Mails themselves from its icon in Applications or the Dock.
