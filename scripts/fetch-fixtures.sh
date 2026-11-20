#!/usr/bin/env bash
# Downloads Inworld's golden parity fixtures for the offline model into Fixtures/,
# which Git ignores.
#
# Each fixture holds input.wav, expected.npy, and meta.json.
# expected.npy is the Float32 output of Inworld's training-side reference on the CPU.
# The inputs and the expected arrays derive from a LibriSpeech recording
# and are under CC BY 4.0, so they stay out of this repository.
# See tests/fixtures/README.md in Inworld's repository.
#
# A file is downloaded to a temporary file and moved into place
# only after its SHA-256 digest matches the one that meta.json records.
# A copy that is absent, partial, or wrong is downloaded again,
# and a fixture whose files all match is left as it is, without a request.
set -euo pipefail

# The commit of https://github.com/inworld-ai/voice-isolator that the port was made from.
revision="c73b3fab81a870410cbac50d2f05f25edc4d10aa"
# INWORLD_FIXTURES_URL names another source, such as a mirror or a local copy for a test of this script.
base="${INWORLD_FIXTURES_URL:-https://raw.githubusercontent.com/inworld-ai/voice-isolator/${revision}/tests/fixtures}"
root="$(cd "$(dirname "$0")/.." && pwd)"

# The file that a download is in before it is checked. The trap removes it after a failure.
temporary=""
cleanup() {
    if [[ -n "${temporary}" ]]; then
        rm -f "${temporary}"
    fi
}
trap cleanup EXIT

sha256_of() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

# Prints the digest that a meta.json file records for a key, or nothing.
recorded() {
    sed -n "s/.*\"$2\": \"\([0-9a-f]\{64\}\)\".*/\1/p" "$1"
}

# Succeeds when a file has the digest that a meta.json file records for a key.
matches() {
    local file="$1" meta="$2" key="$3" want
    [[ -s "${file}" && -s "${meta}" ]] || return 1
    want="$(recorded "${meta}" "${key}")"
    [[ -n "${want}" && "$(sha256_of "${file}")" == "${want}" ]]
}

# Downloads one file of a fixture to a new temporary file in a directory.
download() {
    local fixture="$1" file="$2" directory="$3"
    temporary="$(mktemp "${directory}/.${file}.XXXXXX")"
    echo "Downloading ${fixture}/${file}"
    curl --fail --silent --show-error --location \
        --output "${temporary}" "${base}/${fixture}/${file}"
}

for fixture in offline_3s offline_11s; do
    directory="${root}/Fixtures/${fixture}"
    meta="${directory}/meta.json"
    mkdir -p "${directory}"
    if matches "${directory}/input.wav" "${meta}" input_sha256 \
        && matches "${directory}/expected.npy" "${meta}" expected_sha256; then
        continue
    fi

    # meta.json records the SHA-256 of the input and of the expected array.
    download "${fixture}" meta.json "${directory}"
    if [[ -z "$(recorded "${temporary}" input_sha256)" || -z "$(recorded "${temporary}" expected_sha256)" ]]; then
        echo "error: ${fixture}/meta.json does not record the two SHA-256 digests" >&2
        exit 1
    fi
    mv -f "${temporary}" "${meta}"
    temporary=""

    for pair in "input.wav:input_sha256" "expected.npy:expected_sha256"; do
        file="${pair%%:*}"
        key="${pair##*:}"
        if matches "${directory}/${file}" "${meta}" "${key}"; then
            continue
        fi
        download "${fixture}" "${file}" "${directory}"
        want="$(recorded "${meta}" "${key}")"
        have="$(sha256_of "${temporary}")"
        if [[ "${want}" != "${have}" ]]; then
            echo "error: ${fixture}/${file} has SHA-256 ${have}, but meta.json records ${want}" >&2
            exit 1
        fi
        mv -f "${temporary}" "${directory}/${file}"
        temporary=""
    done
done
