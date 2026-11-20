#!/usr/bin/env bash
# Downloads Inworld's golden parity fixtures for the offline model into Fixtures/,
# which Git ignores.
#
# Each fixture holds input.wav, expected.npy, and meta.json.
# expected.npy is the Float32 output of Inworld's training-side reference on the CPU.
# The inputs and the expected arrays derive from a LibriSpeech recording
# and are under CC BY 4.0, so they stay out of this repository.
# See tests/fixtures/README.md in Inworld's repository.
set -euo pipefail

# The commit of https://github.com/inworld-ai/voice-isolator that the port was made from.
revision="c73b3fab81a870410cbac50d2f05f25edc4d10aa"
base="https://raw.githubusercontent.com/inworld-ai/voice-isolator/${revision}/tests/fixtures"
root="$(cd "$(dirname "$0")/.." && pwd)"

for fixture in offline_3s offline_11s; do
    directory="${root}/Fixtures/${fixture}"
    mkdir -p "${directory}"
    for file in input.wav expected.npy meta.json; do
        if [[ ! -s "${directory}/${file}" ]]; then
            echo "Downloading ${fixture}/${file}"
            curl --fail --silent --show-error --location \
                --output "${directory}/${file}" "${base}/${fixture}/${file}"
        fi
    done
    # meta.json records the SHA-256 of the input and of the expected array.
    for pair in "input.wav:input_sha256" "expected.npy:expected_sha256"; do
        file="${pair%%:*}"
        key="${pair##*:}"
        want="$(sed -n "s/.*\"${key}\": \"\([0-9a-f]*\)\".*/\1/p" "${directory}/meta.json")"
        have="$(shasum -a 256 "${directory}/${file}" | cut -d ' ' -f 1)"
        if [[ "${want}" != "${have}" ]]; then
            echo "error: ${fixture}/${file} has SHA-256 ${have}, but meta.json records ${want}" >&2
            exit 1
        fi
    done
done
