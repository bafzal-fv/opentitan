# Check map of a checker, verified both ways (formal-verification skill, tb-architecture.md,
# Quality bar). The map is the uarch's own table, under ".Check map (click to expand)".
#   python3 tools/checkmap.py <testplan.adoc> <uarch.adoc> <checker folder>
#   CHECKER=<name> python3 tools/checkmap.py ...           default tag_path (checker 1); a new
#                                                            checker adds its entry to CHECKERS
# 1. Every check (A..) and cover (C..) the testplan lists for the checker has a row; every row
#    names one the testplan lists.
# 2. Every assert and cover label in the checker's SV is in a row, and every property a row names
#    exists in the SV (ABVIP rows: the instance exists).
# 3. The Module column is rewritten from the file each property is found in.
import os
import re
import sys

tp_path, doc_path, sv_dir = sys.argv[1:4]

CHECKERS = {
    'tag_path': {
        'name': 'checker 1',
        'prefix': 'tpchk',
        'points': ['tf_forward', 'tf_lookup', 'tf_meta_request', 'tf_sticky_tag', 'tf_errors',
                   'tf_flow', 'wtrc_store', 'wtrc_compare', 'wtrc_faults', 'arb_forward',
                   'arb_return', 'arb_flow', 'rmw_read', 'rmw_write_skip', 'rmw_write_back',
                   'rmw_single_op', 'rmw_errors', 'tag_alerts', 'contracts', 'tlul_protocol',
                   'environment'],
        # Testpoints the checkers share: the checks and covers that are this checker's. An
        # allow-list, so IDs other checkers add there never break this map.
        'shared': {
            'contracts': {'A2', 'A4', 'A6', 'A7', 'A8', 'C2', 'C4', 'C6', 'C7', 'C8'},
            'environment': {f'C{n}' for n in range(1, 21)} | {'C22', 'C23'},
        },
    },
}
CFG = CHECKERS[os.environ.get('CHECKER', 'tag_path')]
CHECKER_FILE = CFG['prefix'] + '_checker'
# The checker's own file holds its rules (ENV_RULE); an older checker may keep them in a module.
CANDIDATES = (CHECKER_FILE, CFG['prefix'] + '_env_rules', *CFG.get('extra_files', ()))
SV_FILES = tuple(f for f in CANDIDATES if os.path.exists(f'{sv_dir}/{f}.sv'))
POINTS = CFG['points']
SHARED = CFG['shared']


def expand(ids):
    out = []
    for part in ids.split(','):
        m = re.fullmatch(r'\s*([AC])(\d+)-[AC]?(\d+)\s*', part)
        if m:
            out += [f'{m.group(1)}{n}' for n in range(int(m.group(2)), int(m.group(3)) + 1)]
        else:
            out.append(part.strip())
    return out


# 1. What the testplan lists.
tp = open(tp_path).read()
ALL_POINTS = set(re.findall(r'\[\[tp_(\w+)\]\]', tp))
listed = set()
absent_tp = []
for p in POINTS:
    start = tp.index(f'[[tp_{p}]]')
    nxt = [tp.find(m, start + 5) for m in ('[[tp_', '[[open_items]]', '\n=== ')]
    sec = tp[start:min(x for x in nxt if x > 0)]
    keep = [line for line in sec.split('\n')
            if not re.match(r'\*(Run|Blocked by|Requirements|Retired):\*', line)]
    text = '\n'.join(keep)
    found = set()
    for m in re.finditer(r'^\|(A\d+[ab]?) ', text, re.M):
        found.add(m.group(1))
    if p != 'contracts':
        # A C number right after another testpoint's name (`rmw_write_back` C6) is that one's
        # cover; after a signal name (`d_error` C1) it is this one's.
        for m in re.finditer(r'(?:`(\w+)` )?\bC(\d+)-C(\d+)\b', text):
            if m.group(1) in (None, p) or m.group(1) not in ALL_POINTS:
                found |= {f'C{n}' for n in range(int(m.group(2)), int(m.group(3)) + 1)}
        for m in re.finditer(r'(?:`(\w+)` )?\bC(\d+)\b', text):
            if m.group(1) in (None, p) or m.group(1) not in ALL_POINTS:
                found.add(f'C{m.group(2)}')
    if p in SHARED:
        # Only this checker's IDs; each must be in the testpoint (contracts' covers by name).
        for i in sorted(SHARED[p]):
            if i not in found and not re.search(rf'\b{i}\b', text):
                absent_tp.append((p, i))
            listed.add((p, i))
    else:
        listed |= {(p, i) for i in found}
listed -= CFG.get('ignore', set())

# The map: the doc's table.
doc = open(doc_path).read()
t0 = doc.index('.Check map (click to expand)')
# The last column names the Jasper task (checkers 1, 2) or the run (checker 3, not yet built).
head = re.compile(r'\|Testpoint \|Check \|Property \|Module \|(?:Task|Run)')
t1 = doc.index('|===', head.search(doc, t0).start() + 5)
rows = []
row_re = re.compile(r'^\|`(\w+)` \|([^|]+?) \|(.+?) \|([^|]*?) \|([^|]+)$')
for line in doc[t0:t1].split('\n'):
    m = row_re.match(line)
    if m:
        props = re.findall(r'`([\w.]+)`', m.group(3))
        rows.append([m.group(1), m.group(2).strip(), props, m.group(4).strip(), m.group(5).strip()])

mapped = {}
for tpn, ids, props, _, _ in rows:
    for i in expand(ids):
        mapped.setdefault((tpn, i), []).extend(props)
missing = sorted(listed - set(mapped))
extra = sorted(set(mapped) - listed)

# 2. Properties against the SV.
where = {}
abvips = {}
for f in SV_FILES:
    text = open(f'{sv_dir}/{f}.sv').read()
    for lab in re.findall(r'^\s*((?:assert|cover)_\w+)\s*:', text, re.M):
        where[lab] = f
    for inst in re.findall(r'^\s*tlul_abvip\s*#\(.*?\)\s*(u_abvip_\w+)\s*\(', text, re.M | re.S):
        abvips[inst] = f
checker_labels = {lab for lab, f in where.items() if f == CHECKER_FILE}
named = {p for _, _, props, _, _ in rows for p in props}
unmapped_sv = sorted(checker_labels - named)
absent_sv = sorted(p for p in named if p not in where and p not in abvips)

# 3. The Module column, from the SV.
new_rows = []
for tpn, ids, props, _, task in rows:
    mods = sorted({where.get(p) or abvips.get(p) or '?' for p in props})
    names = ', '.join(f'`{x}`' for x in props)
    new_rows.append(f'|`{tpn}` |{ids} |{names} |{", ".join(mods)} |{task}')
table_body = doc[t0:t1]
lines = table_body.split('\n')
k = 0
for idx, line in enumerate(lines):
    if row_re.match(line):
        lines[idx] = new_rows[k]
        k += 1
doc = doc[:t0] + '\n'.join(lines) + doc[t1:]
open(doc_path, 'w').write(doc)

print(f"testplan checks and covers for {CFG['name']}: {len(listed)}")
print(f'mapped: {len(mapped)}; missing from the map: {missing}; not in the testplan: '
      f'{sorted(set(extra) | set(absent_tp))}')
print(f'checker properties: {len(checker_labels)}; not in the map: {unmapped_sv}; '
      f'in the map but not in the SV: {absent_sv}')
ok = not (missing or extra or absent_tp or unmapped_sv or absent_sv)
print('RESULT:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
