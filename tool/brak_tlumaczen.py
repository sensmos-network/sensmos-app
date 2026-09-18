# -*- coding: utf-8 -*-
"""Znajduje napisy, ktore user zobaczy PO POLSKU, bo nie ma ich w slowniku.

W tej apce kluczem tlumaczenia jest polski tekst: `tr('Ile kopii')`. Gdy brakuje wpisu,
`tr` konczy sie `?? pl` i pokazuje polski KAZDEMU — cicho, bez bledu, bez ostrzezenia
kompilatora. Flota jest w 95% spoza Polski, wiec to trafia glownie do ludzi, ktorzy tego
jezyka nie znaja.

Uruchomienie (przed KAZDYM wydaniem APK):
    python tool/brak_tlumaczen.py
Kod wyjscia 1 = sa braki.
"""
import io, os, re, sys, glob

KORZEN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(KORZEN, 'lib')

# tr('...') i tr("...") — z pojedynczym argumentem tekstowym, bez interpolacji
TR = re.compile(r"""\btr\(\s*(['"])((?:(?!\1)[^\\]|\\.)*)\1""")
OGONKI = re.compile('[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]')


_ESC = {'n': '\n', 't': '\t', 'r': '\r', "'": "'", '"': '"', '\\': '\\', '$': '$'}


def odkoduj(s):
    """Zamienia escape'y Darta na znaki — BEZ psucia UTF-8.

    Kusi, zeby napisac `s.encode().decode('unicode_escape')`, i wlasnie na tym sie przejechalem:
    to przepuszcza bajty UTF-8 przez latin-1, wiec kazdy polski znak zamienia sie w krzaki,
    a klucz przestaje pasowac do czegokolwiek w slowniku. Cicho, bez bledu.
    """
    wynik, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            n = s[i + 1]
            if n == 'u':
                m = re.match(r'\\u\{([0-9a-fA-F]+)\}|\\u([0-9a-fA-F]{4})', s[i:])
                if m:
                    wynik.append(chr(int(m.group(1) or m.group(2), 16)))
                    i += m.end()
                    continue
            wynik.append(_ESC.get(n, n))
            i += 2
            continue
        wynik.append(s[i])
        i += 1
    return ''.join(wynik)


def klucze_slownika(nazwa_mapy, pliki):
    """Klucze jednej mapy jezykowej — czytane ze zrodla, bo to zwykly const Map."""
    klucze = set()
    for p in pliki:
        s = io.open(p, encoding='utf-8').read()
        # Szukamy DEFINICJI mapy, nie pierwszej wzmianki o niej. Nazwa pada wczesniej w tablicy
        # jezykow (`'de': _deMap`), wiec `find(nazwa)` startowal tuz pod nia i zbieral klucze
        # WSZYSTKICH map ponizej — kazdy napis wygladal na przetlumaczony wszedzie i narzedzie
        # zawsze pokazywalo zero brakow.
        i = s.find(nazwa_mapy + ' = {')
        if i < 0:
            i = s.find(nazwa_mapy + '= {')
        if i < 0:
            continue
        # koniec mapy: pierwsza linia zaczynajaca sie od '};' po jej poczatku
        koniec = s.find(chr(10) + '};', i)
        s = s[:koniec] if koniec > 0 else s
        # od nawiasu klamrowego do konca mapy; wystarczy nam zgrubnie — bierzemy
        # wszystkie literaly po lewej stronie dwukropka
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*:', s[i:]):
            klucze.add(odkoduj(m.group(1)))
    return klucze


LIT = re.compile(r"""(['"])((?:(?!\1)[^\\]|\\.)*)\1""")


def uzyte():
    """Wszystkie klucze podane do tr() w kodzie ekranow.

    Dart SKLEJA sasiadujace literaly, a w tej apce dlugie opisy sa lamane na kilka linii:

        tr('Bez tego urzadzenie wysle pliki i zobaczy liste, ale nie '
           'otworzy zadnego.')

    Kluczem jest CALOSC. Branie samego pierwszego kawalka — na czym sie przejechalem —
    daje klucz, ktorego nigdzie nie ma, wiec dopisany na jego podstawie wpis w slowniku
    nigdy by nie trafil i napis dalej pokazywalby polski.
    """
    zebrane = {}
    for p in glob.glob(os.path.join(LIB, '**', '*.dart'), recursive=True):
        tekst = io.open(p, encoding='utf-8').read()
        for m in re.finditer(r'\btr\(', tekst):
            # `tr(...)` w komentarzu to przyklad w dokumentacji, nie napis do przetlumaczenia
            # (`l10n.dart` sam pokazuje uzycie na `tr('Saldo: %s GALU')`).
            poczatek_linii = tekst.rfind('\n', 0, m.start()) + 1
            if tekst[poczatek_linii:m.start()].lstrip().startswith('//'):
                continue
            i = m.end()
            czesci = []
            while True:
                # przeskocz biale znaki i komentarze miedzy sklejanymi kawalkami
                while True:
                    j = i
                    while j < len(tekst) and tekst[j] in ' \t\r\n':
                        j += 1
                    if tekst[j:j + 2] == '//':
                        j = tekst.find('\n', j)
                        if j < 0:
                            break
                        i = j + 1
                        continue
                    i = j
                    break
                lit = LIT.match(tekst, i)
                if not lit:
                    break
                czesci.append(odkoduj(lit.group(2)))
                i = lit.end()
            if czesci:
                linia = tekst.count('\n', 0, m.start()) + 1
                zebrane.setdefault(''.join(czesci), (os.path.relpath(p, KORZEN), linia))
    return zebrane


def main():
    pliki = [os.path.join(LIB, 'l10n.dart'), os.path.join(LIB, 'l10n_pt.dart')]
    en = klucze_slownika('_enMap', pliki)
    de = klucze_slownika('_deMap', pliki)
    pt = klucze_slownika('ptMap', pliki)

    braki = []
    for klucz, (plik, linia) in sorted(uzyte().items()):
        czego = [n for n, m in (('en', en), ('de', de), ('pt', pt)) if klucz not in m]
        if czego:
            braki.append((plik, linia, klucz, czego))

    # Najpierw te z polskimi ogonkami — tam polski jest widoczny golym okiem.
    braki.sort(key=lambda b: (not OGONKI.search(b[2]), b[0], b[1]))
    for plik, linia, klucz, czego in braki:
        print('%s:%d  [brak %s]  %s' % (plik, linia, ','.join(czego), klucz[:70]))
    print()
    print('napisow bez kompletu tlumaczen: %d' % len(braki))
    return 1 if braki else 0


if __name__ == '__main__':
    sys.exit(main())
