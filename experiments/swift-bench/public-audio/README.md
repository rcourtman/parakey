# Public Speech Fixtures

Generated public benchmark clips live here. The directory is ignored by git
except for this README because the audio comes from third-party datasets and
can be hundreds of megabytes.

Fetch a small LibriSpeech fixture set:

```sh
./fetch-public-speech-fixtures.sh --source librispeech --split dev-clean --count 25
```

Then run the production v3 regression:

```sh
./run-real-dictation-regression.sh --input-dir public-audio/librispeech-dev-clean --out-dir public-results --backend v3 --public-corpus --show-transcripts --show-paths --trials 3
```

For candidate-model evaluation, compare production v3 with the English
Unified model:

```sh
./run-public-model-comparison.sh --trials 3
```

Or fetch and compare in one command:

```sh
./run-public-model-comparison.sh --fetch --count 50 --trials 3
```

The fetcher currently imports LibriSpeech from OpenSLR. LibriSpeech is read
English audiobook speech, aligned to transcripts, and distributed under
CC BY 4.0. That makes it useful as a reproducible public benchmark, but it
does not replace private push-to-talk dictation clips. Keep both:

- public fixtures for reproducible production v3 WER checks and candidate model comparisons
- private real-dictation fixtures for Parakey's actual short, messy workflow

Generated fixture sets contain:

```text
public-audio/librispeech-dev-clean/
  librispeech-dev-clean-0001-84-121123-0000.wav
  librispeech-dev-clean-0001-84-121123-0000.txt
  manifest.tsv
  README.txt
```

The generated `manifest.tsv` records the source corpus, split, original
LibriSpeech ID, original archive member, license, and reference transcript
for each imported clip.
