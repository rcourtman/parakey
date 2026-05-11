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
