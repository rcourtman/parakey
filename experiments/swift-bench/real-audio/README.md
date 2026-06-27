# Private Real-Dictation Fixtures

Put local-only dictation clips here when validating accuracy against
real speech. This directory is ignored by git except for this README.

Use one audio file plus one reference transcript sidecar per clip:

```text
real-audio/
  short-note.wav
  short-note.txt
  noisy-room.m4a
  noisy-room.txt
```

To add an existing local recording safely:

```sh
./add-real-dictation-fixture.sh \
  --id short-note-001 \
  --audio ~/Desktop/short-note.m4a \
  --reference-file ~/Desktop/short-note.txt
```

Then run the model-decision comparison:

```sh
./run-real-model-comparison.sh --trials 3
```

For single-backend debugging:

```sh
./run-real-dictation-regression.sh --backend v3 --trials 5
./run-real-dictation-regression.sh --backend unified --trials 5 --unified-trailing-silence-ms 250
```

Reports are written to `real-results/`, which is also ignored by git.
By default the report redacts reference text, hypothesis text, fixture
filenames, and local paths while still showing latency, memory, and WER.

For a useful model-decision set, aim for 20-50 short clips across these
categories:

- short commands and one-sentence notes
- 30-90 second paragraphs
- final-word stress cases where the last word matters
- quiet speech, fast speech, and natural pauses
- filler-heavy speech if filler removal is enabled in product testing
- punctuation-heavy notes
- mild background noise
- at least a few non-English or mixed-language clips if multilingual
  behavior is in scope

Use `manifest.template.tsv` as a local planning sheet. Copy it to
`manifest.tsv` if you want to track your private set; that copy is ignored
by git.
