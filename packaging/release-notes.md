qnxprobe {{VERSION}}: standalone Windows executables of `qnxprobe.py` and `qnxprobe_gui.py`, built by this repository's own GitHub Actions workflow from the tagged commit.

- `qnxprobe-{{VERSION}}-windows-x64.zip` runs on Intel and AMD PCs, and on Windows on ARM through its x64 emulation.
- `qnxprobe-{{VERSION}}-windows-arm64.zip` is native for Windows on ARM.

Each zip holds `qnxprobe.exe` (command line), `qnxprobe_gui.exe` (the window), `README.txt`, `LICENSE` and `SHA256SUMS.txt`. `SHA256SUMS.txt` beside the zips covers the zips themselves. The executables are not code signed, so Windows SmartScreen may ask once before running them. Unzip to a local folder rather than running from a network share.

The Python files themselves need nothing built: `python3 qnxprobe.py` works on macOS, Linux and Windows with the standard library alone. See the README for what each release of the tool reads.
