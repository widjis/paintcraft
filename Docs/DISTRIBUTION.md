# Distributing PaintCraft

The build produces a **universal** (arm64 + x86_64) `PaintCraft.app` inside a
compressed DMG with a drag-to-Applications layout, an install note in Indonesian,
and the README. Everything is reproducible:

```bash
cd PaintCraft
bash scripts/make-dmg.sh
# -> build/PaintCraft-1.0-universal.dmg
# -> build/PaintCraft-1.0-universal.dmg.sha256
```

The script verifies its own output: signature, both architectures, and a full
57-assertion self-test executed **from the mounted DMG**, plus the Applications
symlink. It refuses to finish if any stage fails.

## What is in the DMG

| Item | Purpose |
|---|---|
| `PaintCraft.app` | universal binary, ad-hoc signed by default |
| `Applications` → `/Applications` | drag target for installation |
| `Cara Install.txt` | install steps + Gatekeeper instructions |
| `README.md` | project overview and build instructions |

## Signing and Gatekeeper — read this before sharing

macOS checks two things on another person's Mac: the signature and the
notarization ticket. A locally built app has neither of the two that Gatekeeper
trusts for download-by-stranger distribution.

| Setup | What happens on the recipient's Mac |
|---|---|
| Ad-hoc (`-`, default here) | "cannot be opened because the developer cannot be verified". Recipient must right-click → Open once, or `xattr -dr com.apple.quarantine /Applications/PaintCraft.app` |
| Apple Development cert (present on this machine) | Same warning; that certificate is for local development, not for distribution |
| **Developer ID Application** + notarization | Opens normally, no warning |

To ship without warnings you need an Apple Developer Program membership
(paid) and a **Developer ID Application** certificate. Then:

```bash
# 1. Sign with hardened runtime (required for notarization)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" build/PaintCraft.app

# 2. Create the DMG, then submit it
xcrun notarytool submit build/PaintCraft-1.0-universal.dmg \
  --apple-id "you@example.com" --team-id "TEAMID" \
  --password "app-specific-password" --wait

# 3. Staple the ticket so the DMG validates offline
xcrun stapler staple build/PaintCraft-1.0-universal.dmg
```

`scripts/make-dmg.sh` accepts a signing identity so the rest of the pipeline is
unchanged:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/make-dmg.sh
```

Notarization itself is not automated here because it needs credentials that must
not be stored in this repository.

## Integrity

Every DMG ships with a `.sha256` file. Verify a download with:

```bash
shasum -a 256 -c PaintCraft-1.0-universal.dmg.sha256
```

## System requirements

- macOS 13 or newer.
- Universal: Apple Silicon native; Intel native (no Rosetta needed for the
  app itself on supported Intel Macs; Rosetta only if an Intel Mac runs an
  arm64-only helper, which this app does not).
- No network access is required to run the app. The optional AI Image Creator
  needs a configured OpenAI-compatible endpoint/key and is disabled by default.

## Legal note

PaintCraft is a clean-room reimplementation inspired by the Microsoft Paint
experience. It contains no Microsoft code, icons, strings, or other assets, and
is not affiliated with or endorsed by Microsoft. The name "PaintCraft" is used
to keep the distributed app clearly distinct from Microsoft Paint.
