# Codag releases

This public repository contains verified installers and compiled release
artifacts for the Codag CLI. The product source remains private.

Install on macOS, Linux, or WSL:

```sh
curl -fsSL https://codag.ai/install.sh | sh
codag setup
```

Release archives are built by GitHub Actions from an exact tag in the private
source repository, checksummed, and covered by GitHub build-provenance
attestations.

`vX.Y.Z` tags in the private source repository identify source. The matching
immutable release here is the customer-facing artifact. `provenance.json`
records the full source commit without exposing the private repository.

The installers require a SHA-256 checksum tool. When the GitHub CLI is
available they also verify GitHub's build attestation; set
`CODAG_REQUIRE_ATTESTATION=1` to make that optional verification mandatory.
