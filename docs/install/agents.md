# Install Parakey with a shell-capable assistant

Use this prompt on the Mac where Parakey should be installed.

```text
Install Parakey from https://github.com/rcourtman/parakey on this Mac.

Parakey is distributed as a notarised Homebrew Cask. Use the Cask path, not a source build.

1. Confirm this Mac is Apple Silicon:
   uname -m
   It must print arm64. If it does not, stop.
2. Confirm macOS is version 26 or later:
   sw_vers -productVersion
3. Install Homebrew if it is missing.
4. Install Parakey:
   brew install --cask rcourtman/parakey/parakey
5. Launch it:
   open /Applications/Parakey.app
6. Explain that first launch downloads a one-time ~600 MB speech model from Hugging Face and may take 1-5 minutes.
7. Ask the user to open the Parakey menu-bar icon and grant Microphone, Accessibility, and Input Monitoring from the warning rows.
8. After all permission rows disappear, tell the user to hold Right Option, speak, and release. The transcript should paste at the cursor.
```
