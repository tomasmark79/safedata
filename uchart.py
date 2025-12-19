#!/usr/bin/env python3

__version__ = "0.9.25"
from itertools import chain, islice
from datetime import datetime
from glob import glob
import argparse
import signal
import sys
import os
import re

try:
    "⣾".encode(sys.stdout.encoding)
    USE_BRAILLE = len("⣾") == 1
except Exception:
    USE_BRAILLE = False

if not USE_BRAILLE:
    print("Warning: Braille patterns not supported.", file=sys.stderr)
    sys.exit(78)

def _handle_sigint(signum, frame):
    raise KeyboardInterrupt("Ctrl+C")

signal.signal(signal.SIGINT, _handle_sigint)

def get_arg():
    parser = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('-v', '--version', action='version',
                        version=f"uChart {__version__}")
    parser.add_argument('-y', '--height',
                        type=int, default=7, metavar='<N>',
                        help='Chart height in lines (default: %(default)s)')
    parser.add_argument('-x', '--width',
                        type=int, default=None, dest='width', metavar='<N>',
                        help='Maximum chart width in characters.')
    parser.add_argument('-m', '--multi',
                        action='store_true', dest='multi_value',
                        help='Plot all individual values instead of just the mean.')
    parser.add_argument('-X', '--debug-mode',
                        action='store_true', dest='debug',
                        help='Additional information about the processing of input data.')
    parser.add_argument('-c', '--column',
                        type=str, default=None, dest='column', metavar='<N>[y|m|d|H|M|S]',
                        help='Column number with optional time aggregation.')
    parser.add_argument('-l', '--no-legend',
                        action='store_false', dest='show_legend', default=True,
                        help='Do not display the chart legend.')
    parser.add_argument('-n', '--note',
                        type=str, default=None, metavar='TEXT', dest='show_stat',
                        help='Custom chart title. (overrides default stats)')
    parser.add_argument('-t', '--top-value',
                        type=float, default=None, dest='topv', metavar='<N>',
                        help='Maximum value in chart. (upper limit of Y-axis)')
    parser.add_argument('-b', '--bottom-value',
                        type=float, default=None, dest='bottomv', metavar='<N>',
                        help='Minimum value in chart. (lower limit of Y-axis)')
    parser.add_argument('-s', '--shift',
                        type=int, default=None, dest='shft', metavar='<N>',
                        help='Shift decimal point. (e.g. -6 = ÷1_000_000, 3 = ×1_000)')
    parser.add_argument('-a', '--add',
                        type=float, default=0, dest='addm', metavar='<N>',
                        help='The constant that will be added to each item. (default: %(default)s)')
    parser.add_argument('-f', '--format',
                        type=str, choices=[',', '.'], dest='separator', default=None, metavar='SEP',
                        help="If numbers contain thousands separator, specify it: ',' or '.' (e.g. -f ,)")
    parser.add_argument('file', nargs='*', default=[],
                        help='The input data file, if not specified, is read from stdin.')
    parser.epilog = ( f"optional time filters:\n"
                      f"   target=  requested period only\n"
                      f"   from=    requested period start (including)\n"
                      f"   to=      requested period end (including)\n"
                      f"\n"
                      f"   Supported formats:\n"
                      f"   yyyy | yyyy-mm | yyyy-mm-dd | yyyy-mm-ddThh |\n" 
                      f"   yyyy-mm-ddThh:mm | yyyy-mm-ddThh:mm:ss\n")
    
    args = parser.parse_args(clean_args)

    if len(sys.argv) == 1 and sys.stdin.isatty():
        parser.print_help()
        sys.exit(0)
    return args

def get_shift(shft: int | None) -> float | int:
    if shft is None or shft == 0:
        return 1
    if not -15 <= shft <= 15:
        return 1
    return 10 ** shft

def column_choice(s: str | None):
    if s:
        s = re.sub(r'[^a-zA-Z0-9]', '', s)

        if re.fullmatch(r'\d+', s):
            if 0 < int(s) < 1e3:
                return int(s), None

        if re.fullmatch(r'([ymdHMS])(\d+)|\d+([ymdHMS])', s):
            mode = re.sub(r'[^a-zA-Z]', '', s)
            colu = re.sub(r'[^0-9]', '', s)
            if 0 < int(colu) < 1e3:
                return int(colu), mode

        print(f"Invalid -c option.\n"
              f"Use a column number (e.g. 3) or add one modifier:\n"
              f"[y]ear, [m]onth, [d]ay, [H]our, [M]inute, [S]econd\n"
              f"Examples: 3, m3, 3m, H3, M3, y3, d3", file=sys.stderr )

    return None, None

def get_terminal_width() -> int:
    try:
        return os.get_terminal_size().columns
    except:
        return 80

# TODO(later): Use in future versions
def detect_input(preview):
    pass

def is_valid(s: str, mode: str) -> bool:
    
    if   mode == 'ts':
        ftm = ( "%Y-%m-%dT%H:%M:%S",
                "%Y-%m-%d_%H:%M:%S" )
    elif mode == 'dt':
        ftm = ( "%Y-%m-%d",
                "%Y/%m/%d" )
    elif mode == 'ti' and len(s) == 8:
        ftm = ( "%H:%M:%S",
                "%H.%M.%S" )
    elif mode == 'ti' and len(s) == 5:
        ftm = ( "%H:%M",   )

    elif mode == 'f1':
        ft = '  %Y-%m-%dT%H:%M:%S'
        for _, s2, _ in ISO_PARTS:
            if len(s) == s2:
                ftm = ( ft[:s2].strip(), )
                break
        else:
            return False
    else:
        return False

    for f in ftm:
        try:
            datetime.strptime(s, f)
            return True
        except ValueError:
            continue

    return False

def create_braille_char(dots):
    base = 0x2800
    value = 0
    for i, dot in enumerate(dots):
        if dot:
            value |= (1 << i)
    return chr(base + value)

def get_dot_for_value(value, row, min_val, max_val, G_HEIGHT):
    if value is None:
        return None

    value_range = max_val - min_val
    if value_range == 0:
        normalized = 0.5
    else:
        normalized = (value - min_val) / value_range
    total_pixels = G_HEIGHT * 4
    pixel_pos = int(normalized * (total_pixels - 1))
    value_row = pixel_pos // 4
    value_row = G_HEIGHT - 1 - value_row

    if value_row != row:
        return None

    y_in_row = pixel_pos % 4
    return y_in_row

def average_values_in_groups(values_list, group_size, axisx: dict) -> list:
    result = []
    for i in range(0, len(values_list), group_size):
        group = values_list[i:i+group_size]
        if group:
            result.append(sum(group) / len(group))
            axisx['e'].append(i+group_size)
    return result

def group_values_for_multi(values_list, group_size, axisx: dict) -> list:
    result = []
    for i in range(0, len(values_list), group_size):
        group = values_list[i:i+group_size]
        if group:
            result.append(group)
            axisx['e'].append(i+group_size)
    return result

def group_values_for_precisely(raw_values: list, width: int, axisx: dict) -> list:

    result = []
    amount_values = len(raw_values)

    axisx['e'] = [round((i + 1) * amount_values / (width * 2) ) for i in range(width * 2)]
    
    size = [axisx['e'][0]]

    for i in range(1, (width * 2) ):
        size.append(axisx['e'][i] - axisx['e'][i-1])

    start = 0

    for end in axisx['e']:
        result.append(raw_values[start:end])
        start = end

    return result

def date_time(g: list[str], c: int, a: dict, v: float, e: dict, p: dict) -> None:

    if e['x'] is not None:
        if g[e['x']][:19] != e['X']:
            toend = False
            for s1, s2, l in ISO_PARTS:
                if toend:
                    if a['i'][l]:
                        a['x'][l].append(c)
                        a['a'][l].append(g[e['x']][s1:s2])
                else:
                    if e['X'][s1:s2] != g[e['x']][s1:s2]:
                        if a['i'][l]:
                            a['x'][l].append(c)
                            a['a'][l].append(g[e['x']][s1:s2])
                        toend = True
            e['X'] = g[e['x']][:19] 

    else:
        if e['d'] is not None:
            if g[e['d']][:10] != e['D']:
                toend = False
                for s1, s2, l in DATE_PARTS:
                    if toend:
                        if a['i'][l]:
                            a['d'][l].append(c)
                            a['b'][l].append(g[e['d']][s1:s2])
                    else:
                        if e['D'][s1:s2] != g[e['d']][s1:s2]:
                            if a['i'][l]:
                                a['d'][l].append(c)
                                a['b'][l].append(g[e['d']][s1:s2])
                            toend = True
                e['D'] = g[e['d']][:10] 

        if e['t'] is not None:
            if g[e['t']][:8] != e['T']:
                toend = False
                for s1, s2, l in TIME_PARTS:
                    if toend:
                        if a['i'][l]:
                            a['t'][l].append(c)
                            a['c'][l].append(g[e['t']][s1:s2])
                    else:
                        if e['T'][s1:s2] != g[e['t']][s1:s2]:
                            if a['i'][l]:
                                a['t'][l].append(c)
                                a['c'][l].append(g[e['t']][s1:s2])
                            toend = True
                e['T'] = g[e['t']][:8] 

    if c%5 == 0:

        if e['x'] is not None:
            for i in ['y','m','d','H','M','S']:
                if len(a['x'][i]) > a['m']:
                    a['x'][i] = []
                    a['a'][i] = []
                    a['i'][i] = False
        else:

            if e['t'] is not None:
                for i in ['H','M','S']:
                    if len(a['t'][i]) > a['m']:
                        a['t'][i] = []
                        a['c'][i] = []
                        a['i'][i] = False

            if e['d'] is not None:
                for i in ['y','m','d']:
                    if len(a['d'][i]) > a['m']:
                        a['d'][i] = []
                        a['b'][i] = []
                        a['i'][i] = False

        if e['x'] is not None:
            if not TS_RE.match( g[e['x']][:19] ):
                e['e'] += 1

        else:

            if e['d'] is not None:
                if not DT_RE.match( g[e['d']][:10] ):
                    e['e'] += 1

            if e['t'] is not None:
                if not TM_RE.match( g[e['t']][:8] ):
                    e['e'] += 1

        if e['e'] > 0:
            e['u'] = False
            p['u'] = False
            p['g'] = {}
            return None

        if c%100 == 0:

            if e['x'] is not None:
                if not any( a['i'][k] for k in "ymdHMS" ):
                    a['x'] = { k: [] for k in 'ymdHMS' }
            else:

                if e['d'] is not None:
                    if not any( a['i'][k] for k in "ymd" ):
                        a['d'] = { 'y':[], 'm':[], 'd':[] }

                if e['t'] is not None:
                    if not any( a['i'][k] for k in "HMS" ):
                        a['t'] = { 'H':[], 'M':[], 'S':[] }

    if e['u'] and e['s'] and CSUM:
        if e['x'] is not None:
            for s1, s2, l in ISO_PARTS:
                if l == CSUM:
                    if g[e['x']][:s2] in p['g']:
                        p['g'][g[e['x']][:s2]] += v
                    else:
                        p['g'][g[e['x']][:s2]] = v
        else:
            if e['d'] is not None and e['t'] is not None:
                ts = g[e['d']][:10] + 'T' + g[e['t']][:8]
            elif e['d']:
                ts = g[e['d']][:10] + 'T00:00:00'
            elif e['t'] is not None:
                ts = '0000-00-00T' + g[e['t']][:8]
            for s1, s2, l in ISO_PARTS:
                if l == CSUM:
                    if ts[:s2] in p['g']:
                        p['g'][ts[:s2]] += v
                    else:
                        p['g'][ts[:s2]] = v

    return None

def group_by_time(r: list, l: int, c: int, e: dict, p: dict):
    count = long = 0
    new_raw = []
    valid = (    e['e'] == 0
             and c > 0
             and len(p['g']) > 0
             and CSUM        )

    if valid:
        for i in p['g'].values():
            if len(str(int(i))) > long:
                long = len(str(int(i)))
            new_raw.append(i)
            count += 1
        p['l'] = True
        return new_raw, long, count

    return r, l, c

def print_x_legend(a: dict, e: dict, p:dict, l: int, b: int, c: int) -> None:
    if CSUM:
        print(f"{SUM_LEGEND[CSUM]}{'':>{l-9}} └{'─' * b}")
        return None

    if b < 10:
        print(f"{'':>{l}} └{'─' * b}")
        return None

    ml = int(b * 0.5)

    if e['d'] is not None or e['t'] is not None:
        x = { k: a['d' if k in 'ymd' else 't'][k]
              for k in 'ymdHMS'
              if 0 < len(a['d' if k in 'ymd' else 't'][k]) < ml }
        v = { k: a['b' if k in 'ymd' else 'c'][k]
              for k in 'ymdHMS'
              if 0 < len(a['b' if k in 'ymd' else 'c'][k]) < ml }

    if e['x'] is not None:
        x = { k: a['x'][k] for k in 'ymdHMS' if 0 < len(a['x'][k]) < ml }
        v = { k: a['a'][k] for k in 'ymdHMS' if 0 < len(a['a'][k]) < ml }

    if len(x) == 0:
        print(f"{'':>{l}} └{'─' * b}")
        return None

    if len(x) > 1:
        lkey = max(x, key=lambda k: len(x[k]))
        x = {lkey: x[lkey]}
        vkey = max(v, key=lambda k: len(v[k]))
        v = {lkey: v[vkey]}
    else:
        lkey = list(x.keys())[0]
        vkey = list(v.keys())[0]

    positions = x[lkey]
    precisely_list = a['e']
    leg_point_pos = []

    line1 = [' '] * b
    
    for point in positions:

        for i, colu in enumerate(precisely_list):
            if point > colu:
                continue
            break

        term_col = i // 2
        is_right = i % 2
        leg_point_pos.append(term_col)
        bit = 1 << (0 if not is_right else 3)

        current = ord(line1[term_col]) - 0x2800 if line1[term_col] != ' ' else 0
        new_val = current | bit
        line1[term_col] = chr(0x2800 + new_val)

    line2 = line1[:]
    positions_reverse = leg_point_pos[::-1]
    
    values_reverse = [s.lstrip('0') or '0' for s in v[vkey][::-1]]
    
    for pos, val in zip (positions_reverse, values_reverse):

        paint = True

        space = 2 if SPACE is None else SPACE

        for i, _ in enumerate(val + '.' * space):
            try:
                if line2[pos+i+1] != ' ':
                    paint = False
            except IndexError:
                paint = False
        if paint:
            for i, iv in enumerate(val):
                line2[pos+i+1] = iv
        
    trans = str.maketrans("0123456789", "₀₁₂₃₄₅₆₇₈₉")
    linex = ''.join(line2).translate(trans)

    print(f"{LEGEND[lkey]}{'':>{l-9}} └{'─' * b}")
    print(f"{'':>{l+2}}{linex}")

def human_bytes(b: int) -> str:
    units = ["Bytes", "KiB", "MiB", "GiB"]
    for unit in units:
        if b < 1024 or unit == units[-1]:
            if b == int(b):
                return f"{int(b)} {unit}"
            else:
                return f"{b:.2f}".rstrip("0").rstrip(".") + f" {unit}"
        b /= 1024
    return f"{b:.1f}{unit}"

def print_debug_info(c, a, g, cl, cv, co, el, cf):
    ch, te, bt = a['M'], a['m'], c['B']
    f1, f2 = c['f']
    l1, l2, l3, l4 = c['l']
    sk, se = c['p'], c['P']
    t1 = f"{human_bytes(bt/c['N'])}/s" if c['N']>0.02 and bt>0 else ''
    el = f"{el[:3]}..." if len(el)>3 else el
    el = '' if len(el) == 0 else el
    ch1 = f"{ch/te*100:.1f}".rstrip("0").rstrip(".") if te else 'n/a'
    er1 = f"{co/cl*100:.3f}".rstrip("0").rstrip(".") if cl else 'n/a'
    sk1 = f"{sk/cl*100:.3f}".rstrip("0").rstrip(".") if cl else 'n/a'
    se1 = f"{se/cl*100:.3f}".rstrip("0").rstrip(".") if cl else 'n/a'
    ts = f"{ordinal(f1)} line (attempt {f2}/10)" if f1 else 'Undetected'

    print( f"\n Total lines:     {cl} ({human_bytes(bt)}) {t1}\n"
             f"   Processed:     {co} ({er1}%)\n"
             f"   Error:         {se} ({se1}%) {el}\n"
             f"   Skipped:       {sk} ({sk1}%)\n"
             f" Error match:     {c['e']}\n"
             f" Values in chart: {cv}\n"
             f" Terminal width:  {te} {'(-x limit)' if XWIDTH else ''}\n"
             f" Chart width:     {ch} ({ch1}%)\n"
             f" Compression:     {cf if cf > 1 else 'No'}\n"
             f" Amount Σ:        {len(g['g'])}\n"
             f" Filter ta/fr/to: {TARGET}, {TFROM}, {TTO}\n"
             f" First timestamp: {ts}\n"
             f"   Hit li/TS/D/T: ({l1},{l2},{l3},{l4})\n"
             f"   f: TS='{c['a']}', D='{c['b']}', T='{c['c']}'\n"
             f"   l: TS='{c['X']}', D='{c['D']}', T='{c['T']}'\n", file=sys.stderr)

def reducef(p: list[str], f: int) -> int:
    if len(p) < 2:
        return f

    max_needed = 0

    for i in range(len(p) - 1):
        s1, s2 = p[i], p[i+1]

        if s1.split('.')[0] != s2.split('.')[0]:
            continue

        frac1 = s1.split('.')[1] if '.' in s1 else ''
        frac2 = s2.split('.')[1] if '.' in s2 else ''

        for pos in range(max(len(frac1), len(frac2))):
            c1 = frac1[pos] if pos < len(frac1) else '0'
            c2 = frac2[pos] if pos < len(frac2) else '0'
            if c1 != c2:
                max_needed = max(max_needed, pos + 1)
                break
    return min(max_needed, f)

def ordinal(n: int) -> str:
    s = {1: "st", 2: "nd", 3: "rd"}
    teens = 11 <= (n % 100) <= 13
    suffix = "th" if teens else s.get(n % 10, "th")
    return f"{n}{suffix}"

def am_digit(p: list[str]) -> int:
    return max((len(s.replace('-', '').split('.')[0]) for s in p), default=0)

def negat(p: list[str]) -> bool:
    return any(s.startswith('-0.') for s in p)

def draw_graph(values_for_plot, original_raw_values, compression_factor, long_numbers, long_floatpa, axisx, colle, grups, cl, cv):
    if not values_for_plot:
        return

    if not original_raw_values:
        min_val = min(val for group in values_for_plot for val in (group if isinstance(group, list) else [group]))
        max_val = max(val for group in values_for_plot for val in (group if isinstance(group, list) else [group]))
    else:
        min_val = min(original_raw_values)
        max_val = max(original_raw_values)

    max_val = TOPVAL if TOPVAL is not None else max_val
    min_val = DOWNV if DOWNV is not None else min_val
    value_range = max_val - min_val

    if not TITLE and SHOWSTATS:
        total_original_values = len(original_raw_values)
        num_plot_columns = len(values_for_plot)
        if MULTIV:
            print(f"\n[{total_original_values} values in {num_plot_columns} columns; {compression_factor} values in a column]")
        elif compression_factor == 1:
            print(f"\n[{total_original_values} values]")
        else:
            print(f"\n[{total_original_values} values; average of {compression_factor} values in a column]")
    if TITLE:
        print(f"{TITLE}")

    legend_values = []

    if SHOWLEGEND:
        for i in range(YHEIGHT):
            normalized = 1 - (i / (YHEIGHT - 1))
            val = min_val + normalized * value_range
            legend_values.append(val)

        zend = None
        for row in range(YHEIGHT):
            lg = legend_values[row]
            lz = f"{lg:>{3+long_numbers+3}.{long_floatpa}f}"
            ze = len(lz) - len(lz.rstrip('0'))
            zend = ze if zend is None else zend
            zend = ze if ze < zend else zend

        zend = long_floatpa - zend
        vall = [f"{legend_values[row]:.{zend}f}" for row in range(YHEIGHT)]
        zend = reducef(vall, zend)
        zend = 1 if zend < 1 and am_digit(vall) < 4 else zend
        nega = 1 if negat(vall) and zend == 7 else 0

    for row in range(YHEIGHT):
        line = ""
        if SHOWLEGEND:
            lg = legend_values[row]
            if all( c in '0.-' for c in f"{lg:.{zend}f}" ):
                line += f"{'':{nega+long_numbers+2}}0 │"
            else:
                line += f"{lg:>{3+nega+long_numbers}.{zend}f} │"

        for i in range(0, len(values_for_plot), 2):
            dots = [False] * 8

            if i < len(values_for_plot):
                current_data_left = values_for_plot[i]
                values_to_process = current_data_left if isinstance(current_data_left, list) else [current_data_left]

                for val in values_to_process:
                    y_pos = get_dot_for_value(val, row, min_val, max_val, YHEIGHT)
                    if y_pos is not None:
                        dot_map = [6, 2, 1, 0]
                        dots[dot_map[y_pos]] = True

            if i + 1 < len(values_for_plot):
                current_data_right = values_for_plot[i + 1]
                values_to_process = current_data_right if isinstance(current_data_right, list) else [current_data_right]

                for val in values_to_process:
                    y_pos = get_dot_for_value(val, row, min_val, max_val, YHEIGHT)
                    if y_pos is not None:
                        dot_map = [7, 5, 4, 3]
                        dots[dot_map[y_pos]] = True
            line += create_braille_char(dots)
        print(line)

    if SHOWLEGEND:
        num_braille_chars = axisx['M'] = (len(values_for_plot) + 1) // 2

        if axisx['u']:
            print_x_legend(axisx, colle, grups, nega+long_numbers+3, num_braille_chars, compression_factor)
        else:
            print(f"{'':>{nega+long_numbers+3}} └{'─' * num_braille_chars}")
    return

def date_time_search(c: int, e: dict, a: dict, g: list, p: dict, cl: int) -> None:

    if c == 10:
        e['u'] = False
        return None

    e['l'][0] += 1
    amx = [i for i, item in enumerate(g) if is_valid( item[:19], "ts" )]
    e['l'][1] += len(amx)
    if len(amx) == 1:
        e['a'] = e['X'] = g[amx[0]][:19]
        e['s'] = a['u'] = True
        if CSUM: p['u'] = True
        e['f'] = [cl, c+1]
        e['x'] = amx[0]
    else:
        amd = [i for i, item in enumerate(g) if is_valid( item[:10], "dt" )]
        e['l'][2] += len(amd)
        if len(amd) == 1:
            e['b'] = e['D'] = g[amd[0]][:10]
            e['s'] = a['u'] = True
            if CSUM: p['u'] = True
            e['f'] = [cl, c+1]
            e['d'] = amd[0]
        amt = [i for i, item in enumerate(g) if is_valid( item[:8], "ti" )]
        e['l'][3] += len(amt)
        if len(amt) == 1:
            e['c'] = e['T'] = g[amt[0]][:8]
            e['s'] = a['u'] = True
            if CSUM: p['u'] = True
            e['f'] = [cl, c+1]
            e['t'] = amt[0]

    return None

def extract_filters(args_list):
    custom_filters = {}
    cleaned_args = []
    search_arg = ('from=',
                    'to=',
                'target=',
                 'space=', )
    
    for a in args_list:
        if a.startswith(search_arg):
            key, value = a.split('=', 1)
            if value:
                custom_filters[key] = value
            else:
                cleaned_args.append(a)
        else:
            cleaned_args.append(a)
    
    return custom_filters, cleaned_args

def valid_filter(f: dict, mode: str) -> str | None:
    if mode == 'target':
        if 'target' in f:
            if is_valid( f["target"], "f1"):
                return f["target"]
            else:
                return
    
    if mode == 'from':
        if 'from' in f:
            if is_valid( f["from"], "f1"):
                return f["from"]
            else:
                return

    if mode == 'to':
        if 'to' in f:
            if is_valid( f["to"], "f1"):
                return f["to"]
            else:
                return

    if mode == 'space':
        if 'space' in f:
            if len( f['space'] ) == 1 and f['space'].isdigit():
                return int( f['space'] )
            return
    return

def value_filtering(f: list, c: dict) -> bool:
    if TARGET:
        if c['x'] is not None:
            if f[c['x']][:len(TARGET)] == TARGET:
                return True
        else:
            d = f[c['d']][:10] if c['d'] is not None else '0000-00-00'
            dt = d+'T'+f[c['t']][:8] if c['t'] is not None else d+'T00:00:00'
            if re.sub(r'\D','',dt[:len(TARGET)]) == re.sub(r'\D','',TARGET):
                return True
            return False

    fr = to = False

    if TFROM is None:
        fr = True
    else:
        if c['x'] is not None:
            if f[c['x']][:len(TFROM)] >= TFROM:
                fr = True
        else:
            d = f[c['d']][:10] if c['d'] is not None else '0000-00-00'
            dt = d+'T'+f[c['t']][:8] if c['t'] is not None else d+'T00:00:00'
            if re.sub(r'\D','',dt[:len(TFROM)]) >= re.sub(r'\D','',TFROM):
                fr = True

    if TTO is None:
        to = True
    else:
        if c['x'] is not None:
            if f[c['x']][:len(TTO)] <= TTO:
                to = True
        else:
            d = f[c['d']][:10] if c['d'] is not None else '0000-00-00'
            dt = d+'T'+f[c['t']][:8] if c['t'] is not None else d+'T00:00:00'
            if re.sub(r'\D','',dt[:len(TTO)]) <= re.sub(r'\D','',TTO):
                to = True
    
    if ( TFROM or TTO ) and fr and to:
        return True

    return False

LEGEND = {    'y': 'years >  ',
              'm': 'months > ',
              'd': 'days >   ',
              'H': 'hours >  ',
              'M': 'minutes >',
              'S': 'seconds >',}

SUM_LEGEND = {'y': 'year Σ   ',
              'm': 'month Σ  ',
              'd': 'day Σ    ',
              'H': 'hour Σ   ',
              'M': 'min Σ    ',
              'S': 'sec Σ    ',}

ISO_PARTS = [ (0,  4, "y"),
              (5,  7, "m"),
              (8, 10, "d"),
              (11,13, "H"),
              (14,16, "M"),
              (17,19, "S"),]

DATE_PARTS = [(0, 4,'y'),
              (5, 7,'m'),
              (8,10,'d'),]

TIME_PARTS = [(0,2,'H'),
              (3,5,'M'),
              (6,8,'S'),]

filters, clean_args = extract_filters(sys.argv[1:])
arg = get_arg()
T = arg.show_stat

TITLE        = T.replace('\\n','\n').replace('\\t','\t') if T is not None else None
SHOWSTATS    = True if arg.show_stat is None else False
TARGET       = valid_filter(filters,'target')
SPACE        = valid_filter(filters,'space')
TFROM        = valid_filter(filters,'from')
TTO          = valid_filter(filters,'to')
COLUMN, CSUM = column_choice(arg.column)
SHFT         = get_shift(arg.shft)
MULTIV       = arg.multi_value
SHOWLEGEND   = arg.show_legend
SEPA         = arg.separator
DOWNV        = arg.bottomv
YHEIGHT      = arg.height
DEBUGFLAG    = arg.debug
XWIDTH       = arg.width
ADDM         = arg.addm
TOPVAL       = arg.topv
FILE         = arg.file

FILTERON = bool(TARGET or TFROM or TTO)

YHEIGHT = 2 if YHEIGHT < 2 else YHEIGHT
XWIDTH  = None if XWIDTH is not None and XWIDTH < 1 else XWIDTH
if TOPVAL is not None and DOWNV is not None and TOPVAL <= DOWNV:
    TOPVAL = DOWNV = None

TS_RE = re.compile( r'^\d{4}-'                # y 0000-9999
                    r'(0[1-9]|1[0-2])-'       # m 01–12
                    r'(0[1-9]|[12]\d|3[01])'  # d 01–31
                    r'[T_]'
                    r'([01]\d|2[0-3])'        # H 00–23
                    r':[0-5]\d'               # M 00–59
                    r':[0-5]\d')              # S 00–59

DT_RE = re.compile( r'^\d{4}[-/]'             # y 0000-9999
                    r'(0[1-9]|1[0-2])[-/]'    # m 01–12
                    r'(0[1-9]|[12]\d|3[01])') # d 01–31

TM_RE = re.compile( r'^([01]\d|2[0-3])'       # H 00-23
                    r'[:.][0-5]\d'            # M 00-59
                    r'(?:[:.][0-5]\d)?$')     # S 00-59 if is

def main():
    size = 0
    err_lines = []
    raw_values = []
    long_numbers = 0
    long_floatpa = 2
    counter_line = 0
    counter_value = 0
    counter_error = 0
    counter_skipped = 0

    colle = { 'u': True,  # I use date/time
              's': False, # Found
              'f': [0]*2, # fileline, first TS value
              'l': [0]*4, # amount l/ts/d/t
              'e': 0,     # 0 = no errors
              'B': 0,     # data size, 
              'N': 0,     # load time
              'p': 0,     # skipped line
              'P': 0,     # error line

              'x': None,  # collumn
              'a': None,  # first - 0000-00-00T00:00:00
              'X': None,  # last  - 0000-00-00T00:00:00

              'd': None,  # collumn
              'b': None,  # first - 0000-00-00
              'D': None,  # last  - 0000-00-00

              't': None,  # collumn
              'c': None,  # first - 00:00:00
              'T': None,  # last  - 00:00:00
            }

    axisx = { 'u': False, 
              'm': get_terminal_width() if XWIDTH is None else XWIDTH,
              'M': 0,     # num_braille_chars
              'i': { k: True for k in 'ymdHMS' },
              'e': [],    # precisely group list 

              'x': { k: [] for k in 'ymdHMS' },
              'a': { k: [] for k in 'ymdHMS' },
              'X': True,

              'd': { 'y':[], 'm':[], 'd':[] },
              'b': { 'y':[], 'm':[], 'd':[] },
              'D': True,

              't': { 'H':[], 'M':[], 'S':[] },
              'c': { 'H':[], 'M':[], 'S':[] },
              'T': True,
            }

    grups = { 'u': False,
              'l': False,
              'g': {},
            }

    # 1. pipe
    if not sys.stdin.isatty() and not FILE:
        datain = sys.stdin

    # 2. file or files
    else:
        file_list = []
        has_pattern = bool(FILE)

        for pattern in FILE:
            matches = glob(pattern)
            if matches:
                file_list.extend(matches)
            else:
                print(f"{pattern}: No such file or directory", file=sys.stderr)

        if not file_list:
            if has_pattern:
                print("No input files found.", file=sys.stderr)
                sys.exit(1)
            else:
                datain = sys.stdin
        else:
            def multi_file_stream(files):
                for f_path in files:
                    try:
                        with open(f_path, 'r', encoding='utf-8') as f:
                            yield from f
                    except Exception as e:
                        print(f"Error reading {f_path}: {e}", file=sys.stderr)

            datain = multi_file_stream(file_list)

    preview = list(islice(datain, 10))
    detect_input(preview)
    start_data_load = datetime.now()
    
    try:
        for line in chain(preview, datain):
            counter_line += 1
            size += len(line)

            if COLUMN:

                fields = line.split()

                if len(fields) < COLUMN:
                    if len(err_lines) < 4: err_lines.append(counter_line)
                    counter_error += 1
                    continue

                if not colle['s'] and colle['u']:
                    date_time_search(counter_value, colle, axisx, fields, grups, counter_line)

                if FILTERON:
                    if not value_filtering(fields, colle):
                        counter_skipped += 1
                        continue

                line = fields[COLUMN-1]

            if SEPA:
                line = line.replace(SEPA, '')

            line = line.strip().replace(',', '.')

            if line:

                try:
                    value = ( float(line) + ADDM ) * SHFT
                    value = TOPVAL if TOPVAL is not None and value > TOPVAL else value
                    value = DOWNV if DOWNV is not None and value < DOWNV else value

                    if len(str(int(value))) > long_numbers:
                        long_numbers = len(str(int(value)))

                    raw_values.append(value)
                    counter_value += 1

                    if colle['u'] and COLUMN:
                        date_time(fields, counter_value, axisx, value, colle, grups)

                except ValueError:
                    if len(err_lines) < 4: err_lines.append(counter_line)
                    counter_error += 1
                    continue
        
        end_data_load = datetime.now()
        colle['B'] = size
        colle['p'] = counter_skipped
        colle['P'] = counter_error
        old_counter_value = counter_value

        if grups['u']:
            raw_values, long_numbers, counter_value = group_by_time(raw_values, long_numbers, counter_value, colle, grups)

        if long_numbers < 6:
            long_floatpa = 8 - long_numbers
            long_numbers = 6

        if raw_values:
            if XWIDTH and XWIDTH < get_terminal_width() - (long_numbers + 1 + long_floatpa + 2 + 2):
                term_width = XWIDTH
            else:
                term_width = get_terminal_width() - (long_numbers + 1 + long_floatpa + 2 + 2)

            available_braille_chars = term_width if SHOWLEGEND else get_terminal_width() - 2
            if available_braille_chars < 1:
                available_braille_chars = 1
            max_data_columns = available_braille_chars * 2
            compression_factor = 1

            if len(raw_values) > max_data_columns:
                compression_factor = (len(raw_values) + max_data_columns - 1) // max_data_columns
                if compression_factor == 0: compression_factor = 1

            val_for_plot = []

            if MULTIV:
                if XWIDTH is None:
                    val_for_plot = group_values_for_multi(raw_values, compression_factor, axisx)
                else:
                    val_for_plot = group_values_for_precisely(raw_values, XWIDTH, axisx)
            else:
                val_for_plot = average_values_in_groups(raw_values, compression_factor, axisx)
            
            colle['N'] = (end_data_load - start_data_load).total_seconds()
            draw_graph(val_for_plot, raw_values, compression_factor, long_numbers,
                       long_floatpa, axisx, colle, grups, counter_line, counter_value)

            if DEBUGFLAG:
                print_debug_info(colle, axisx, grups, counter_line, counter_value,
                                 old_counter_value, err_lines, compression_factor)
        else:
            if DEBUGFLAG:
                print( f'\n     Total lines: {counter_line}\n'
                       f' Processed lines: {old_counter_value}\n'
                       f'     Error lines: {counter_error}\n'
                       f'   Skipped lines: {counter_skipped}\n' )

    except KeyboardInterrupt:
        print(f'\nAfter loading {len(raw_values)} values, it was interrupted by the user.', file=sys.stderr)
        sys.exit(130)

    finally:
        if hasattr(datain, 'close') and datain is not sys.stdin:
            try:
                datain.close()
            except:
                pass

if __name__ == "__main__":
    main()
