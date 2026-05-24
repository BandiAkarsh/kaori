## ADDED Requirements

### Requirement: Build pipeline adds third-party apt repositories
The rootfs build SHALL support adding third-party package repositories via GPG key verification and apt sources configuration.

#### Scenario: Brave browser repository added during build
- **WHEN** `scripts/build-rootfs.sh` runs
- **THEN** the Brave browser GPG key is downloaded from `https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg` and saved to `/usr/share/keyrings/brave-browser-archive-keyring.gpg` in the chroot
- **AND** `/etc/apt/sources.list.d/brave-browser-release.list` contains `deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main`
- **AND** `apt-get update` succeeds after adding the repository

### Requirement: Third-party repo is isolated from main Debian repos
The third-party repository configuration MUST use signed-by pinning to prevent package conflicts and supply-chain attacks.

#### Scenario: Packages from Brave repo are verified by signature
- **WHEN** `apt-get install brave-browser` is executed
- **THEN** the package signature is verified against the Brave GPG key
- **AND** no Debian-maintained package overrides Brave's packages or vice versa

### Requirement: Build fails gracefully on missing GPG key
If the third-party GPG key cannot be downloaded, the build MUST fail with a clear error message rather than proceeding with an unsigned repo.

#### Scenario: GPG key download fails
- **WHEN** the curl command to download the Brave GPG key returns a non-zero exit code
- **THEN** the build script exits with an error message indicating the GPG key could not be downloaded
- **AND** no apt sources file is created for Brave
