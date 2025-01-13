# proflog

Profile timing of a running program logs.

## Example

    $ proflog bash -c 'echo 1; sleep 1; echo 2; sleep 1; echo 3; sleep 1'
    00:00.956 ▏ 1
    00:01.006 ▏ 2
    00:00.955 ▏ 3

## Build

There are no external dependencies. For a static release build, simply run:

    $ zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
    $ tree zig-out/
    zig-out/
    └── bin
        └── proflog

    2 directories, 1 file
