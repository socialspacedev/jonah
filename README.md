# Touchwheel

Copy chosen songs off an old iPod (1G–5G, e.g. the 3rd-gen touch-wheel model) onto your Mac.

- Plug in the iPod. Touchwheel finds it and lists every song from its database.
- Tick songs (checkbox, Space, or double-click), search to narrow, then **Export…**.
- Files are copied into `Artist / Album / NN Title.ext`. Nothing on the iPod is changed, and nothing at the destination is overwritten.
- If the iPod's database is damaged, songs are listed from the audio files' own tags instead.

## Build

    ./build.sh            # debug build + launch
    ./build.sh release    # optimised build → dist/Touchwheel.app

Needs only the Command Line Tools (no Xcode).

## Getting a 3G iPod to mount

It needs to appear in Finder as a drive. If it doesn't, force disk mode: hold **Menu + Play/Pause** until the Apple logo, then immediately hold **Previous + Next** until "Do not disconnect" appears.

Songs bought from the iTunes Store before 2009 (`.m4p`) copy fine but stay DRM-locked.

## Testing without the UI

    .build/debug/Touchwheel --list <ipod-root>
    .build/debug/Touchwheel --export <ipod-root> <dest>
