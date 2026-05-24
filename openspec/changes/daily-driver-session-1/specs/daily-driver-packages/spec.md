## ADDED Requirements

### Requirement: Installed system has functional web browser
The rootfs MUST include a web browser that can be launched from the desktop and has full audio/video playback and download capabilities.

#### Scenario: Browser launches from terminal
- **WHEN** user runs `brave-browser` in the terminal
- **THEN** the Brave browser window opens and loads the default search page

#### Scenario: Browser survives system snapshot rollback
- **WHEN** user installs an apt update that triggers a pre/post snapshot pair
- **THEN** Brave browser remains installed and functional after any snapshot rollback

### Requirement: Bluetooth devices can pair and connect
The installed system MUST have a functional Bluetooth stack with a tray applet for device management.

#### Scenario: Bluetooth adapter detected
- **WHEN** user runs `systemctl status bluetooth`
- **THEN** the bluetooth service is active and the adapter is listed in `bluetoothctl list`

#### Scenario: Bluetooth device pairing
- **WHEN** user clicks Bluetooth tray icon (blueman-manager)
- **THEN** blueman manager opens and can discover, pair, and connect to nearby Bluetooth devices

### Requirement: WiFi can be managed from the desktop
The installed system MUST have a NetworkManager applet in the system tray.

#### Scenario: NetworkManager applet shows available networks
- **WHEN** user clicks NetworkManager tray icon (nm-applet)
- **THEN** a list of available WiFi networks is displayed

### Requirement: Audio volume can be controlled
The installed system MUST have tools for volume control via GUI and CLI.

#### Scenario: Volume slider in terminal
- **WHEN** user runs `pamixer --get-volume`
- **THEN** the current volume percentage is printed

#### Scenario: Audio mixer GUI opens
- **WHEN** user runs `pavucontrol`
- **THEN** the PulseAudio/PipeWire volume control GUI opens showing input and output devices

### Requirement: Screenshots can be captured
The installed system MUST have tools for full-screen and region screenshots.

#### Scenario: Full screen screenshot captured
- **WHEN** user runs `grim screenshot.png`
- **THEN** a PNG file is saved to the current directory containing the full screen capture

#### Scenario: Region selection screenshot captured
- **WHEN** user runs `grim -g "$(slurp)" screenshot.png`
- **THEN** a PNG file is saved containing only the selected screen region

### Requirement: Clipboard history is available
The installed system MUST have a clipboard manager that persists clipboard history across window switches.

#### Scenario: Clipboard history accessed
- **WHEN** user runs `cliphist list`
- **THEN** a chronological list of clipboard entries is printed

### Requirement: Files can be browsed and managed
The installed system MUST include a graphical file manager.

#### Scenario: File manager opens home directory
- **WHEN** user runs `thunar`
- **THEN** the Thunar file manager window opens showing the user's home directory

### Requirement: Archive files can be extracted
The installed system MUST support extracting common archive formats (zip, 7z, tar.gz).

#### Scenario: Zip archive extracted
- **WHEN** user runs `unzip archive.zip`
- **THEN** the archive contents are extracted to the current directory

#### Scenario: 7z archive extracted
- **WHEN** user runs `7z x archive.7z`
- **THEN** the archive contents are extracted to the current directory

### Requirement: Media keys control audio playback
The installed system MUST respond to media keys (play/pause, next, previous) when a compatible application is running.

#### Scenario: Media key pauses playback
- **WHEN** user presses the media play/pause key
- **THEN** the currently playing audio is paused (verified via playerctl)
