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

Then run:

```sh
./run-real-dictation-regression.sh --backend v3 --trials 5
```

Reports are written to `real-results/`, which is also ignored by git.
By default the report redacts reference text, hypothesis text, fixture
filenames, and local paths while still showing latency, memory, and WER.
