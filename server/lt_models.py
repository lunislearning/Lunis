"""Download the LibreTranslate (Argos) language models for the given languages.

Run with the LibreTranslate virtualenv's Python, while the machine has internet:
    <venv-python> server/lt_models.py en fr es de
    <venv-python> server/lt_models.py --check en fr es de    (offline: only verify)

The classroom box may never be online again, so the installers fetch everything
translation needs up front instead of leaving it to LibreTranslate's first start:
the translation model for every pair, and the small sentence-splitting model
(MiniSBD) for every language, which Argos otherwise downloads on first use. Safe
to re-run: what is already installed is skipped. Exit code 1 if anything failed.
"""
import sys


def sentence_models(langs, check_only):
    """Argos >= 1.10 splits sentences with MiniSBD and fetches its model per source
    language on first use. Fetch them now (or, offline, check they are there)."""
    try:
        import os
        from argostranslate import settings
        from minisbd import models as sbd
    except ImportError:
        return 0                                    # older Argos: uses the packaged stanza model
    sbd.cache_dir = str(settings.data_dir / "minisbd")
    failed = 0
    for lang in sorted(langs):
        if lang not in sbd.list_models():
            continue
        path = os.path.join(sbd.cache_dir, sbd.MODELS[lang])
        if os.path.isfile(path):
            print("  [ok] sentence model %s present" % lang)
            continue
        if check_only:
            failed += 1
            print("  [!]  sentence model %s missing" % lang)
            continue
        try:
            sbd.get_model_file(lang)
            print("  [ok] sentence model %s downloaded" % lang)
        except Exception as e:
            failed += 1
            print("  [!]  sentence model %s failed: %s" % (lang, e))
    return failed


def main(argv):
    check_only = "--check" in argv
    langs = set(a for a in argv if not a.startswith("-")) or {"en", "fr", "es", "de"}
    import argostranslate.package as pkg

    have = {(p.from_code, p.to_code) for p in pkg.get_installed_packages()}
    if check_only:
        missing = [(a, b) for a in sorted(langs) for b in sorted(langs)
                   if a != b and (a == "en" or b == "en") and (a, b) not in have]
        for a, b in missing:
            print("  [!]  %s->%s not installed" % (a, b))
        for a, b in sorted(have):
            if a in langs and b in langs:
                print("  [ok] %s->%s installed" % (a, b))
        return 1 if (missing or sentence_models(langs, True)) else 0

    pkg.update_package_index()
    wanted = [p for p in pkg.get_available_packages()
              if p.from_code in langs and p.to_code in langs]
    failed = 0
    for p in sorted(wanted, key=lambda p: (p.from_code, p.to_code)):
        pair = "%s->%s" % (p.from_code, p.to_code)
        if (p.from_code, p.to_code) in have:
            print("  [ok] %s already installed" % pair)
            continue
        try:
            print("  ...  %s downloading" % pair, flush=True)
            pkg.install_from_path(p.download())
            print("  [ok] %s installed" % pair)
        except Exception as e:                      # keep going; report at the end
            failed += 1
            print("  [!]  %s failed: %s" % (pair, e))
    if not wanted:
        print("  [!]  the package index lists no models for %s" % ", ".join(sorted(langs)))
        return 1
    failed += sentence_models(langs, False)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
