import os, sys, subprocess, shutil, zipfile
from pathlib import Path
import urllib.request

STAR = chr(42)
ROOT = Path.cwd()
EXE = ROOT / 'fnaf4.exe'
OUT = ROOT / 'out'
SRC = ROOT / '.src'
OUT.mkdir(exist_ok=True)
SRC.mkdir(exist_ok=True)
print('Game', EXE, EXE.exists(), EXE.stat().st_size if EXE.exists() else 0)

ctfak_src = SRC / 'CTFAK2.0'
if not ctfak_src.exists():
    subprocess.run(['git', 'clone', 'https://github.com/CTFAK/CTFAK2.0.git', str(ctfak_src)], check=True)
else:
    subprocess.run(['git', '-C', str(ctfak_src), 'checkout', '--', '.'], check=False)
    subprocess.run(['git', '-C', str(ctfak_src), 'clean', '-fd'], check=False)

prog_path = ctfak_src / 'Interface' / 'CTFAK.Cli' / 'Program.cs'
if prog_path.exists():
    pt = prog_path.read_text(encoding='utf-8', errors='ignore')
    pt = pt.replace('Console.Clear()', 'try{Console.Clear();}catch{}')
    pt = pt.replace('Console.ReadKey();', 'try{Console.ReadKey();}catch{}')
    pt = pt.replace('Directory.SetCurrentDirectory', '//noSetCwd')
    prog_path.write_text(pt, encoding='utf-8')
    print('Patched Program.cs')

art_path = ctfak_src / 'Interface' / 'CTFAK.Cli' / 'ASCIIArt.cs'
if art_path.exists():
    at = art_path.read_text(encoding='utf-8', errors='ignore')
    key = 'public static void DrawArt2()'
    i = at.find(key)
    if i != -1:
        j = at.find(chr(10) + '        }', i)
        if j != -1:
            at = at[:i] + 'public static void DrawArt2() { }' + at[j + len(chr(10) + '        }'):]
    at = at.replace('Console.Title', '//Console.Title')
    art_path.write_text(at, encoding='utf-8')
    print('Patched ASCIIArt')

print('Building CTFAK...')
res = subprocess.run(['dotnet', 'build', 'CTFAK.sln', '-c', 'Release'], cwd=str(ctfak_src), capture_output=True, text=True)
print(res.stdout[-600:])
print(res.stderr[-600:])
print('Build exit', res.returncode)
if res.returncode != 0:
    sys.exit(1)

cli_bin = None
for pp in (ctfak_src / 'Interface' / 'CTFAK.Cli' / 'bin' / 'Release').rglob('CTFAK.Cli.dll'):
    cli_bin = pp.parent
    break
print('CLI bin', cli_bin)
if not cli_bin:
    sys.exit(1)

launcher = ['dotnet', str(cli_bin / 'CTFAK.Cli.dll')]

req = SRC / 'ctfakrequirements.zip'
urls = ['https://github.com/CTFAK/.github/raw/main/ctfakrequirements.zip',
        'https://raw.githubusercontent.com/CTFAK/.github/main/ctfakrequirements.zip']
if not (req.exists() and req.stat().st_size > 1000):
    for u in urls:
        try:
            urllib.request.urlretrieve(u, str(req))
            if req.exists() and req.stat().st_size > 1000:
                break
        except Exception as e:
            print('dl fail', e)
try:
    with zipfile.ZipFile(req) as z:
        z.extractall(cli_bin)
    print('Extracted req')
except Exception as e:
    print('req issue', e)

zlibs = list(cli_bin.rglob('zlibwapi.dll')) + list(ctfak_src.rglob('zlibwapi.dll'))
if zlibs:
    for arch in ['x64', 'x86']:
        d = cli_bin / arch
        d.mkdir(parents=True, exist_ok=True)
        t = d / 'zlibwapi.dll'
        if not t.exists():
            shutil.copy2(zlibs[0], t)
    rz = cli_bin / 'zlibwapi.dll'
    if not rz.exists():
        shutil.copy2(zlibs[0], rz)

if not (cli_bin / 'template.mfa').exists():
    try:
        urllib.request.urlretrieve('https://raw.githubusercontent.com/Mrr7782/CTFAK2.0-compiled/main/template.mfa', str(cli_bin / 'template.mfa'))
    except Exception as e:
        print('template fail', e)

plugin_dir = cli_bin / 'Plugins'
plugin_dir.mkdir(parents=True, exist_ok=True)
for name in ['CTFAK.Decompiler.dll', 'Dumper.dll']:
    found = [c for c in ctfak_src.rglob(name) if 'obj' not in c.parts]
    if found:
        shutil.copy2(found[0], plugin_dir / name)
print('Plugins:', sorted(x.name for x in plugin_dir.glob(STAR + '.dll')))

cmd = launcher + ['-path', str(EXE), '-tool', 'Export as MFA', '-closeonfinish']
print('Running', cmd)
r = subprocess.run(cmd, cwd=str(cli_bin), capture_output=True, text=True, timeout=1800)
print(r.stdout[-2000:])
print(r.stderr[-2000:])
print('Exit', r.returncode)

cmd2 = launcher + ['-path', str(EXE), '-tool', 'Dump Everything', '-closeonfinish']
r2 = subprocess.run(cmd2, cwd=str(cli_bin), capture_output=True, text=True, timeout=1800)
print('Dumper exit', r2.returncode)

print('cli_bin contents:', sorted(x.name for x in cli_bin.iterdir()))

for _root in [cli_bin, ROOT]:
    for _dp, _dn, _fn in os.walk(str(_root)):
        if 'Dumps' in Path(_dp).parts:
            for _f in _fn:
                _full = Path(_dp) / _f
                _rel = _full.relative_to(_root)
                _dest = OUT / _rel
                _dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(_full, _dest)
                print('Copy', _full, _full.stat().st_size)

seen = set()
for _root in [ROOT, cli_bin]:
    for _dp, _dn, _fn in os.walk(str(_root)):
        for _f in _fn:
            if _f.lower().endswith('.mfa') and _f.lower() != 'template.mfa':
                _full = Path(_dp) / _f
                if str(_full) in seen:
                    continue
                seen.add(str(_full))
                try:
                    shutil.copy2(_full, OUT / _f)
                    print('MFA', _full, _full.stat().st_size)
                except Exception as e:
                    print('mfa fail', e)

print('Final OUT')
for p in OUT.rglob(STAR):
    if p.is_file():
        print(' ', p, p.stat().st_size)
