# Security

Parakey is a local-only dictation tool. It does not transmit audio,
transcripts, or telemetry to any network service.

## Reporting a vulnerability

If you discover a security issue (e.g. a way the app could be coerced
into leaking transcripts, escalate privileges, or be hijacked into
performing unwanted clipboard / paste actions), please **don't open a
public issue**.

Instead, email the maintainer with the details. The repository owner's
contact is listed on their GitHub profile.

## What's in scope

- Anything that lets a non-Parakey process read transcripts in flight,
  or trigger Parakey paste actions.
- Privilege-escalation paths through the app bundle's launcher.
- TCC bypasses or impersonation that misuse Parakey's granted
  permissions.

## What's out of scope

- Issues that require already having local user privileges (e.g. an
  attacker who can already read `~/Library/Logs/Parakey.log` doesn't
  need a vulnerability — they're already on the box).
- Vulnerabilities in upstream dependencies (please report those to
  the upstream project).
- Anything that requires the user to ship a custom build with
  transcript logging deliberately enabled — Parakey as shipped never
  writes transcript content to disk.

## Trust model for the speech model

Parakey's transcription is local, but the speech-recognition weights
themselves are downloaded once on first launch. That download is
handled by the upstream [FluidAudio](https://github.com/FluidInference/FluidAudio)
library, which fetches the Parakeet TDT v3 CoreML model from
[`nvidia/parakeet-tdt-0.6b-v3` on Hugging Face](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
over HTTPS.

What that means for trust:

- The download is HTTPS, with standard macOS TLS certificate
  validation. A passive network attacker cannot tamper with the
  payload.
- FluidAudio does **not** verify a cryptographic checksum or
  signature of the downloaded model files. An attacker who compromises
  the NVIDIA Hugging Face repository, the Hugging Face CDN, or the
  TLS chain could substitute a malicious CoreML graph on a Parakey
  user's first launch. That graph runs on the Apple Neural Engine
  in-process; its output goes to the clipboard and is pasted at the
  cursor, so the realistic abuse channel is attacker-chosen "transcripts"
  rather than direct code execution.
- FluidAudio reads `REGISTRY_URL` and `MODEL_REGISTRY_URL` from the
  process environment to override the download base URL. Parakey
  refuses to launch if either is set — they are a persistence vector
  on macOS (e.g. via a `~/Library/LaunchAgents/*.plist`
  `EnvironmentVariables` block) and Parakey does not document them as
  a feature. If you see Parakey refuse with this error, audit your
  LaunchAgents, shell rc files, and any parent process for an
  injected value before relaunching.

Pinning a known-good SHA-256 for each model file is on the wishlist
but not implemented today. If model integrity is a hard requirement
for your environment, the safest mitigation is to pre-populate
`~/Library/Application Support/FluidAudio/Models/` from a trusted
machine before Parakey's first launch.
