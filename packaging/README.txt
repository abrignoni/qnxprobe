qnxprobe, built as standalone Windows executables
==================================================

  qnxprobe.exe        the command line tool. Open a command prompt in this
                      folder and run, for example:
                          qnxprobe.exe --self-test
                          qnxprobe.exe mmcblk0.img
                          qnxprobe.exe --list --depth 3 mmcblk0.img
                          qnxprobe.exe --extract out.zip mmcblk0.img
                          qnxprobe.exe --help

  qnxprobe_gui.exe    the window. Double-click it, add an image, and press
                      Run report, Extract to zip, or open the Contents tab and
                      press Load contents.

  SHA256SUMS.txt      the hashes of both executables as built. Check them with
                          certutil -hashfile qnxprobe.exe SHA256

Both open the image read-only and never write to it. Neither installs anything
or needs administrator rights. They are built from the same two Python files in
https://github.com/abrignoni/qnxprobe by the repository's own GitHub Actions
workflow, and are not code signed, so Windows SmartScreen may ask once before
running them.

The x64 build runs on Intel and AMD PCs, and on Windows on ARM through its
built-in x64 emulation. The arm64 build is native for Windows on ARM.
