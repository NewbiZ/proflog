import signal
import traceback
import os
import pathlib
import atexit

STACKTRACE_EXTRA = bool(os.environ.get("PROFLOG_STACKTRACE_EXTRA", ""))
STACKTRACE_SIZE = int(os.environ.get("PROFLOG_STACKTRACE_SIZE", "9999"))
STACKTRACE_DIR = os.environ.get("PROFLOG_STACKTRACE_DIR")
STACKTRACE_FILE = None
STACKTRACE_PYTHON_PACKAGES = os.environ.get(
    "PROFLOG_STACKTRACE_PYTHON_PACKAGES", ""
).split(",")


def dump_stacktrace(signal, frame):
    try:
        while frame and frame.f_back:
            f_modname = frame.f_globals.get("__name__", "")
            if not any(
                f_modname.startswith(f"{p}") for p in STACKTRACE_PYTHON_PACKAGES
            ):
                frame = frame.f_back
                continue
            break
        stacktrace = traceback.extract_stack(frame)
        assert STACKTRACE_FILE
        if STACKTRACE_EXTRA:
            txt = " \x1b[0;34m←\x1b[0m ".join(
                f"\x1b[0;34m{pathlib.Path(f.filename).name}:{f.lineno}\x1b[0m {f.line or "?"}".strip()
                for f in stacktrace[::-1][:STACKTRACE_SIZE]
            )
        else:
            txt = " \x1b[0;34m←\x1b[0m ".join(
                (f.line or "").strip() for f in stacktrace[::-1][:STACKTRACE_SIZE]
            )
        print(
            txt,
            file=STACKTRACE_FILE,
            flush=True,
        )
    except:  # noqa
        ...


def cleanup():
    assert STACKTRACE_FILE
    pathlib.Path(STACKTRACE_FILE.name).unlink(missing_ok=True)


def main():
    global STACKTRACE_FILE
    global STACKTRACE_PYTHON_PACKAGES
    if STACKTRACE_DIR:
        pathlib.Path(STACKTRACE_DIR).mkdir(parents=True, exist_ok=True)
        STACKTRACE_FILE = open(pathlib.Path(STACKTRACE_DIR) / str(os.getpid()), "w+")
        signal.signal(signal.SIGUSR1, dump_stacktrace)
        atexit.register(cleanup)


main()
