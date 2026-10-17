import sys

from xgrab.app import main as gui_main


def run() -> None:
    argv = sys.argv[1:]

    # Le navigateur lance l'exe avec le chemin du manifeste JSON en argument.
    if argv and argv[0].lower().endswith(".json"):
        from xgrab.nativehost import serve

        serve(argv[0])
        return

    gui_main(argv)


if __name__ == "__main__":
    run()
